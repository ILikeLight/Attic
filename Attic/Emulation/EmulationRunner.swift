import Foundation
import QuartzCore

/// Runs the core on its own thread at the core's frame rate.
///
/// libretro cores are not thread-safe, so everything that touches the core
/// (save states, battery saves) is sent to this thread with `perform`.
final class EmulationRunner: Thread, @unchecked Sendable {
    private let condition = NSCondition()
    private var commands: [() -> Void] = []
    private var paused = true
    private var stopping = false
    private var speed = 1
    private var rewinding = false

    private let core: LibretroCore
    /// Waits as long as the game time in each frame's sound instead of one frame time
    /// (see `CoreProfile.pacesByAudio`).
    private let pacesByAudio: Bool
    /// Set on the emulation thread once the game is loaded; nil when rewinding is off.
    var rewind: RewindBuffer?
    private var framesSinceSnapshot = 0
    private var framesSinceStep = 0
    /// Time waited for frames whose sound had not come in yet, taken off when it comes (`pacesByAudio`).
    private var waitedAhead = 0.0

    init(core: LibretroCore, pacesByAudio: Bool = false) {
        self.core = core
        self.pacesByAudio = pacesByAudio
        super.init()
        name = "Attic emulation"
        qualityOfService = .userInteractive
    }

    override func main() {
        var nextFrame = CACurrentMediaTime()
        while true {
            condition.lock()
            while commands.isEmpty && paused && !stopping {
                condition.wait()
            }
            let pending = commands
            commands.removeAll()
            let isPaused = paused
            let isStopping = stopping
            let frames = speed
            let isRewinding = rewinding
            condition.unlock()

            pending.forEach { $0() }
            if isStopping { break }
            if isPaused {
                nextFrame = CACurrentMediaTime()
                continue
            }

            var gameTime = 1 / core.framesPerSecond
            if isRewinding, let rewind {
                stepBack(rewind)
            } else {
                var played = 0.0
                for frame in 0..<frames {
                    // Only the first frame is heard, so fast-forward keeps normal pitch.
                    core.audioEnabled = frame == 0
                    core.runFrame()
                    played += pacesByAudio ? gameTimeBySound() : 1 / core.framesPerSecond
                    takeSnapshot()
                }
                core.audioEnabled = true
                framesSinceStep = .max
                gameTime = played / Double(frames)
            }

            nextFrame += gameTime
            let now = CACurrentMediaTime()
            if nextFrame > now {
                Thread.sleep(forTimeInterval: nextFrame - now)
            } else if now - nextFrame > 0.25 {
                // Too far behind (e.g. after a hiccup); don't try to catch up.
                nextFrame = now
            }
        }
        core.unload()
    }

    /// The game time the sound sent since the last frame covers. A frame whose sound has not come in
    /// yet waits a frame time ahead, at most two frames' worth, which is taken off when the sound comes.
    /// (Dolphin reports its frame rate before the game sets it, so that time can be off.)
    private func gameTimeBySound() -> Double {
        let sound = Double(core.takeAudioFrames()) / core.sampleRate
        guard sound > 0 else {
            let frame = 1 / core.framesPerSecond
            waitedAhead = min(waitedAhead + frame, 2 * frame)
            return frame
        }
        let settled = min(waitedAhead, sound)
        waitedAhead -= settled
        return sound - settled
    }

    func setPaused(_ value: Bool) {
        condition.lock()
        paused = value
        condition.signal()
        condition.unlock()
    }

    /// Frames emulated per real frame: 1 is normal speed, 2 is fast-forward.
    func setSpeed(_ value: Int) {
        condition.lock()
        speed = max(1, value)
        condition.unlock()
    }

    /// While on, the game runs backwards through the rewind snapshots.
    func setRewinding(_ value: Bool) {
        condition.lock()
        rewinding = value
        condition.unlock()
    }

    private func takeSnapshot() {
        guard let rewind else { return }
        framesSinceSnapshot += 1
        guard framesSinceSnapshot >= rewind.interval else { return }
        framesSinceSnapshot = 0
        if let state = core.serialize() {
            rewind.push(state)
        }
    }

    /// Goes back one snapshot every few frames, three times as fast as the game ran.
    /// At the oldest snapshot the picture stands still.
    private func stepBack(_ rewind: RewindBuffer) {
        framesSinceStep = framesSinceStep == .max ? .max : framesSinceStep + 1
        guard framesSinceStep >= max(1, rewind.interval / 3), let state = rewind.pop() else { return }
        framesSinceStep = 0
        framesSinceSnapshot = 0
        _ = core.unserialize(state)
        // One silent frame shows the picture of that moment.
        core.audioEnabled = false
        core.runFrame()
        core.audioEnabled = true
    }

    func perform(_ command: @escaping () -> Void) {
        condition.lock()
        commands.append(command)
        condition.signal()
        condition.unlock()
    }

    /// Runs a command on the emulation thread and waits for its result.
    func performAndWait<Result>(_ command: @escaping () -> Result) async -> Result {
        await withCheckedContinuation { continuation in
            perform { continuation.resume(returning: command()) }
        }
    }

    /// Stops the thread after it ran the queued commands; the core is unloaded there.
    func stop() {
        condition.lock()
        stopping = true
        condition.signal()
        condition.unlock()
    }
}
