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

    /// The frames since the port was last cleared, for `LinkMonitor`: all of them, those that got
    /// no new message, and those that got two or more (of which only the last one counts).
    struct FrameCount: Equatable {
        var frames = 0
        var empty = 0
        var crowded = 0
    }

    private struct Port {
        var pad = Pad()
        /// Messages since the last frame.
        var messages = 0
        var count = FrameCount()
    }

    /// Ports 1 to 3 (players 2 to 4).
    private let ports = Mutex([Port](repeating: Port(), count: 3))

    func set(port: Int, mask: UInt32, left: SIMD2<Int16>, right: SIMD2<Int16>, motion: SIMD3<Float>) {
        guard (1...3).contains(port) else { return }
        ports.withLock { ports in
            let pressed = mask & ~ports[port - 1].pad.held
            ports[port - 1].pad.held = mask
            ports[port - 1].pad.latched |= pressed
            ports[port - 1].pad.left = left
            ports[port - 1].pad.right = right
            ports[port - 1].pad.motion = motion
            ports[port - 1].messages += 1
        }
    }

    func clear(port: Int) {
        guard (1...3).contains(port) else { return }
        ports.withLock { $0[port - 1] = Port() }
    }

    /// Ports 1 to 3 for the next frame, with the taps since the last one.
    func nextFrame() -> [Pad] {
        ports.withLock { ports in
            let frame = ports.map { port in
                var pad = port.pad
                pad.held |= pad.latched
                return pad
            }
            for index in ports.indices {
                ports[index].pad.latched = 0
                ports[index].count.frames += 1
                if ports[index].messages == 0 {
                    ports[index].count.empty += 1
                } else if ports[index].messages > 1 {
                    ports[index].count.crowded += 1
                }
                ports[index].messages = 0
            }
            return frame
        }
    }

    /// Ports 1 to 3.
    func frameCounts() -> [FrameCount] {
        ports.withLock { $0.map(\.count) }
    }
}
