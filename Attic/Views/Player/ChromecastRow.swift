import SwiftUI

/// In the menu: play on a Chromecast on the same Wi-Fi, or stop. The iPhone then becomes the
/// controller, as with AirPlay.
struct ChromecastRow: View {
    @Environment(AppSettings.self) private var settings
    let session: EmulatorSession
    private let chromecast = Chromecast.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Chromecast").font(.text(14, weight: 600)).foregroundStyle(Palette.text)
                    Text(detail)
                        .font(.text(12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if chromecast.isBusy {
                    // Not "Stoppen", which the tile above uses for the game.
                    capsule("Loskoppelen", systemImage: "xmark") { chromecast.stop() }
                        .accessibilityLabel("Loskoppelen van de Chromecast")
                }
            }
            if !chromecast.isBusy && !chromecast.devices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chromecast.devices) { device in
                            capsule(device.name, systemImage: "tv") { chromecast.cast(session, to: device) }
                                .accessibilityLabel("Spelen op \(device.name)")
                        }
                    }
                }
            }
        }
        .onAppear { chromecast.search() }
        .onDisappear { chromecast.stopSearching() }
    }

    private var detail: String {
        switch chromecast.state {
        case .idle:
            chromecast.devices.isEmpty ? "Zoeken op je wifi…" : "Kies je tv; je iPhone wordt de controller"
        case .connecting(let name):
            "Verbinden met \(name)…"
        case .casting(let name):
            if settings.showPerformance, let figures = chromecast.figures {
                "Op \(name) · \(figures.framesConfirmed) beelden aangekomen, \(figures.packetsResent) pakketjes opnieuw, "
                    + "\(figures.keyFrames) beginbeelden, tv \(figures.playoutDelay) ms achter"
            } else {
                "Speelt op \(name) · het geluid blijft op je iPhone"
            }
        case .failed(let reason):
            reason
        }
    }

    private func capsule(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                Text(title).font(.text(12, weight: 600)).lineLimit(1)
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Palette.raised, in: Capsule())
        }
        .buttonStyle(.pressable)
    }
}
