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

    private let manager = CMMotionManager()
    private var listeners: [ObjectIdentifier: (Sample) -> Void] = [:]
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

    private func deliver(_ data: CMDeviceMotion) {
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
