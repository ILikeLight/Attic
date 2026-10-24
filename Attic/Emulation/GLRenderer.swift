import Accelerate
import AtticLibretro
import CoreVideo
import OpenGLES

/// The OpenGL ES 3 context for cores that draw with the GPU, such as GLideN64 for the N64.
///
/// The core always draws into the same framebuffer, as in RetroArch: cores may keep its name,
/// and may leave the picture standing when a frame brings nothing new. After each frame the
/// picture is copied on the GPU into one of three IOSurfaces, which the Metal screen shows
/// without another copy, so the core never draws into the frame that is on screen. The
/// Simulator cannot draw into an IOSurface with OpenGL ES; there the frame is read back instead.
/// Like the core, it is only used on the emulation thread.
final class GLRenderer {
    /// A surface the Metal screen shows.
    private struct Surface {
        let pixelBuffer: CVPixelBuffer
        let texture: CVOpenGLESTexture
        let framebuffer: GLuint
    }

    private let context: EAGLContext
    private let textureCache: CVOpenGLESTextureCache
    /// False where OpenGL ES cannot draw into an IOSurface.
    private let sharesSurfaces: Bool
    private var renderFramebuffer: GLuint = 0
    private var renderTexture: GLuint = 0
    private var depthBuffer: GLuint = 0
    private var surfaces: [Surface] = []
    private var next = 0
    /// The pixels of a frame read back in the Simulator.
    private var copyBuffer: UnsafeMutableRawPointer?
    /// The frame copied last time, shown once the GPU has finished it.
    private var pending: (surface: Surface, width: Int, height: Int, flipped: Bool, fence: GLsync?)?
    private(set) var width = 0
    private(set) var height = 0

    /// The framebuffer the core draws into, or 0 before `makeTargets`.
    var framebuffer: GLuint { renderFramebuffer }

    init?() {
        guard let context = EAGLContext(api: .openGLES3), EAGLContext.setCurrent(context) else { return nil }
        var cache: CVOpenGLESTextureCache?
        guard CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, context, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.context = context
        textureCache = cache
        // Try a small surface first, so the choice is made before the core starts drawing.
        sharesSurfaces = Self.makeSurface(width: 16, height: 16).map { Self.texture(for: $0, cache: cache) != nil } ?? false
        CVOpenGLESTextureCacheFlush(cache, 0)
    }

    deinit {
        EAGLContext.setCurrent(context)
        deleteTargets()
        CVOpenGLESTextureCacheFlush(textureCache, 0)
        EAGLContext.setCurrent(nil)
    }

