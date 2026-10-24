import AtticLibretro
import CoreGraphics
import CoreVideo
import Foundation
import Synchronization
import UIKit

/// The latest video frame of the core, converted to BGRA8 for Metal.
/// Written on the emulation thread, read by the renderer on the main thread.
final class FrameBuffer: @unchecked Sendable {
    /// A frame the GPU drew (see `GLRenderer`), which the screen samples directly.
    struct Surface {
        let pixelBuffer: CVPixelBuffer
        /// OpenGL stores the bottom row first.
        let flipped: Bool
    }

    private let lock = NSLock()
    private var pixels: UnsafeMutablePointer<UInt32>
    private var capacity: Int
    private var surface: Surface?
    private(set) var width = 0
    private(set) var height = 0
    /// Increases with every new frame, so the renderer only uploads changes.
    private(set) var generation: UInt64 = 0

    /// RGB565 → BGRA8 for every possible 16-bit value.
    private static let rgb565: [UInt32] = (0..<65_536).map { value in
        let r = UInt32((value >> 11) & 0x1F)
        let g = UInt32((value >> 5) & 0x3F)
        let b = UInt32(value & 0x1F)
        return 0xFF00_0000 | ((r << 3) | (r >> 2)) << 16 | ((g << 2) | (g >> 4)) << 8 | ((b << 3) | (b >> 2))
    }

    init() {
        capacity = 512 * 512
        pixels = .allocate(capacity: capacity)
        pixels.initialize(repeating: 0xFF00_0000, count: capacity)
    }

    deinit {
        pixels.deallocate()
    }

