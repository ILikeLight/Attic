import CoreMotion

/// Points the Wii Remote by pointing the iPhone, as with a real one: turning it left or right moves
/// the pointer sideways, raising or lowering its top (or its back, held upright) moves it up or down.
/// The gyroscope's turns are added up from the middle of the picture, so it works however the iPhone
/// is held; at an edge the pointer stays, and turning back moves it at once. Dolphin reads the right
/// stick as the pointer's position.
@MainActor
final class TiltPointer {
    /// How far to turn the iPhone from the middle to an edge of the picture, sideways and up or down:
    /// about 20° and 15°, so a turn moves the pointer as far either way on a 4:3 picture.
    private let range = SIMD2(0.35, 0.26)
    private var position = SIMD2<Double>.zero
    private var lastTime: TimeInterval?
    private var input: InputState?

    func start(_ input: InputState) {
        self.input = input
        position = .zero
        lastTime = nil
        input.setStick(.right, x: 0, y: 0, from: .touch)
        DeviceMotion.shared.add(self) { [weak self] sample in
            self?.update(sample, input: input)
        }
    }

    func stop() {
        DeviceMotion.shared.remove(self)
        input = nil
    }

    /// Where the iPhone points now becomes the middle of the picture again. Adding up the turns
    /// drifts a little over time, and turning past an edge shifts the middle too.
    func recenter() {
        position = .zero
        input?.setStick(.right, x: 0, y: 0, from: .touch)
    }

    private func update(_ sample: DeviceMotion.Sample, input: InputState) {
        let data = sample.data
        defer { lastTime = data.timestamp }
        guard let lastTime else { return }
        let step = data.timestamp - lastTime
        guard step > 0, step < 0.1 else { return }

        let rate = SIMD3(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z)
        let gravity = SIMD3(data.gravity.x, data.gravity.y, data.gravity.z)
        let length = (gravity * gravity).sum().squareRoot()
        guard length > 0 else { return }
        // Turning about up in the world turns the iPhone left (right-handed); turning about the
        // screen's right raises its top, or its back when it is held upright.
        let left = (rate * -gravity / length).sum()
        let raise = (rate * sample.right).sum()
        // Dolphin points up and left for a negative stick.
        position.x = min(max(position.x - left * step / range.x, -1), 1)
        position.y = min(max(position.y - raise * step / range.y, -1), 1)
        input.setStick(.right, x: position.x, y: position.y, from: .touch)
    }
}
