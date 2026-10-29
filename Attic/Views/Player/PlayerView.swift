import SwiftUI

struct PlayerView: View {
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(SaveStateStore.self) private var saveStates
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accent) private var accent

    let request: PlayRequest
    @State private var session: EmulatorSession?
    @State private var controllers: GameControllerInput?
    /// Where the game's vibration goes: a controller, this iPhone or another iPhone.
    @State private var rumble = RumbleOutput(isEnabled: true)
    @State private var touches = TouchState()
    @State private var menuOpen = false
    @State private var controlsPanelOpen = false
    @State private var pointer: WiiPointer = .touch
    @State private var tilt = TiltPointer()
    @State private var stopping = false
    /// Players 2 to 4 joining from other iPhones, in a game of a system with more controller ports.
    @State private var multiplayer: MultiplayerHost?
    /// An Apple TV or other second screen; while connected the game is shown there.
    private let display = ExternalDisplay.shared

    enum WiiPointer: Hashable {
        case touch, tilt
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if let session {
                    if landscape {
                        landscapeLayout(session, size: geometry.size, insets: geometry.safeAreaInsets)
                    } else {
                        portraitLayout(session, width: geometry.size.width)
                    }
                    if settings.showPerformance, let multiplayer, !multiplayer.players.isEmpty {
                        LinkReadout(host: multiplayer)
                            .padding(.top, landscape ? 56 : 60)
                            .padding(.leading, landscape ? 4 : 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .allowsHitTesting(false)
                    }
                    if controlsPanelOpen {
                        ControlsPanel(landscape: landscape) {
                            closeControlsPanel()
                        }
                        .padding(.top, landscape ? 60 : 72)
                        .frame(maxWidth: landscape ? 420 : .infinity)
                        .padding(.horizontal, 12)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if menuOpen {
                        PlayerMenu(session: session, multiplayer: multiplayer, landscape: landscape,
                                   save: saveState, load: loadState, toggleFastForward: toggleFastForward,
                                   screenshot: screenshot, controls: openControlsPanel, stop: stop, close: closeMenu)
                            .transition(.opacity)
                    }
                }
                ToastOverlay(edge: .top)
                    .padding(.top, landscape ? 64 : 96)
                if let multiplayer, let request = multiplayer.requests.first {
                    JoinRequestBanner(host: multiplayer, request: request)
                        .padding(.top, landscape ? 12 : 56)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: 460)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: menuOpen)
            .animation(.easeOut(duration: 0.22), value: controlsPanelOpen)
            .animation(.easeOut(duration: 0.22), value: multiplayer?.requests.first)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .externalDisplayAccessory()
        .task { await start() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, session?.state == .running {
                session?.pause()
                menuOpen = true
            }
        }
        .onChange(of: pointer) { _, mode in
            guard let session else { return }
            if mode == .tilt {
                tilt.start(session.input)
            } else {
                tilt.stop()
            }
        }
        // While the game runs the screen stays on, even when only a controller or the iPhone's
        // movement is used; with the menu open it may turn off again.
        .onChange(of: session?.state == .running) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onChange(of: settings.rumble) { _, on in
            rumble.isEnabled = on
        }
        .onChange(of: settings.soundWhenSilent) { _, on in
            session?.playsWhenSilent = on
        }
        .onChange(of: settings.tvBothScreens, initial: true) { _, both in
            display.bothScreens = both
        }
        .onChange(of: settings.allowPlayers) { _, allowed in
            if allowed {
                multiplayer?.open(direct: settings.directWiFi)
            } else {
                multiplayer?.close()
            }
        }
        .onDisappear {
            multiplayer?.close()
            Chromecast.shared.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            tilt.stop()
            rumble.stop()
            controllers?.stop()
            if let session, display.session === session {
                display.session = nil
            }
            // Gone without Stoppen: stop the game here as Stoppen would, so its emulator does
            // not stay loaded and nothing goes unsaved.
            if let session, !stopping, session.state != .stopped {
                let autosave = settings.autosave && session.isActive
                let wasPlaying = session.isActive
                let library = library
                Task {
                    let result = await session.stop(autosave: autosave)
                    if wasPlaying {
                        library.recordSession(session.game.id, duration: result.played)
                    }
                }
            }
        }
    }

    // MARK: Layouts

    private func portraitLayout(_ session: EmulatorSession, width: CGFloat) -> some View {
        let game = session.game
        let layout = game.controls
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                menuButton(style: .portrait)
                if settings.showPerformance {
                    PerformanceReadout(session: session)
                        .frame(maxWidth: .infinity)
                } else if display.isConnected && game.system.screen.isDual {
                    TVLine()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(game.title)
                        .font(.text(13, weight: 600))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                if showsRecenter(game) {
                    recenterButton(style: .portrait)
                }
                if session.canRewind {
                    rewindButton(style: .portrait)
                }
                fastForwardButton(style: .portrait)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)

            screens(session, width: width)

            if game.hasWiiPointer {
                HStack {
                    Text("Wii-aanwijzer").font(.text(12)).foregroundStyle(Palette.muted)
                    Spacer()
                    SegmentedChoice(options: [.init(value: WiiPointer.touch, title: "Tikken op beeld"),
                                              .init(value: WiiPointer.tilt, title: "Telefoon richten")],
                                    selection: $pointer)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            if game.usesMotion && game.wiiSettings.controller == .nunchuk {
                WiiRemoteHoldChoice(session: session, compact: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            Spacer(minLength: 8)

            ControlSurface(input: session.input, touches: touches, haptics: settings.haptics,
                           shakeButton: session.game.shakeButton, onMenuKey: openMenu) {
                VStack(spacing: 14) {
                    if !layout.shoulders.isEmpty {
                        HStack {
                            shoulders(layout, layout.leftShoulders, style: .portrait)
                            Spacer()
                            shoulders(layout, layout.rightShoulders, style: .portrait)
                        }
                    }
                    HStack {
                        directionControls(game, style: .portrait, pairedSize: 108)
                        Spacer()
                        FaceButtons(layout: layout, touches: touches, style: .portrait)
                    }
                    CenterButtons(layout: layout, touches: touches, style: .portrait)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .opacity(settings.buttonOpacity / 100)
            }
        }
    }

    @ViewBuilder
    private func screens(_ session: EmulatorSession, width: CGFloat) -> some View {
        let screen = session.game.system.screen
        let onTV = display.isConnected
        switch screen {
        case _ where onTV && screen.isDual:
            // The top screen is on the TV: the touch screen as wide as fits (the top bar says so).
            let bottomWidth = width - 24
            touchScreen(session)
                .frame(width: bottomWidth, height: bottomWidth / screen.bottomAspectRatio)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .ds, .n3ds:
            let topWidth = width * (screen == .ds ? 0.77 : 0.92)
            let bottomWidth = width * (screen == .ds ? 0.77 : 0.74)
            VStack(spacing: 8) {
                GameScreen(session: session, label: "Bovenscherm", region: session.game.system.screen.topRegion)
                    .frame(width: topWidth, height: topWidth / screen.aspectRatio)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                touchScreen(session)
                    .frame(width: bottomWidth, height: bottomWidth * 3 / 4)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case _ where onTV:
            TVNotice()
                .frame(width: width - 32, height: 150)
                .overlay { wiiPointerArea(session) }
        case .gb:
            let screenWidth = width * 0.85
            GameScreen(session: session, label: "Spelbeeld")
                .frame(width: screenWidth, height: screenWidth / session.aspectRatio)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        default:
            GameScreen(session: session, label: "Spelbeeld")
                .frame(width: width, height: width / session.aspectRatio)
                .overlay { wiiPointerArea(session) }
        }
    }

    private func landscapeLayout(_ session: EmulatorSession, size: CGSize, insets: EdgeInsets) -> some View {
        let game = session.game
        let layout = game.controls
        let fullHeight = size.height + insets.top + insets.bottom
        let screenHeight = min(fullHeight, size.width / session.aspectRatio)
        let dual = game.system.screen.isDual
        // Side by side, the two screens share the width.
        let dualHeight = min(fullHeight * 0.86, (size.width - 8) / (session.aspectRatio + game.system.screen.bottomAspectRatio))
        let onTV = display.isConnected
        // With the top screen on the TV, the touch screen alone, as high as fits.
        let touchHeight = min(fullHeight, size.width / game.system.screen.bottomAspectRatio)
        return ZStack {
            if dual && onTV {
                touchScreen(session)
                    .frame(width: touchHeight * game.system.screen.bottomAspectRatio, height: touchHeight)
                    .ignoresSafeArea()
            } else if dual {
                HStack(spacing: 8) {
                    GameScreen(session: session, label: "Bovenscherm", region: game.system.screen.topRegion)
                        .frame(width: dualHeight * session.aspectRatio, height: dualHeight)
                    touchScreen(session)
                        .frame(width: dualHeight * game.system.screen.bottomAspectRatio, height: dualHeight)
                }
                .ignoresSafeArea()
            } else if onTV {
                TVNotice()
                    .frame(width: 300, height: 150)
                    .overlay { wiiPointerArea(session) }
            } else {
                GameScreen(session: session, label: "Spelbeeld")
                    .frame(width: screenHeight * session.aspectRatio, height: screenHeight)
                    .overlay { wiiPointerArea(session) }
                    .ignoresSafeArea()
            }

            ControlSurface(input: session.input, touches: touches, haptics: settings.haptics,
                           shakeButton: session.game.shakeButton, onMenuKey: openMenu) {
                ZStack {
                    VStack(alignment: .leading, spacing: 26) {
                        Spacer()
                        HStack(spacing: 8) { shoulders(layout, layout.leftShoulders, style: .overlay, width: 72) }
                        directionControls(game, style: .overlay, pairedSize: 100)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 26) {
                        Spacer()
                        HStack(spacing: 8) { shoulders(layout, layout.rightShoulders, style: .overlay, width: 72) }
                        FaceButtons(layout: layout, touches: touches, style: .overlay)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    VStack {
                        Spacer()
                        CenterButtons(layout: layout, touches: touches, style: .overlay)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
                .opacity(settings.buttonOpacity / 100)
            }

            VStack {
                HStack {
                    menuButton(style: .overlay)
                    Spacer()
                    if settings.showPerformance {
                        PerformanceReadout(session: session)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(ControlStyle.overlay.barFill, in: Capsule())
                            .overlay(Capsule().strokeBorder(ControlStyle.overlay.barBorder, lineWidth: 1))
                        Spacer()
                    }
                    if showsRecenter(session.game) {
                        recenterButton(style: .overlay)
                    }
                    if session.canRewind {
                        rewindButton(style: .overlay)
                    }
                    fastForwardButton(style: .overlay)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
        }
    }

    /// The D-pad or the stick, or both, the D-pad above the stick as on a PSP (`pairedSize` each).
    @ViewBuilder
    private func directionControls(_ game: Game, style: ControlStyle, pairedSize: CGFloat) -> some View {
        if game.showsDPadWithStick {
            VStack(spacing: 8) {
                DPad(touches: touches, style: style, size: pairedSize)
                AnalogStick(touches: touches, style: style, size: pairedSize)
            }
        } else if game.usesStick {
            AnalogStick(touches: touches, style: style)
        } else {
            DPad(touches: touches, style: style)
        }
    }

    private func shoulders(_ layout: ControlLayout, _ range: Range<Int>, style: ControlStyle, width: CGFloat? = nil) -> some View {
        ForEach(Array(range), id: \.self) { index in
            ShoulderButton(label: layout.shoulders[index], button: layout.shoulderButtons[index], touches: touches, style: style,
                           width: width ?? (layout.shoulders.count > 2 ? 72 : 96))
        }
    }

    /// The DS or 3DS bottom screen: a finger on it touches the game.
    @ViewBuilder
    private func touchScreen(_ session: EmulatorSession) -> some View {
        if session.state == .unsupported {
            TouchScreenPlaceholder()
        } else {
            GameScreen(session: session, label: "Onderscherm", region: session.game.system.screen.bottomRegion)
                .overlay {
                    GeometryReader { geometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        touch(session, at: value.location, in: geometry.size, pressed: true)
                                    }
                                    .onEnded { value in
                                        touch(session, at: value.location, in: geometry.size, pressed: false)
                                    }
                            )
                    }
                }
                .accessibilityLabel("Aanraakscherm")
        }
    }

    /// On the Wii, a finger on the picture moves the Wii Remote's pointer: Dolphin reads the
    /// right stick as the pointer's position. The pointer stays where the finger left it.
    @ViewBuilder
    private func wiiPointerArea(_ session: EmulatorSession) -> some View {
        if session.game.hasWiiPointer && pointer == .touch {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = value.location.x / max(geometry.size.width, 1) * 2 - 1
                                let y = value.location.y / max(geometry.size.height, 1) * 2 - 1
                                session.input.setStick(.right, x: x, y: y, from: .touch)
                            }
                    )
            }
            .accessibilityLabel("Wii-aanwijzer")
        }
    }

    private func touch(_ session: EmulatorSession, at location: CGPoint, in size: CGSize, pressed: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        let region = session.game.system.screen.bottomRegion
        let x = region.minX + min(max(location.x / size.width, 0), 1) * region.width
        let y = region.minY + min(max(location.y / size.height, 0), 1) * region.height
        session.input.setPointer(x: x, y: y, pressed: pressed)
    }

    private func menuButton(style: ControlStyle) -> some View {
        Button(action: openMenu) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").font(.system(size: 16, weight: .semibold))
                Text("Menu").font(.text(14, weight: 600))
            }
            .foregroundStyle(style.label)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: 40)
            .background(style.barFill, in: Capsule())
            .overlay(Capsule().strokeBorder(style.barBorder, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    /// Hold to wind the game back; let go to play on from there.
    private func rewindButton(style: ControlStyle) -> some View {
        let on = session?.isRewinding == true
        return Image(systemName: "backward.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(on ? Palette.ink : style.label)
            .frame(width: 48, height: 40)
            .background(on ? accent : style.barFill, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? .clear : style.barBorder, lineWidth: 1))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in session?.setRewinding(true) }
                    .onEnded { _ in session?.setRewinding(false) }
            )
            .accessibilityElement()
            .accessibilityLabel("Terugspoelen")
            .accessibilityHint("Ingedrukt houden")
            .accessibilityAddTraits(.isButton)
    }

    /// With a Wii Remote that follows the iPhone: its pointer or its tilt.
    private func showsRecenter(_ game: Game) -> Bool {
        game.hasWiiPointer && (pointer == .tilt || game.usesMotion)
    }

    /// Point the iPhone at the middle of the picture and tap: that becomes the middle again, and
    /// how the iPhone is held now counts as the Wii Remote held level.
    private func recenterButton(style: ControlStyle) -> some View {
        Button {
            tilt.recenter()
            session?.levelWiiRemote()
            if settings.haptics {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } label: {
            Image(systemName: "scope")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(style.label)
                .frame(width: 48, height: 40)
                .background(style.barFill, in: Capsule())
                .overlay(Capsule().strokeBorder(style.barBorder, lineWidth: 1))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Wii Remote naar het midden")
        .accessibilityHint("Richt je iPhone op het midden van het beeld en tik")
    }

    private func fastForwardButton(style: ControlStyle) -> some View {
        let on = session?.isFastForward == true
        return Button(action: toggleFastForward) {
            HStack(spacing: 6) {
                Image(systemName: "forward.fill").font(.system(size: 13, weight: .bold))
                Text(on ? "2×" : "1×").font(.text(14, weight: 700))
            }
            .foregroundStyle(on ? Palette.ink : style.label)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(on ? accent : style.barFill, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? .clear : style.barBorder, lineWidth: 1))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Snel vooruit")
        .accessibilityValue(on ? "Aan" : "Uit")
    }

    // MARK: Actions

    private func start() async {
        guard session == nil else { return }
        guard let game = library.game(request.gameID) else {
            dismiss()
            return
        }
        let session = EmulatorSession(game: game, saveStates: saveStates)
        session.playsWhenSilent = settings.soundWhenSilent
        self.session = session
        display.session = session
        // In a game for more players, each next controller becomes player 2, 3 or 4.
        let controllers = GameControllerInput(input: session.input, analogStick: game.usesStick,
                                              mapping: settings.mapping(for: .of(game)),
                                              seats: game.system.maxPlayers > 1 ? session : nil)
        controllers.onChange = { toasts.show($0) }
        self.controllers = controllers
        rumble.isEnabled = settings.rumble
        rumble.controllers = controllers
        session.onRumble = { [rumble] port, strength in
            rumble.set(port: port, strength: strength)
        }
        await session.start(from: request.saveState, rewind: settings.rewind, options: settings.coreOptions(for: game))
        switch session.state {
        case .failed(let message):
            toasts.show(message, isError: true)
        case .running:
            if let state = request.saveState {
                if !session.saveStateFailed {
                    toasts.show("\(state.label) geladen")
                } else if state.slot == nil, let kept = saveStates.keepAsSlot(state, gameID: game.id) {
                    // Stopping makes a new auto-save; the one that did not load stays as a slot.
                    toasts.show("Auto-save laadde niet; bewaard als \(kept.label)", isError: true)
                } else {
                    toasts.show("\(state.label) laadde niet; het spel begint opnieuw", isError: true)
                }
            }
            if game.system.maxPlayers > 1 {
                let multiplayer = MultiplayerHost(session: session)
                multiplayer.onChange = { toasts.show($0) }
                rumble.multiplayer = multiplayer
                if settings.allowPlayers {
                    multiplayer.open(direct: settings.directWiFi)
                }
                self.multiplayer = multiplayer
            }
        default:
            break
        }
    }

    private func openMenu() {
        guard !stopping else { return }
        if menuOpen {
            closeMenu()
            return
        }
        controlsPanelOpen = false
        session?.pause()
        menuOpen = true
    }

    private func closeMenu() {
        menuOpen = false
        session?.resume()
    }

    private func toggleFastForward() {
        guard let session else { return }
        session.setFastForward(!session.isFastForward)
    }

    private func saveState() {
        guard let session else { return }
        guard session.isActive else {
            closeMenu()
            toasts.show("Opslaan kan zodra \(session.game.system.coreName) in Attic zit")
            return
        }
        let slot = saveStates.nextSlot(for: session.game.id)
        Task {
            let state = await session.saveState(slot: slot)
            closeMenu()
            toasts.show(state != nil ? "Opgeslagen in slot \(slot)" : "Opslaan is niet gelukt", isError: state == nil)
        }
    }

    private func loadState() {
        guard let session else { return }
        guard session.isActive, let latest = saveStates.latest(for: session.game.id) else {
            closeMenu()
            toasts.show("Nog geen save state om te laden")
            return
        }
        Task {
            let ok = await session.loadState(latest)
            closeMenu()
            toasts.show(ok ? "\(latest.label) geladen" : "Laden is niet gelukt", isError: !ok)
        }
    }

    private func screenshot() {
        guard let session else { return }
        Task {
            let ok = session.isActive ? await session.screenshot() : false
            closeMenu()
            toasts.show(ok ? "Screenshot bewaard in Foto’s" : "Geen toegang tot Foto’s", isError: !ok)
        }
    }

    private func openControlsPanel() {
        menuOpen = false
        controlsPanelOpen = true
    }

    private func closeControlsPanel() {
        controlsPanelOpen = false
        session?.resume()
    }

    private func stop() {
        guard let session, !stopping else { return }
        stopping = true
        let gameID = session.game.id
        let wasPlaying = session.isActive
        let autosave = settings.autosave && wasPlaying
        Task {
            let result = await session.stop(autosave: autosave)
            rumble.stop()
            controllers?.stop()
            if wasPlaying {
                library.recordSession(gameID, duration: result.played)
            }
            if result.autosave != nil {
                toasts.show("Automatisch opgeslagen")
            }
            dismiss()
        }
    }
}

// MARK: - Screen

/// The game picture, or for systems without an emulator yet, a placeholder in the game's colours.
/// The two halves of a DS picture, which melonDS delivers stacked (256×384).
/// Frames per second, the game's speed and the busiest threads, refreshed every second
/// (Settings › Prestaties tonen).
private struct PerformanceReadout: View {
    let session: EmulatorSession
    @State private var figures: PerformanceMonitor.Figures?

    var body: some View {
        VStack(spacing: 2) {
            Text(summary)
            Text(threads)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(Palette.textSecondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .task {
            while !Task.isCancelled {
                figures = session.performance()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var summary: String {
        guard let figures else { return "– fps · –%" }
        let speed = figures.speed.map { "\(Int(($0 * 100).rounded()))%" } ?? "–%"
        return "\(Int(figures.framesPerSecond.rounded())) fps · \(speed)"
    }

    /// Each thread's share of one processor core.
    private var threads: String {
        guard let figures, !figures.threads.isEmpty else { return " " }
        return figures.threads.map { "\($0.name) \(Int(($0.load * 100).rounded()))%" }.joined(separator: " · ")
    }
}

/// Under Prestaties tonen while others play along: how evenly each player's messages come in
/// (`LinkMonitor`). Gaps are the median, 95th percentile and largest; "netwerk" is how much longer
/// than the quickest message one took, apart from how evenly the other iPhone sent them.
private struct LinkReadout: View {
    let host: MultiplayerHost
    @State private var figures: [LinkMonitor.Figures] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(figures) { player in
                VStack(alignment: .leading, spacing: 1) {
                    Text("Speler \(player.port + 1) · \(player.route)")
                    Text(String(format: "%.0f/s · gat %.0f · p95 %.0f · max %.0f ms",
                                player.perSecond, player.gapMedian, player.gap95, player.gapMax))
                    if let delay95 = player.delay95, let delayMax = player.delayMax, let lost = player.lost {
                        Text(String(format: "netwerk p95 %.0f · max %.0f ms · kwijt %.1f%%", delay95, delayMax, lost * 100))
                    }
                    if let empty = player.emptyFrames, let crowded = player.crowdedFrames {
                        Text(String(format: "beelden zonder nieuws %.0f%% · met 2+ %.0f%%", empty * 100, crowded * 100))
                    }
                }
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(Palette.textSecondary)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(figures.isEmpty ? 0 : 1)
        .accessibilityElement(children: .combine)
        .task {
            while !Task.isCancelled {
                figures = host.linkFigures()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct GameScreen: View {
    let session: EmulatorSession
    let label: String
    var region = CGRect(x: 0, y: 0, width: 1, height: 1)

    var body: some View {
        switch session.state {
        case .unsupported:
            placeholder(message: "\(session.game.system.coreName) \(session.game.system.arrival). Je ziet hier alvast de besturing.")
        case .failed(let message):
            placeholder(message: message)
        default:
            MetalScreen(frameBuffer: session.frameBuffer, region: region)
                .overlay {
                    if session.state == .starting {
                        ProgressView().tint(.white)
                    }
                }
        }
    }

    private func placeholder(message: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            CoverArt(style: session.game.cover)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(label) · \(session.game.system.coreName)")
                    .font(.text(11, weight: 600))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(message)
                    .font(.text(13, weight: 600))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
    }
}

private struct TouchScreenPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(hex: 0x12151C))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            .overlay(Text("Aanraakscherm · tik of sleep").font(.text(12)).foregroundStyle(Palette.muted))
    }
}

// MARK: - Menu

private struct PlayerMenu: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accent) private var accent
    let session: EmulatorSession
    let multiplayer: MultiplayerHost?
    let landscape: Bool
    let save: () -> Void
    let load: () -> Void
    let toggleFastForward: () -> Void
    let screenshot: () -> Void
    let controls: () -> Void
    let stop: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack(alignment: landscape ? .trailing : .bottom) {
            Color.black.opacity(landscape ? 0.5 : 0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            panel
                .transition(.move(edge: landscape ? .trailing : .bottom))
        }
    }

    /// Scrolls only when it does not fit, as in a short landscape window with players listed.
    private var panel: some View {
        ViewThatFits(in: .vertical) {
            panelContent
            ScrollView(showsIndicators: false) { panelContent }
        }
        .frame(width: landscape ? 340 : nil)
        .frame(maxHeight: landscape ? .infinity : nil)
        .background(
            UnevenRoundedRectangle(cornerRadii: landscape
                ? .init(topLeading: 24, bottomLeading: 24)
                : .init(topLeading: Metrics.sheetRadius, topTrailing: Metrics.sheetRadius), style: .continuous)
                .fill(Palette.surface)
                .ignoresSafeArea()
        )
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: landscape ? 14 : 18) {
            if !landscape {
                SheetGrabber().frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "Gepauzeerd")
                    Text(session.game.title)
                        .font(.display(landscape ? 18 : 22))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                CloseButton(size: landscape ? 36 : 40, action: close)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: landscape ? 8 : 10), count: landscape ? 2 : 3),
                      spacing: landscape ? 8 : 10) {
                tile("Opslaan", "arrow.down.to.line", action: save)
                tile("Laden", "arrow.up.to.line", action: load)
                tile("Snel vooruit \(session.isFastForward ? "2×" : "1×")", "forward.fill", action: toggleFastForward)
                tile("Screenshot", "camera", action: screenshot)
                tile("Besturing", "gamecontroller", action: controls)
                tile("Stoppen", "stop.fill", action: stop)
            }
            if session.game.usesMotion && session.game.wiiSettings.controller == .nunchuk {
                WiiRemoteHoldChoice(session: session)
            }
            ChromecastRow(session: session)
            if ExternalDisplay.shared.isConnected && session.game.system.screen.isDual {
                tvScreensChoice
            }
            if let multiplayer {
                PlayersRow(host: multiplayer)
            }
            PrimaryButton(title: "Verder spelen", systemImage: "play.fill", height: landscape ? 48 : 54, action: close)
        }
        .padding(.horizontal, 20)
        .padding(.top, landscape ? 20 : 10)
        .padding(.bottom, landscape ? 20 : 12)
    }

    /// What a DS or 3DS game shows on the TV: the top screen, or both for someone watching along.
    private var tvScreensChoice: some View {
        @Bindable var settings = settings
        return HStack {
            Text("Op de tv").font(.text(13)).foregroundStyle(Palette.muted)
            Spacer()
            SegmentedChoice(options: [.init(value: false, title: "Bovenscherm"), .init(value: true, title: "Beide schermen")],
                            selection: $settings.tvBothScreens)
        }
    }

    private func tile(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if landscape {
                    HStack(spacing: 10) {
                        Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                        Text(title).font(.text(13, weight: 600)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 52)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: systemImage).font(.system(size: 20, weight: .semibold))
                        Text(title).font(.text(13, weight: 600)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 84)
                }
            }
            .foregroundStyle(Palette.text)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: landscape ? 14 : 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Controls panel

/// "Besturing": the visibility slider, shown over the game so the effect is visible right away.
private struct ControlsPanel: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accent) private var accent
    let landscape: Bool
    let done: () -> Void

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Besturing").font(.display(18)).foregroundStyle(Palette.text)
                Spacer()
                Button(action: done) {
                    Text("Klaar")
                        .font(.text(14, weight: 700))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(accent, in: Capsule())
                }
                .buttonStyle(.pressable)
            }
            HStack {
                Text("Zichtbaarheid knoppen").font(.text(15)).foregroundStyle(Palette.text)
                Spacer()
                Text("\(Int(settings.buttonOpacity))%").font(.mono(13)).foregroundStyle(Palette.textSecondary)
            }
            Slider(value: $settings.buttonOpacity, in: 0...100, step: 5)
                .tint(accent)
                .accessibilityLabel("Zichtbaarheid knoppen")
            Text(landscape
                 ? "Menu en snel vooruit blijven altijd zichtbaar, zodat je ze terugvindt."
                 : "Je ziet het meteen aan de knoppen hieronder. Bij 0% zijn ze onzichtbaar, maar ze werken nog.")
                .font(.text(12))
                .lineSpacing(2)
                .foregroundStyle(Palette.muted)
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 20, y: 16)
    }
}

/// How the Wii Remote is held, for a game that asks to turn it in between: pointed at the screen,
/// or sideways like a steering wheel (Mario Party 8's races). Only the iPhone's movement changes.
private struct WiiRemoteHoldChoice: View {
    let session: EmulatorSession
    var compact = false

    var body: some View {
        HStack {
            Text("Wii Remote").font(.text(compact ? 12 : 13)).foregroundStyle(Palette.muted)
            Spacer()
            SegmentedChoice(options: [.init(value: false, title: "Rechtop"), .init(value: true, title: "Dwars")],
                            selection: Binding { session.holdsWiiRemoteSideways } set: { session.holdsWiiRemoteSideways = $0 })
        }
    }
}

/// In the menu: whether other iPhones may join as players 2 to 4, and who is playing.
private struct PlayersRow: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accent) private var accent
    let host: MultiplayerHost

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $settings.allowPlayers) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Andere iPhones laten meedoen").font(.text(14, weight: 600)).foregroundStyle(Palette.text)
                    Text(settings.allowPlayers
                         ? "Op de andere iPhone: Attic › \(Image(systemName: "gamecontroller")) in de bibliotheek"
                         : "Als controller, tot \(host.maxPlayers) spelers samen")
                        .font(.text(12))
                        .foregroundStyle(Palette.muted)
                }
            }
            .tint(accent)
            if !host.players.isEmpty {
                HStack(spacing: 6) {
                    ForEach(host.players) { player in
                        Button {
                            host.remove(player)
                        } label: {
                            HStack(spacing: 5) {
                                Text("Speler \(player.number)").font(.text(12, weight: 600))
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(Palette.text)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Palette.raised, in: Capsule())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("Speler \(player.number) laten stoppen")
                    }
                }
            }
        }
    }
}

/// Over the game: another iPhone asks to join, and the player of this one says yes or no.
private struct JoinRequestBanner: View {
    @Environment(\.accent) private var accent
    let host: MultiplayerHost
    let request: UUID

    var body: some View {
        let number = host.nextPlayer
        HStack(spacing: 12) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Een iPhone wil meedoen").font(.text(15, weight: 600)).foregroundStyle(Palette.text)
                Text(number.map { "Als speler \($0)" } ?? "Er is geen plek meer").font(.text(12)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Button("Nee") { host.turnAway(request) }
                .font(.text(14, weight: 600))
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Palette.raised, in: Capsule())
                .buttonStyle(.pressable)
            Button("Toestaan") { host.allow(request) }
                .font(.text(14, weight: 600))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(accent, in: Capsule())
                .buttonStyle(.pressable)
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }
}