    /// `redFirst`: 32-bit pixels stored as RGBA instead of BGRA, as a Vulkan core may draw them.
    func write(_ source: UnsafeRawPointer, width: Int, height: Int, pitch: Int, format: retro_pixel_format, redFirst: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        if width * height > capacity {
            pixels.deallocate()
            capacity = width * height
            pixels = .allocate(capacity: capacity)
        }
        self.width = width
        self.height = height
        surface = nil
        Self.rgb565.withUnsafeBufferPointer { table in
            for y in 0..<height {
                let row = source + y * pitch
                let out = pixels + y * width
                switch format {
                case RETRO_PIXEL_FORMAT_XRGB8888 where redFirst:
                    let input = row.assumingMemoryBound(to: UInt32.self)
                    for x in 0..<width {
                        let value = input[x]
                        out[x] = 0xFF00_0000 | (value & 0xFF) << 16 | (value & 0xFF00) | (value >> 16) & 0xFF
                    }
                case RETRO_PIXEL_FORMAT_XRGB8888:
                    let input = row.assumingMemoryBound(to: UInt32.self)
                    for x in 0..<width { out[x] = input[x] | 0xFF00_0000 }
                case RETRO_PIXEL_FORMAT_RGB565:
                    let input = row.assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width { out[x] = table[Int(input[x])] }
                default:
                    // 0RGB1555
                    let input = row.assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        let value = input[x]
                        let r = UInt32((value >> 10) & 0x1F), g = UInt32((value >> 5) & 0x1F), b = UInt32(value & 0x1F)
                        out[x] = 0xFF00_0000 | (r << 3 | r >> 2) << 16 | (g << 3 | g >> 2) << 8 | (b << 3 | b >> 2)
                    }
                }
            }
        }
        generation &+= 1
    }

    /// A frame the GPU drew; `width` and `height` are the part of the surface the core used.
    func publish(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int, flipped: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.width = width
        self.height = height
        surface = Surface(pixelBuffer: pixelBuffer, flipped: flipped)
        generation &+= 1
    }

    /// Gives the renderer the current frame while the lock is held.
    func read<Result>(_ body: (UnsafePointer<UInt32>, Int, Int, UInt64) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(pixels, width, height, generation)
    }

    /// The current frame if the GPU drew it.
    func readSurface() -> (surface: Surface, width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return surface.map { ($0, width, height) }
    }

    /// The current frame as an image, for save-state thumbnails and screenshots.
    /// `region` picks a part of the picture in fractions, such as the top screen of the DS.
    func image(scale: Int = 1, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> UIImage? {
        if let (surface, width, height) = readSurface() {
            let buffer = surface.pixelBuffer
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            return Self.image(width: width, height: height, scale: scale, region: region) { row in
                let stored = surface.flipped ? height - 1 - row : row
                return UnsafePointer((base + stored * bytesPerRow).assumingMemoryBound(to: UInt32.self))
            }
        }
        return read { pixels, width, height, _ in
            Self.image(width: width, height: height, scale: scale, region: region) { UnsafePointer(pixels + $0 * width) }
        }
    }

    /// Copies a region of a picture; `row` gives the pixels of each row, top row first.
    private static func image(width fullWidth: Int, height fullHeight: Int, scale: Int, region: CGRect,
                              row: (Int) -> UnsafePointer<UInt32>) -> UIImage? {
        guard fullWidth > 0, fullHeight > 0 else { return nil }
        let left = Int(region.minX * CGFloat(fullWidth))
        let top = Int(region.minY * CGFloat(fullHeight))
        let width = max(1, Int(region.width * CGFloat(fullWidth)))
        let height = max(1, Int(region.height * CGFloat(fullHeight)))
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let out = buffer.baseAddress!.assumingMemoryBound(to: UInt32.self)
            for y in 0..<height {
                (out + y * width).update(from: row(top + y) + left, count: width)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        guard scale > 1 else { return UIImage(cgImage: image) }
        let size = CGSize(width: width * scale, height: height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Which buttons are held, from touch, game controllers and the keyboard.
/// Read once per frame on the emulation thread.
final class InputState: Sendable {
    enum Source {
        /// `motion` is a shake of the iPhone, the Wii Remote's shake.
        case touch, controller, keyboard, motion
    }

    private let touch = Atomic<UInt32>(0)
    private let controller = Atomic<UInt32>(0)
    private let keyboard = Atomic<UInt32>(0)
    private let motion = Atomic<UInt32>(0)
    /// Buttons pressed since the last frame, so a tap shorter than one frame still counts.
    private let latched = Atomic<UInt32>(0)

    func set(_ mask: UInt32, from source: Source) {
        let previous = switch source {
        case .touch: touch.exchange(mask, ordering: .relaxed)
        case .controller: controller.exchange(mask, ordering: .relaxed)
        case .keyboard: keyboard.exchange(mask, ordering: .relaxed)
        case .motion: motion.exchange(mask, ordering: .relaxed)
        }
        let pressed = mask & ~previous
        if pressed != 0 {
            latched.bitwiseOr(pressed, ordering: .relaxed)
        }
    }

    /// The buttons for the next frame: everything held now plus short taps since the last frame.
    func nextFrameMask() -> UInt32 {
        let held = touch.load(ordering: .relaxed) | controller.load(ordering: .relaxed) | keyboard.load(ordering: .relaxed)
            | motion.load(ordering: .relaxed)
        return held | latched.exchange(0, ordering: .relaxed)
    }

    func clear() {
        touch.store(0, ordering: .relaxed)
        controller.store(0, ordering: .relaxed)
        keyboard.store(0, ordering: .relaxed)
        motion.store(0, ordering: .relaxed)
        latched.store(0, ordering: .relaxed)
        pointer.store(0, ordering: .relaxed)
        pointerLatched.store(0, ordering: .relaxed)
        touchStick.store(0, ordering: .relaxed)
        controllerStick.store(0, ordering: .relaxed)
        controllerRightStick.store(0, ordering: .relaxed)
        touchRightStick.store(0, ordering: .relaxed)
    }

    // MARK: Analog sticks

    enum Stick {
        case left, right
    }

    /// A stick position: x in bits 0–15 and y in bits 16–31, as Int16 from -0x7FFF to 0x7FFF.
    private let touchStick = Atomic<UInt32>(0)
    private let controllerStick = Atomic<UInt32>(0)
    /// On screen the N64's C buttons stand in for the right stick, and a finger on the
    /// picture moves it for the Wii Remote's pointer.
    private let controllerRightStick = Atomic<UInt32>(0)
    private let touchRightStick = Atomic<UInt32>(0)

    /// `x` and `y` run from -1 to 1; y points down, as in libretro.
    func setStick(_ stick: Stick, x: Double, y: Double, from source: Source) {
        let packed = UInt32(UInt16(bitPattern: Int16(min(max(x, -1), 1) * 0x7FFF)))
            | UInt32(UInt16(bitPattern: Int16(min(max(y, -1), 1) * 0x7FFF))) << 16
        switch (stick, source) {
        case (.left, .touch): touchStick.store(packed, ordering: .relaxed)
        case (.left, .controller): controllerStick.store(packed, ordering: .relaxed)
        case (.right, .controller): controllerRightStick.store(packed, ordering: .relaxed)
        case (.right, .touch): touchRightStick.store(packed, ordering: .relaxed)
        default: break
        }
    }

    /// Both sticks for the next frame; a controller stick that is pushed wins over the touch stick.
    func nextFrameSticks() -> (left: SIMD2<Int16>, right: SIMD2<Int16>) {
        let controller = controllerStick.load(ordering: .relaxed)
        let left = controller != 0 ? controller : touchStick.load(ordering: .relaxed)
        let controllerRight = controllerRightStick.load(ordering: .relaxed)
        let right = controllerRight != 0 ? controllerRight : touchRightStick.load(ordering: .relaxed)
        return (Self.unpack(left), Self.unpack(right))
    }

    private static func unpack(_ value: UInt32) -> SIMD2<Int16> {
        SIMD2(Int16(bitPattern: UInt16(value & 0xFFFF)), Int16(bitPattern: UInt16(value >> 16)))
    }

    // MARK: Touch screen

    /// A finger on a touch screen (the DS), as a position in the core's whole picture.
    struct Pointer {
        /// 0 is the left or top edge of the picture, 0xFFFF the right or bottom edge.
        var x: UInt16 = 0
        var y: UInt16 = 0
        var pressed = false
    }

    /// x in bits 0–15, y in bits 16–31, pressed in bit 32.
    private let pointer = Atomic<UInt64>(0)
    /// A touch that started since the last frame, kept so a quick tap is still seen.
    private let pointerLatched = Atomic<UInt64>(0)

    /// `x` and `y` run from 0 to 1 across the whole picture of the core.
    func setPointer(x: Double, y: Double, pressed: Bool) {
        let packedX = UInt64(min(max(x, 0), 1) * 0xFFFF)
        let packedY = UInt64(min(max(y, 0), 1) * 0xFFFF)
        let value = packedX | packedY << 16 | (pressed ? 1 << 32 : 0)
        let previous = pointer.exchange(value, ordering: .relaxed)
        if pressed && previous & (1 << 32) == 0 {
            pointerLatched.store(value, ordering: .relaxed)
        }
    }

    func nextFramePointer() -> Pointer {
        var value = pointer.load(ordering: .relaxed)
        let latched = pointerLatched.exchange(0, ordering: .relaxed)
        if value & (1 << 32) == 0 && latched != 0 {
            value = latched
        }
        return Pointer(x: UInt16(value & 0xFFFF), y: UInt16((value >> 16) & 0xFFFF), pressed: value & (1 << 32) != 0)
    }
}
