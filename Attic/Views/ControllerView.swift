import SwiftUI

/// This iPhone as a controller for a game on another iPhone nearby: pick the game, wait until the
/// other iPhone allows it, then play with the buttons of that system (`MultiplayerClient`).
struct ControllerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var client = MultiplayerClient()
    @State private var touches = TouchState()
    @State private var controllers: GameControllerInput?
    @State private var pointer = PointerMode.aim
    @State private var tilt = TiltPointer()
    @State private var rumble = RumbleOutput(isEnabled: true)

    /// How a Wii Remote's pointer is moved on this iPhone, which shows no picture: by pointing
    /// the iPhone itself, or with a finger on a pad that stands for the TV screen.
    enum PointerMode: Hashable {
        case aim, touchpad
    }

    var body: some View {
        Group {
            if case .playing(let player, let system, let title, let controller) = client.phase {
                pad(player: player, system: system, title: title, controller: controller)
            } else {
                lobby
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            rumble.isEnabled = settings.rumble
            client.onRumble = { [rumble] strength in
                rumble.set(port: 0, strength: strength)
            }
            client.direct = settings.directWiFi
            client.search()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            client.stop()
            tilt.stop()
            rumble.stop()
            controllers?.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: client.phase) { _, phase in
            rumble.stop()
            controllers?.stop()
            controllers = nil
            // A controller on this iPhone plays along too, with the buttons set up for that system.
            if case .playing(_, let system, _, let controller) = phase {
                controllers = GameControllerInput(input: client.input, analogStick: controller?.usesStick ?? system.usesStick,
                                                  mapping: settings.mapping(for: ControlScheme(system: system, wiiController: controller)))
            }
            rumble.controllers = controllers
            updatePointer()
        }
        .onChange(of: pointer) { updatePointer() }
        .onChange(of: settings.rumble) { _, on in
            rumble.isEnabled = on
        }
    }

    // MARK: Finding a game

    private var lobby: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SheetHeader(title: "Meedoen als controller",
                            subtitle: "Speel mee met een spel op een andere iPhone in de buurt; je iPhone wordt de controller.") {
                    dismiss()
                }
                switch client.phase {
                case .asking(let host):
                    notice(systemImage: "hourglass", title: "Wachten op toestemming",
                           text: "Op de andere iPhone verschijnt een vraag of je mee mag doen met \(host.title).",
                           button: "Annuleren") { client.search() }
                case .turnedAway:
                    notice(systemImage: "hand.raised", title: "Niet toegelaten",
                           text: "De andere iPhone liet je deze keer niet meedoen.", button: "Opnieuw zoeken") { client.search() }
                case .full:
                    notice(systemImage: "person.3", title: "Het spel zit vol",
                           text: "Alle controllers van dit spel zijn al bezet.", button: "Opnieuw zoeken") { client.search() }
                case .ended:
                    notice(systemImage: "stop.circle", title: "Het spel is gestopt",
                           text: "De andere iPhone stopte het spel of liet je stoppen.", button: "Opnieuw zoeken") { client.search() }
                case .lost:
                    notice(systemImage: "wifi.exclamationmark", title: "Verbinding verbroken",
                           text: "De andere iPhone is niet meer te bereiken. Staat wifi op beide aan, en zijn ze dicht genoeg bij elkaar?",
                           button: "Opnieuw zoeken") { client.search() }
                case .searching, .playing:
                    hostList
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
    }

    @ViewBuilder
    private var hostList: some View {
        if client.hosts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Zoeken naar spellen in de buurt…").font(.text(15, weight: 600)).foregroundStyle(Palette.text)
                }
                Text("Start op de andere iPhone een spel, open daar het menu en zet \"Andere iPhones laten meedoen\" aan. Beide iPhones hebben Attic en wifi aan nodig; een gedeeld wifi-netwerk hoeft niet.")
                    .font(.text(13))
                    .lineSpacing(2)
                    .foregroundStyle(Palette.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            TitledSection(title: "In de buurt") {
                RowGroup {
                    ForEach(client.hosts) { host in
                        Button {
                            client.join(host)
                        } label: {
                            HStack(spacing: 12) {
                                Text(host.system?.shortName ?? "?")
                                    .font(.text(12, weight: 700))
                                    .foregroundStyle(Palette.textSecondary)
                                    .frame(width: 44, height: 28)
                                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(host.title).font(.text(15, weight: 600)).foregroundStyle(Palette.text).lineLimit(2)
                                    Text(host.isCompatible ? host.system?.name ?? "Onbekend systeem" : "Andere versie van Attic: werk Attic bij op beide iPhones")
                                        .font(.text(12)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0)
                                if host.isCompatible {
                                    Text("Meedoen").font(.text(14, weight: 600)).foregroundStyle(accent)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .opacity(host.isCompatible ? 1 : 0.55)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .disabled(!host.isCompatible)
                    }
                }
            }
        }
    }

    private func notice(systemImage: String, title: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 26, weight: .semibold)).foregroundStyle(accent)
            Text(title).font(.display(22)).foregroundStyle(Palette.text)
            Text(text).font(.text(14)).lineSpacing(2).foregroundStyle(Palette.textSecondary)
            PrimaryButton(title: button, action: action)
                .padding(.top, 6)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Playing

    /// The buttons of the system the other iPhone plays, as on its own screen, without the picture.
    /// On the Wii they are those of the controller the game uses, and a Wii Remote also points
    /// and moves with this iPhone.
    private func pad(player: Int, system: GameSystem, title: String, controller: WiiController?) -> some View {
        let layout = controller?.layout ?? system.controls
        let wiiRemote = controller?.isWiiRemote ?? false
        return GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack(alignment: .top) {
                ControlSurface(input: client.input, touches: touches, haptics: settings.haptics,
                               shakeButton: wiiRemote ? GameSystem.wii.shakeButton : nil) {
                    VStack(spacing: landscape ? 12 : 22) {
                        if wiiRemote && pointer == .touchpad {
                            PointerPad(input: client.input)
                                .padding(.top, landscape ? 112 : 132)
                        } else {
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 8) {
                            shoulders(layout, layout.leftShoulders)
                            Spacer(minLength: 0)
                            shoulders(layout, layout.rightShoulders)
                        }
                        HStack(alignment: .center) {
                            direction(usesStick: controller?.usesStick ?? system.usesStick,
                                      withDPad: controller?.showsDPadWithStick ?? system.showsDPadWithStick,
                                      pairedSize: landscape ? 92 : 108)
                            Spacer(minLength: 12)
                            FaceButtons(layout: layout, touches: touches, style: .portrait)
                        }
                        CenterButtons(layout: layout, touches: touches, style: .portrait)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 70)
                    .padding(.bottom, landscape ? 8 : 24)
                }

                VStack(alignment: .leading, spacing: 10) {
                    header(player: player, system: system, title: title, wiiRemote: wiiRemote)
                    if wiiRemote {
                        HStack {
                            Text("Aanwijzer").font(.text(12)).foregroundStyle(Palette.muted)
                            Spacer()
                            SegmentedChoice(options: [.init(value: PointerMode.aim, title: "Telefoon richten"),
                                                      .init(value: PointerMode.touchpad, title: "Aanraakvlak")],
                                            selection: $pointer)
                        }
                    }
                    if controller == .nunchuk {
                        HStack {
                            Text("Wii Remote").font(.text(12)).foregroundStyle(Palette.muted)
                            Spacer()
                            SegmentedChoice(options: [.init(value: false, title: "Rechtop"), .init(value: true, title: "Dwars")],
                                            selection: Binding { client.holdsSideways } set: { client.holdsSideways = $0 })
                        }
                    }
                    if settings.showPerformance {
                        ControllerLinkReadout(client: client)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private func header(player: Int, system: GameSystem, title: String, wiiRemote: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(player)")
                .font(.display(22))
                .foregroundStyle(Palette.ink)
                .frame(width: 42, height: 42)
                .background(accent, in: Circle())
                .accessibilityLabel("Speler \(player)")
            VStack(alignment: .leading, spacing: 1) {
                Text("Speler \(player)").font(.text(15, weight: 600)).foregroundStyle(Palette.text)
                Text("\(title) · \(system.shortName)").font(.text(12)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if wiiRemote {
                // Point the iPhone at the middle of the TV and tap: that becomes the middle again.
                Button {
                    tilt.recenter()
                    client.levelWiiRemote()
                    if settings.haptics {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .frame(width: 44, height: 38)
                        .background(Palette.control, in: Capsule())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Wii Remote naar het midden")
                .accessibilityHint("Richt je iPhone op het midden van het beeld en tik")
            }
            Button {
                client.stop()
                client.search()
            } label: {
                Text("Stoppen")
                    .font(.text(14, weight: 600))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(Palette.control, in: Capsule())
            }
            .buttonStyle(.pressable)
        }
    }

    /// Pointing the iPhone moves the pointer while a Wii Remote is played with "Telefoon richten".
    private func updatePointer() {
        if case .playing(_, _, _, let controller?) = client.phase, controller.isWiiRemote, pointer == .aim {
            tilt.start(client.input)
        } else {
            tilt.stop()
        }
    }

    private func shoulders(_ layout: ControlLayout, _ range: Range<Int>) -> some View {
        ForEach(Array(range), id: \.self) { index in
            ShoulderButton(label: layout.shoulders[index], button: layout.shoulderButtons[index], touches: touches,
                           style: .portrait, width: layout.shoulders.count > 2 ? 72 : 96)
        }
    }

    /// The D-pad or the stick, or both, as on the player's own screen.
    @ViewBuilder
    private func direction(usesStick: Bool, withDPad: Bool, pairedSize: CGFloat) -> some View {
        if withDPad {
            VStack(spacing: 8) {
                DPad(touches: touches, style: .portrait, size: pairedSize)
                AnalogStick(touches: touches, style: .portrait, size: pairedSize)
            }
        } else if usesStick {
            AnalogStick(touches: touches, style: .portrait)
        } else {
            DPad(touches: touches, style: .portrait)
        }
    }
}

/// A pad that stands for the TV screen: where a finger is on it, the Wii Remote points.
/// The pointer stays where the finger left it, as on the iPhone with the game.
/// Under Prestaties tonen: how this iPhone's messages go out, to set beside the figures on the
/// iPhone with the game. "Sensor te laat" is how long the motion readings took to reach the app.
private struct ControllerLinkReadout: View {
    let client: MultiplayerClient
    @State private var route = ""
    @State private var perSecond: Double?
    @State private var sensor: DeviceMotion.Delivery?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Via \(route)" + (perSecond.map { String(format: " · %.0f berichten/s", $0) } ?? ""))
            if let sensor {
                Text(String(format: "Sensor %.0f/s · te laat p95 %.0f · max %.0f ms",
                            sensor.perSecond, sensor.lateness95, sensor.latenessMax))
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(Palette.textSecondary)
        .accessibilityElement(children: .combine)
        .task {
            while !Task.isCancelled {
                (route, perSecond, sensor) = client.linkFigures()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct PointerPad: View {
    let input: InputState

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Palette.surface)
                .overlay {
                    Label("Aanwijzer", systemImage: "hand.point.up.left")
                        .font(.text(13, weight: 600))
                        .foregroundStyle(Palette.muted)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let x = value.location.x / max(geometry.size.width, 1) * 2 - 1
                            let y = value.location.y / max(geometry.size.height, 1) * 2 - 1
                            input.setStick(.right, x: x, y: y, from: .touch)
                        }
                )
        }
        .accessibilityLabel("Aanraakvlak voor de Wii-aanwijzer")
    }
}
