import AVFoundation
import Synchronization

/// Lock-free ring buffer of interleaved stereo samples: one writer (the
/// emulation thread) and one reader (the audio thread).
final class AudioRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Int16>
    private let capacity: Int
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    var available: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
    }

    /// Writes as many samples as fit; the rest is dropped.
    func write(_ samples: UnsafePointer<Int16>, count: Int) {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let amount = min(count, capacity - (write - read))
        guard amount > 0 else { return }
        for index in 0..<amount {
            buffer[(write + index) % capacity] = samples[index]
        }
        writeIndex.store(write + amount, ordering: .releasing)
    }

    func read(into destination: UnsafeMutablePointer<Int16>, count: Int) -> Int {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let amount = min(count, write - read)
        guard amount > 0 else { return 0 }
        for index in 0..<amount {
            destination[index] = buffer[(read + index) % capacity]
        }
        readIndex.store(read + amount, ordering: .releasing)
        return amount
    }

    func clear() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}

/// Plays the core's 16-bit stereo audio through AVAudioEngine, which also
/// converts the core's sample rate (65,536 Hz for the GBA) to the device rate.
final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var ring = AudioRingBuffer(capacity: 2)
    private var scratch: UnsafeMutablePointer<Int16>?
    private(set) var sampleRate: Double = 0
    private var maxLatencySamples = 0
    /// The game is running, so sound should play; set on the main thread.
    private var isPlaying = false
    /// Plays also when the iPhone is on silent; set on the main thread.
    var playsWhenSilent = false {
        didSet {
            if isPlaying && playsWhenSilent != oldValue {
                activateSession()
            }
        }
    }
    private var observers: [NSObjectProtocol] = []

    init() {
        // iOS stops the engine when the output changes (AirPods or headphones in or out) and
        // for an interruption (a call, Siri); while the game runs, it plays on afterwards.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restartIfPlaying()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.restartIfPlaying()
        })
    }

    private func restartIfPlaying() {
        guard isPlaying else { return }
        ring.clear()
        start()
    }

    func configure(sampleRate: Double) {
        // The session before the graph, as Apple recommends. The other way round, the Simulator
        // sets up the audio device in the middle of the engine's set-up, just as CoreAudio starts
        // a system sound of its own, and the two can deadlock.
        activateSession()
        stop()
        if let node = sourceNode {
            engine.detach(node)
        }
        self.sampleRate = sampleRate
        // About 150 ms of room; normally only one or two frames are queued.
        let capacity = Int(sampleRate * 0.15) * 2
        ring = AudioRingBuffer(capacity: capacity)
        maxLatencySamples = Int(sampleRate * 0.08) * 2
        scratch?.deallocate()
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 8192 * 2)
        self.scratch = scratch

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let ring = ring
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let frames = min(Int(frameCount), 8192)
            let received = ring.read(into: scratch, count: frames * 2) / 2
            for frame in 0..<received {
                left[frame] = Float(scratch[frame * 2]) / 32_768
                right[frame] = Float(scratch[frame * 2 + 1]) / 32_768
            }
            for frame in received..<Int(frameCount) {
                left[frame] = 0
                right[frame] = 0
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }

    func start() {
        isPlaying = true
        activateSession()
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            // Without sound the game still runs.
        }
    }

    private func activateSession() {
        // Ambient sound is silenced by the silent switch; playback is not. Both mix with other
        // apps' sound (music, a podcast), as before.
        try? AVAudioSession.sharedInstance().setCategory(playsWhenSilent ? .playback : .ambient, mode: .default,
                                                         options: playsWhenSilent ? .mixWithOthers : [])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func pause() {
        isPlaying = false
        engine.pause()
        ring.clear()
    }

    func stop() {
        isPlaying = false
        engine.stop()
        ring.clear()
    }

    /// Called on the emulation thread with interleaved stereo frames.
    func push(_ samples: UnsafePointer<Int16>, frames: Int) {
        // Keep latency low: if the queue grew too long, skip ahead.
        if ring.available > maxLatencySamples {
            ring.clear()
        }
        ring.write(samples, count: frames * 2)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        engine.stop()
        scratch?.deallocate()
    }
}
