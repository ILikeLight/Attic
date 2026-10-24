import Compression
import Foundation

/// Save states taken every few frames, so the game can be wound back.
///
/// The emulation thread hands over each state; compressing it with LZ4 happens on a
/// background queue. Small states are kept ten times a second, large ones (DS, N64)
/// less often, up to a minute back and at most `budget` bytes in all.
final class RewindBuffer: @unchecked Sendable {
    private struct Snapshot {
        let data: Data
        let size: Int
        let compressed: Bool
    }

    /// Frames between two snapshots.
    let interval: Int
    private let maxSnapshots: Int
    private let budget = 96 << 20
    private var snapshots: [Snapshot] = []
    private var bytes = 0
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.attic.rewind", qos: .utility)

    init(stateSize: Int, framesPerSecond: Double) {
        let fps = max(framesPerSecond, 1)
        interval = switch stateSize {
        case ..<(1 << 20): max(1, Int(fps / 10))
        case ..<(8 << 20): max(1, Int(fps / 4))
        default: max(1, Int(fps / 2))
        }
        maxSnapshots = Int(60 * fps) / interval
    }

    func push(_ state: Data) {
        queue.async { [self] in
            let snapshot = Self.compress(state)
            lock.lock()
            snapshots.append(snapshot)
            bytes += snapshot.data.count
            while !snapshots.isEmpty && (bytes > budget || snapshots.count > maxSnapshots) {
                bytes -= snapshots.removeFirst().data.count
            }
            lock.unlock()
        }
    }

    /// The newest snapshot, taken out of the buffer; nil when there is nothing left to go back to.
    func pop() -> Data? {
        queue.sync {}   // states still being compressed come first
        lock.lock()
        let snapshot = snapshots.popLast()
        if let snapshot { bytes -= snapshot.data.count }
        lock.unlock()
        return snapshot.flatMap(Self.decompress)
    }

    func clear() {
        queue.sync {}
        lock.lock()
        snapshots.removeAll()
        bytes = 0
        lock.unlock()
    }

    private static func compress(_ state: Data) -> Snapshot {
        let capacity = state.count + state.count / 255 + 64
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            state.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, state.count, nil, COMPRESSION_LZ4)
            }
        }
        guard written > 0 else { return Snapshot(data: state, size: state.count, compressed: false) }
        output.count = written
        return Snapshot(data: output, size: state.count, compressed: true)
    }

    private static func decompress(_ snapshot: Snapshot) -> Data? {
        guard snapshot.compressed else { return snapshot.data }
        var output = Data(count: snapshot.size)
        let written = output.withUnsafeMutableBytes { destination in
            snapshot.data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, snapshot.size,
                                          source.bindMemory(to: UInt8.self).baseAddress!, snapshot.data.count, nil, COMPRESSION_LZ4)
            }
        }
        return written == snapshot.size ? output : nil
    }
}
