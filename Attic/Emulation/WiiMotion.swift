import CoreMotion
import Synchronization

/// The iPhone's accelerometer as the Wii Remote's, so tilting, swinging and shaking the iPhone
/// does the same to the Wii Remote. Dolphin reads it through libretro's sensor interface
/// (`LibretroCore`), in g along the Wii Remote's axes: +X its left side, +Y its back (towards
/// the player), +Z up out of its buttons. For a sideways Wii Remote Dolphin turns the values a
/// quarter itself, so there they stay along the screen: right, up, out.
///
/// How the iPhone leans back when the game starts or goes on, or the screen turns, counts as the
/// Wii Remote held level, so it can be held as is comfortable. From there, raising the iPhone's top
/// (or its back, held upright) raises the Wii Remote's tip, as with the pointer (`TiltPointer`).
/// The gyroscope is left out: with it Dolphin would also turn the pointer, which follows the
/// finger or `TiltPointer` instead.
@MainActor
final class WiiMotion {
    /// The latest reading, read by the emulation thread. Until the first one: held level.
    nonisolated let reading: Mutex<SIMD3<Float>>
    nonisolated let isAvailable: Bool

    private let sideways: Bool
    /// A Wii Remote that is not sideways in Dolphin is held sideways now; how it is held anew counts as level.
    var heldSideways = false {
        didSet { lean = nil }
    }
    /// How far the screen leans back from upright when level was taken; nil takes it again.
    private var lean: Double?

    init(sideways: Bool) {
        self.sideways = sideways
        reading = Mutex(sideways ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1))
        isAvailable = DeviceMotion.shared.isAvailable
    }

    func start() {
        lean = nil
        DeviceMotion.shared.add(self) { [weak self] sample in
            self?.update(sample)
        }
    }

    func stop() {
        DeviceMotion.shared.remove(self)
    }

    /// How the iPhone is held now counts as the Wii Remote held level from here on.
    func level() {
        lean = nil
    }

    private func update(_ sample: DeviceMotion.Sample) {
        let data = sample.data
        if sample.turned {
            lean = nil
        }
        // What an accelerometer measures: the push that holds the iPhone up, plus how it is moved.
        // Core Motion reports gravity itself, pointing down.
        let force = SIMD3(-(data.gravity.x + data.userAcceleration.x),
                          -(data.gravity.y + data.userAcceleration.y),
                          -(data.gravity.z + data.userAcceleration.z))

        // Along the screen as it is turned: right, up and out towards the player.
        let up = sample.up
        var screen = SIMD3((force * sample.right).sum(), (force * up).sum(), force.z)

        // Leaning back about the screen's horizontal axis, undone so that holding it this way is level.
        let gravity = SIMD3(-data.gravity.x, -data.gravity.y, -data.gravity.z)
        let lean = lean ?? atan2(gravity.z, (gravity * up).sum())
        self.lean = lean
        screen = SIMD3(screen.x,
                       screen.y * cos(lean) + screen.z * sin(lean),
                       -screen.y * sin(lean) + screen.z * cos(lean))

        let remote = if sideways {
            screen  // Dolphin turns it itself
        } else if heldSideways {
            // Its tip to the left and its buttons towards the player, as Dolphin turns a sideways one.
            SIMD3(-screen.y, screen.x, screen.z)
        } else {
            SIMD3(-screen.x, screen.z, screen.y)
        }
        reading.withLock { $0 = SIMD3<Float>(remote) }
    }
}
