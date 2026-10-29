import MetalKit
import SwiftUI

/// Shows the core's frames with Metal.
///
/// Pixels stay sharp without uneven widths: the shader enlarges each pixel by a
/// whole factor and only blends the one-pixel seams ("sharp bilinear").
struct MetalScreen: UIViewRepresentable {
    let frameBuffer: FrameBuffer
    /// The part of the core's picture to show, in fractions (for the DS: one of its two screens).
    var region = CGRect(x: 0, y: 0, width: 1, height: 1)

    func makeCoordinator() -> ScreenRenderer? {
        ScreenRenderer(frameBuffer: frameBuffer)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator?.region = region
    }

    static func dismantleUIView(_ view: MTKView, coordinator: ScreenRenderer?) {
        view.isPaused = true
        view.delegate = nil
    }
}

final class ScreenRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let frameBuffer: FrameBuffer
    private var texture: MTLTexture?
    private var uploadedGeneration: UInt64 = .max
    /// Metal views of the surfaces a GPU core draws into (see `GLRenderer`).
    private var textureCache: CVMetalTextureCache?
    private var surfaceTextures: [ObjectIdentifier: CVMetalTexture] = [:]
    var region = CGRect(x: 0, y: 0, width: 1, height: 1)

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut screen_vertex(uint id [[vertex_id]]) {
        const float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        const float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        VertexOut out;
        out.position = float4(positions[id], 0, 1);
        out.uv = uvs[id];
        return out;
    }

    fragment float4 screen_fragment(VertexOut in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    sampler linearSampler [[sampler(0)]],
                                    constant float2 &outputSize [[buffer(0)]],
                                    constant float4 &shown [[buffer(1)]],
                                    constant uint &flipped [[buffer(2)]]) {
        float2 size = float2(source.get_width(), source.get_height());
        float2 uv = flipped ? float2(in.uv.x, 1.0 - in.uv.y) : in.uv;
        float2 texel = (shown.xy + uv * shown.zw) * size;
        float2 scale = max(floor(outputSize / (size * shown.zw)), float2(1.0));
        float2 region = 0.5 - 0.5 / scale;
        float2 centered = fract(texel) - 0.5;
        float2 offset = (centered - clamp(centered, -region, region)) * scale + 0.5;
        // Stay inside the shown part, so the DS screens don't bleed into each other.
        float2 position = clamp(floor(texel) + offset, shown.xy * size + 0.5, (shown.xy + shown.zw) * size - 0.5);
        return source.sample(linearSampler, position / size);
    }
    """

    init?(frameBuffer: FrameBuffer) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screen_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screen_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        self.frameBuffer = frameBuffer
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let source = currentSource(), let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        draw(source, region: region, outputSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)), with: encoder)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    /// Draws the current frame into `target` (for a Chromecast): each region of the picture in its
    /// own rectangle of it, in pixels, on black. `done` runs once the GPU has finished.
    func render(into target: MTLTexture, parts: [(region: CGRect, frame: CGRect)], done: @escaping () -> Void) -> Bool {
        guard let source = currentSource(), let commands = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        for part in parts {
            encoder.setViewport(MTLViewport(originX: part.frame.minX, originY: part.frame.minY, width: part.frame.width,
                                            height: part.frame.height, znear: 0, zfar: 1))
            draw(source, region: part.region, outputSize: SIMD2(Float(part.frame.width), Float(part.frame.height)), with: encoder)
        }
        encoder.endEncoding()
        commands.addCompletedHandler { _ in done() }
        commands.commit()
        return true
    }

    private struct Source {
        let texture: MTLTexture
        /// The part of the texture the picture uses, and whether its rows are stored bottom-up.
        let used: SIMD2<Float>
        let flipped: UInt32
    }

    /// The current frame as a texture, uploaded if it is new.
    private func currentSource() -> Source? {
        var source: MTLTexture?
        var used = SIMD2<Float>(1, 1)
        var flipped: UInt32 = 0
        if let (surface, width, height) = frameBuffer.readSurface() {
            let pixelBuffer = surface.pixelBuffer
            source = texture(for: pixelBuffer)
            used = SIMD2(Float(width) / Float(CVPixelBufferGetWidth(pixelBuffer)), Float(height) / Float(CVPixelBufferGetHeight(pixelBuffer)))
            flipped = surface.flipped ? 1 : 0
        } else {
            frameBuffer.read { pixels, width, height, generation in
                guard width > 0, height > 0 else { return }
                if texture?.width != width || texture?.height != height {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                    descriptor.usage = .shaderRead
                    texture = device.makeTexture(descriptor: descriptor)
                    uploadedGeneration = .max
                }
                if generation != uploadedGeneration {
                    texture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
                    uploadedGeneration = generation
                }
            }
            source = texture
        }
        return source.map { Source(texture: $0, used: used, flipped: flipped) }
    }

    /// Draws `region` of the picture into the encoder's viewport, which is `outputSize` pixels.
    private func draw(_ source: Source, region: CGRect, outputSize: SIMD2<Float>, with encoder: MTLRenderCommandEncoder) {
        var outputSize = outputSize
        var flipped = source.flipped
        let used = source.used
        // A bottom-up picture keeps its top rows at the end of the used part.
        let top = flipped == 1 ? 1 - region.maxY : region.minY
        var shown = SIMD4<Float>(Float(region.minX) * used.x, Float(top) * used.y, Float(region.width) * used.x, Float(region.height) * used.y)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&outputSize, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentBytes(&shown, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.setFragmentBytes(&flipped, length: MemoryLayout<UInt32>.size, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// A Metal texture over a GPU core's surface; made once per surface.
    private func texture(for pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let key = ObjectIdentifier(pixelBuffer)
        if let cached = surfaceTextures[key] {
            return CVMetalTextureGetTexture(cached)
        }
        guard let textureCache else { return nil }
        var made: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
                                                        CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
                                                        0, &made) == kCVReturnSuccess,
              let made else { return nil }
        // A new game brings new surfaces; the cached textures keep the old ones alive until then.
        if surfaceTextures.count >= 6 {
            surfaceTextures.removeAll()
        }
        surfaceTextures[key] = made
        return CVMetalTextureGetTexture(made)
    }
}
