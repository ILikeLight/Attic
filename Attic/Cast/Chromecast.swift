import Foundation
import Network
import Observation

/// Playing on a Chromecast on the same Wi-Fi, without Google's sender library (see `CastChannel`):
/// finds Chromecasts with Bonjour, starts the TV's built-in mirroring receiver and sends it the
/// game as H.264 (`CastCapture` → `CastVideoEncoder` → `CastStreamer`). While it casts, the
/// iPhone plays as with a TV (`ExternalDisplay.isCasting`). The sound stays on the iPhone for now.
@MainActor
@Observable
final class Chromecast {
    static let shared = Chromecast()

    struct Device: Identifiable, Hashable {
        /// The Bonjour name.
        let id: String
        /// The name the TV was given in Google Home.
        let name: String
        let endpoint: NWEndpoint
    }

    enum State: Equatable {
        case idle
        case connecting(String)
        case casting(String)
        case failed(String)
    }

    private(set) var devices: [Device] = []
    private(set) var state = State.idle
    /// How the stream goes, for Prestaties tonen; refreshed every second while casting.
    private(set) var figures: CastStreamer.Figures?

    var isBusy: Bool {
        switch state {
        case .connecting, .casting: true
        case .idle, .failed: false
        }
    }

    /// The TV plays each frame this long after it was made (ms): long enough for a lost packet to
    /// be sent again over Wi-Fi, short enough to play with.
    static let targetDelay = 100
    private static let frameRate = 60
    private static let bitRate = 6_000_000

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var channel: CastChannel?
    @ObservationIgnored private var streamer: CastStreamer?
    @ObservationIgnored private var encoder: CastVideoEncoder?
    @ObservationIgnored private var capture: CastCapture?
    @ObservationIgnored private var figuresTimer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "app.attic.cast", qos: .userInteractive)

    /// Looks for Chromecasts until `stopSearching`; `devices` follows what it finds.
    func search() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Device? in
                guard case .service(let service, _, _, _) = result.endpoint else { return nil }
                var name = service
                if case .bonjour(let record) = result.metadata, let friendly = record["fn"], !friendly.isEmpty {
                    name = friendly
                }
                return Device(id: service, name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in self?.devices = found }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stopSearching() {
        browser?.cancel()
        browser = nil
    }

    func cast(_ session: EmulatorSession, to device: Device) {
        tearDown()
        state = .connecting(device.name)
        let video = CastStreamer.Stream.video()
        let channel = CastChannel(to: device.endpoint, queue: queue) { [weak self] channel, event in
            switch event {
            case .ready:
                channel.sendOffer(CastStreamer.offer(video: video, width: CastCapture.width, height: CastCapture.height,
                                                     frameRate: Self.frameRate, maxBitRate: Self.bitRate * 3 / 2,
                                                     targetDelay: Self.targetDelay))
            case .answer(let answer):
                let streamer = channel.remoteHost.flatMap { CastStreamer(answer: answer, host: $0, streams: [video], queue: channel.queue) }
                Task { @MainActor in
                    guard let self, self.channel === channel else { return }
                    if let streamer {
                        self.begin(streamer, on: device, session: session)
                    } else {
                        self.fail("De Chromecast nam het beeld niet aan.")
                    }
                }
            case .closed(let reason):
                Task { @MainActor in
                    guard let self, self.channel === channel else { return }
                    self.fail(reason ?? "De verbinding met de Chromecast is verbroken.")
                }
            }
        }
        self.channel = channel
        queue.async { channel.start() }
    }

    /// Stops casting; the TV goes back to what it showed before.
    func stop() {
        tearDown()
        state = .idle
    }

    private func begin(_ streamer: CastStreamer, on device: Device, session: EmulatorSession) {
        let queue = queue
        guard let encoder = CastVideoEncoder(width: CastCapture.width, height: CastCapture.height, frameRate: Self.frameRate,
                                             bitRate: Self.bitRate, onFrame: { frame in queue.async { streamer.send(frame) } })
        else { return fail("Deze iPhone kon het beeld niet omzetten voor de tv.") }
        let display = ExternalDisplay.shared
        let screen = session.game.system.screen
        let aspect = session.aspectRatio
        guard let capture = CastCapture(frameBuffer: session.frameBuffer, encoder: encoder, parts: {
            // As on an AirPlay TV: a DS shows its top screen, or both side by side.
            if screen.isDual && !display.bothScreens {
                [(screen.topRegion, aspect)]
            } else if screen.isDual {
                [(screen.topRegion, aspect), (screen.bottomRegion, screen.bottomAspectRatio)]
            } else {
                [(CGRect(x: 0, y: 0, width: 1, height: 1), aspect)]
            }
        }) else { return fail("Deze iPhone kon het beeld niet omzetten voor de tv.") }
        streamer.onKeyFrameWanted = { encoder.requestKeyFrame() }
        streamer.onStatus = { [weak self] status in
            guard status == .silent else { return }
            Task { @MainActor in
                guard let self, self.streamer === streamer else { return }
                self.fail("Het beeld komt niet meer aan op de tv.")
            }
        }
        queue.async { streamer.start() }
        capture.start()
        self.streamer = streamer
        self.encoder = encoder
        self.capture = capture
        state = .casting(device.name)
        display.isCasting = true
        figuresTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            queue.async {
                let figures = streamer.figures
                Task { @MainActor in
                    guard let self, self.streamer === streamer else { return }
                    self.figures = figures
                }
            }
        }
    }

    private func fail(_ reason: String) {
        tearDown()
        state = .failed(reason)
    }

    private func tearDown() {
        capture?.stop()
        capture = nil
        encoder?.invalidate()
        encoder = nil
        figuresTimer?.invalidate()
        figuresTimer = nil
        figures = nil
        let streamer = streamer
        let channel = channel
        self.streamer = nil
        self.channel = nil
        queue.async {
            streamer?.stop()
            channel?.close()
        }
        ExternalDisplay.shared.isCasting = false
    }
}