    /// Makes the framebuffers once the core knows its largest picture.
    func makeTargets(width: Int, height: Int, depth: Bool, stencil: Bool) -> Bool {
        makeCurrent()
        deleteTargets()
        self.width = width
        self.height = height

        glGenTextures(1, &renderTexture)
        glBindTexture(GLenum(GL_TEXTURE_2D), renderTexture)
        glTexStorage2D(GLenum(GL_TEXTURE_2D), 1, GLenum(GL_RGBA8), GLsizei(width), GLsizei(height))
        glGenFramebuffers(1, &renderFramebuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), renderFramebuffer)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), renderTexture, 0)
        if depth || stencil {
            glGenRenderbuffers(1, &depthBuffer)
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), depthBuffer)
            glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(stencil ? GL_DEPTH24_STENCIL8 : GL_DEPTH_COMPONENT24),
                                  GLsizei(width), GLsizei(height))
            glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(stencil ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT),
                                      GLenum(GL_RENDERBUFFER), depthBuffer)
        }
        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else { return false }

        if sharesSurfaces {
            for _ in 0..<3 {
                guard let pixelBuffer = Self.makeSurface(width: width, height: height),
                      let texture = Self.texture(for: pixelBuffer, cache: textureCache) else { return false }
                var framebuffer: GLuint = 0
                glGenFramebuffers(1, &framebuffer)
                glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
                glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D),
                                       CVOpenGLESTextureGetName(texture), 0)
                surfaces.append(Surface(pixelBuffer: pixelBuffer, texture: texture, framebuffer: framebuffer))
                guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else { return false }
            }
        } else {
            copyBuffer = .allocate(byteCount: width * height * 4, alignment: 16)
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), renderFramebuffer)
        next = 0
        return true
    }

    /// The context is per thread; the emulation thread keeps it.
    func makeCurrent() {
        if EAGLContext.current() !== context {
            EAGLContext.setCurrent(context)
        }
    }

    /// Hands the frame the core drew (`width` × `height` from the bottom-left corner) to the screen.
    ///
    /// The GPU may still be drawing it, so instead of waiting for that (`glFinish`), the frame is
    /// shown at the next frame, when it is long done: the core can already prepare the next frame
    /// while the GPU draws this one. That costs one frame of delay.
    func finishFrame(width usedWidth: Int, height usedHeight: Int, flipped: Bool, into frameBuffer: FrameBuffer) {
        let width = min(usedWidth, width), height = min(usedHeight, height)
        if sharesSurfaces, !surfaces.isEmpty {
            showPending(in: frameBuffer)
            let surface = surfaces[next]
            next = (next + 1) % surfaces.count
            copy(to: surface.framebuffer, width: width, height: height)
            let fence = glFenceSync(GLenum(GL_SYNC_GPU_COMMANDS_COMPLETE), 0)
            glFlush()
            pending = (surface, width, height, flipped, fence)
        } else if let copyBuffer {
            read(width: width, height: height, into: copyBuffer)
            // OpenGL stores the bottom row first; the frame buffer wants the top row first.
            let pitch = width * 4
            let top = flipped ? UnsafeRawPointer(copyBuffer + (height - 1) * pitch) : UnsafeRawPointer(copyBuffer)
            frameBuffer.write(top, width: width, height: height, pitch: flipped ? -pitch : pitch, format: RETRO_PIXEL_FORMAT_XRGB8888)
        }
    }

    private func showPending(in frameBuffer: FrameBuffer) {
        guard let pending else { return }
        self.pending = nil
        if let fence = pending.fence {
            // Normally done long ago; waits at most 100 ms for a GPU that is far behind.
            glClientWaitSync(fence, GLbitfield(GL_SYNC_FLUSH_COMMANDS_BIT), 100_000_000)
            glDeleteSync(fence)
        }
        frameBuffer.publish(pending.surface.pixelBuffer, width: pending.width, height: pending.height, flipped: pending.flipped)
    }

    /// Copies the frame into a surface on the GPU, leaving the state the core set behind as it was.
    private func copy(to target: GLuint, width: Int, height: Int) {
        var readFramebuffer: GLint = 0
        var drawFramebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_READ_FRAMEBUFFER_BINDING), &readFramebuffer)
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &drawFramebuffer)
        // A blit is cut off by the scissor box the core may have left on.
        let scissor = glIsEnabled(GLenum(GL_SCISSOR_TEST)) == GLboolean(GL_TRUE)
        glDisable(GLenum(GL_SCISSOR_TEST))
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), renderFramebuffer)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), target)
        glBlitFramebuffer(0, 0, GLint(width), GLint(height), 0, 0, GLint(width), GLint(height),
                          GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(readFramebuffer))
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), GLuint(drawFramebuffer))
        if scissor {
            glEnable(GLenum(GL_SCISSOR_TEST))
        }
    }

    /// Reads the frame as BGRA, leaving the state the core set behind as it was.
    private func read(width: Int, height: Int, into buffer: UnsafeMutableRawPointer) {
        var readFramebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_READ_FRAMEBUFFER_BINDING), &readFramebuffer)
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), renderFramebuffer)
        glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), buffer)
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(readFramebuffer))
        var image = vImage_Buffer(data: buffer, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        vImagePermuteChannels_ARGB8888(&image, &image, [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
    }

    private func deleteTargets() {
        if let fence = pending?.fence {
            glDeleteSync(fence)
        }
        pending = nil
        for surface in surfaces {
            var framebuffer = surface.framebuffer
            glDeleteFramebuffers(1, &framebuffer)
        }
        surfaces.removeAll()
        if renderFramebuffer != 0 {
            glDeleteFramebuffers(1, &renderFramebuffer)
            glDeleteTextures(1, &renderTexture)
            renderFramebuffer = 0
            renderTexture = 0
        }
        if depthBuffer != 0 {
            glDeleteRenderbuffers(1, &depthBuffer)
            depthBuffer = 0
        }
        copyBuffer?.deallocate()
        copyBuffer = nil
    }

    /// A BGRA surface that both OpenGL ES and Metal can use.
    private static func makeSurface(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferOpenGLESCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer) == kCVReturnSuccess
        else { return nil }
        return pixelBuffer
    }

    private static func texture(for pixelBuffer: CVPixelBuffer, cache: CVOpenGLESTextureCache) -> CVOpenGLESTexture? {
        var texture: CVOpenGLESTexture?
        let result = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, GLenum(GL_TEXTURE_2D), GL_RGBA,
            GLsizei(CVPixelBufferGetWidth(pixelBuffer)), GLsizei(CVPixelBufferGetHeight(pixelBuffer)),
            GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), 0, &texture)
        return result == kCVReturnSuccess ? texture : nil
    }
}
