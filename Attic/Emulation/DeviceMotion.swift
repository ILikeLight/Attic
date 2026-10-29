import CoreMotion
import UIKit

/// The app's one motion manager (Apple advises one per app), shared by the Wii Remote's movement
/// (`WiiMotion`) and its pointer (`TiltPointer`): the iPhone's motion on the main queue, with the
/// screen's axes as the interface is turned.
@MainActor
final class DeviceMotion {
    static let shared = DeviceMotion()

    struct Sample {
        let data: CMDeviceMotion
        /// The screen's right and up, in the iPhone's own axes (its out is always +Z).
        let right: SIMD3<Double>
        let up: SIMD3<Double>
        /// The interface was turned since the previous sample.
        let turned: Bool
    }

    /// How the readings reach the app, for Prestaties tonen: per second, and how long after the
    /// sensor took them, in milliseconds. A busy main thread holds them up.
    struct Delivery {
        var perSecond: Double
        var lateness95: Double
        var latenessMax: Double
    }

    private let manager = CMMotionManager()
    private var listeners: [ObjectIdentifier: (Sample) -> Void] = [:]
    /// The lateness of each reading since `delivery()` was last called, in seconds.
    private var lateness: [Double] = []
    private var lastDelivery = ProcessInfo.processInfo.systemUptime
    private weak var scene: UIWindowScene?
    private var orientation: UIInterfaceOrientation?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func add(_ listener: AnyObject, _ handler: @escaping (Sample) -> Void) {
        guard isAvailable else { return }
        listeners[ObjectIdentifier(listener)] = handler
        guard !manager.isDeviceMotionActive else { return }
        scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }
        orientation = nil
        manager.deviceMotionUpdateInterval = 1.0 / 100
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let data else { return }
            MainActor.assumeIsolated {
                self?.deliver(data)
            }
        }
    }

    func remove(_ listener: AnyObject) {
        listeners[ObjectIdentifier(listener)] = nil
        if listeners.isEmpty {
            manager.stopDeviceMotionUpdates()
        }
    }

    /// The readings since the previous call; nil when none came.
    func delivery() -> Delivery? {
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            lateness = []
            lastDelivery = now
        }
        guard !lateness.isEmpty else { return nil }
        let sorted = lateness.sorted()
        return Delivery(perSecond: Double(sorted.count) / max(now - lastDelivery, 0.001),
                        lateness95: sorted[Int((Double(sorted.count - 1) * 0.95).rounded())] * 1000,
                        latenessMax: sorted[sorted.count - 1] * 1000)
    }

    private func deliver(_ data: CMDeviceMotion) {
        // Both count from the iPhone's start. Started over every ten seconds or so when nobody asks.
        let now = ProcessInfo.processInfo.systemUptime
        if lateness.count >= 1_000 {
            lateness.removeAll(keepingCapacity: true)
            lastDelivery = now
        }
        lateness.append(now - data.timestamp)
        let current = scene?.effectiveGeometry.interfaceOrientation ?? .portrait
        let turned = orientation != nil && current != orientation
        orientation = current
        let (right, up): (SIMD3<Double>, SIMD3<Double>) = switch current {
        case .portraitUpsideDown: ([-1, 0, 0], [0, -1, 0])
        case .landscapeRight: ([0, -1, 0], [1, 0, 0])
        case .landscapeLeft: ([0, 1, 0], [-1, 0, 0])
        default: ([1, 0, 0], [0, 1, 0])
        }
        let sample = Sample(data: data, right: right, up: up, turned: turned)
        for listener in listeners.values {
            listener(sample)
        }
    }
}
