import Synchronization

/// The buttons and sticks of players 2 to 4, who play from another iPhone (`MultiplayerHost`).
/// The network sets them as they come in; the emulation thread reads them once per frame.
final class RemotePlayers: Sendable {
    struct Pad {
        var held: UInt32 = 0
        /// Buttons pressed since the last frame, so a tap shorter than one frame still counts.
        var latched: UInt32 = 0
        var left = SIMD2<Int16>.zero
        var right = SIMD2<Int16>.zero
        /// A Wii Remote's accelerometer from that iPhone (`WiiMotion`); zero when it sends none.
        var motion = SIMD3<Float>.zero
    }

    /// Ports 1 to 3 (players 2 to 4).
    private let pads = Mutex([Pad](repeating: Pad(), count: 3))

    func set(port: Int, mask: UInt32, left: SIMD2<Int16>, right: SIMD2<Int16>, motion: SIMD3<Float>) {
        guard (1...3).contains(port) else { return }
        pads.withLock { pads in
            let pressed = mask & ~pads[port - 1].held
            pads[port - 1].held = mask
            pads[port - 1].latched |= pressed
            pads[port - 1].left = left
            pads[port - 1].right = right
            pads[port - 1].motion = motion
        }
    }

    func clear(port: Int) {
        guard (1...3).contains(port) else { return }
        pads.withLock { $0[port - 1] = Pad() }
    }

    /// Ports 1 to 3 for the next frame, with the taps since the last one.
    func nextFrame() -> [Pad] {
        pads.withLock { pads in
            let frame = pads.map { pad in
                var pad = pad
                pad.held |= pad.latched
                return pad
            }
            for index in pads.indices {
                pads[index].latched = 0
            }
            return frame
        }
    }
}
