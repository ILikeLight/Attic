import CoreVideo
import Metal
import QuartzCore

/// Draws the game into frames for a Chromecast, as sharp as on the iPhone (`ScreenRenderer`),
/// and hands each new one to the encoder: at most 60 a second, and twice a second while the
/// picture stands still (paused), so the TV doesn't think the stream stopped.
@MainActor
final class CastCapture {
    /// The size of the frames; the game is enlarged to fit, with black around it.
    static let width = 1280
    static let height = 720

    private let frameBuffer: FrameBuffer
    private let renderer: ScreenRenderer
    private let encoder: CastVideoEncoder
    /// The parts of the picture to show, each with its width over its height: one, or a DS's two screens.
    private let parts: () -> [(region: CGRect, aspect: CGFloat)]
    private var pool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?
    private var link: CADisplayLink?
    private var lastGeneration: UInt64 = .max
    private var lastFrame: CFTimeInterval = 0

    init?(frameBuffer: FrameBuffer, encoder: CastVideoEncoder, parts: @escaping () -> [(region: CGRect, aspect: CGFloat)]) {
        guard let renderer = ScreenRenderer(frameBuffer: frameBuffer) else { return nil }
        self.frameBuffer = frameBuffer
        self.renderer = renderer
        self.encoder = encoder
        self.parts = parts
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Self.width,
            kCVPixelBufferHeightKey: Self.height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &textureCache)
        guard pool != nil, textureCache != nil else { return nil }
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let generation = frameBuffer.read { _, _, _, generation in generation }
        let now = CACurrentMediaTime()
        guard generation != lastGeneration || now - lastFrame > 0.5 else { return }
        var buffer: CVPixelBuffer?
        guard let pool, let textureCache, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        var made: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .bgra8Unorm, Self.width, Self.height, 0, &made) == kCVReturnSuccess,
              let made, let texture = CVMetalTextureGetTexture(made) else { return }
        let time = DispatchTime.now().uptimeNanoseconds
        let encoder = encoder
        let drawn = renderer.render(into: texture, parts: Self.layout(parts())) {
            // `made` keeps the texture alive until the GPU is done with it.
            withExtendedLifetime(made) {
                encoder.encode(buffer, time: time)
            }
        }
        if drawn {
            lastGeneration = generation
            lastFrame = now
        }
    }

    /// Side by side in the middle, as large as fits, 16 points apart at TV size.
    private static func layout(_ parts: [(region: CGRect, aspect: CGFloat)]) -> [(region: CGRect, frame: CGRect)] {
        let width = CGFloat(Self.width), height = CGFloat(Self.height)
        let gap = parts.count > 1 ? width / 120 : 0
        let total = parts.reduce(0) { $0 + $1.aspect }
        guard total > 0 else { return [] }
        let partHeight = min(height, (width - gap * CGFloat(parts.count - 1)) / total).rounded(.down)
        let used = parts.reduce(0) { $0 + ($1.aspect * partHeight).rounded(.down) } + gap * CGFloat(parts.count - 1)
        var x = ((width - used) / 2).rounded(.down)
        let y = ((height - partHeight) / 2).rounded(.down)
        return parts.map { part in
            let partWidth = (part.aspect * partHeight).rounded(.down)
            defer { x += partWidth + gap }
            return (part.region, CGRect(x: x, y: y, width: partWidth, height: partHeight))
        }
    }
}
