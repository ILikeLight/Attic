import SwiftUI
import UIKit

/// A second screen, such as an Apple TV with AirPlay screen mirroring on. While a game is
/// playing it shows the game, and the iPhone becomes the controller.
@MainActor
@Observable
final class ExternalDisplay {
    static let shared = ExternalDisplay()

    /// Second-screen scenes connected now. Usually one, but when the player takes the TV over from
    /// the library, its scene can connect before the library's disconnects.
    fileprivate var scenes = 0
    /// The game plays on a Chromecast (`Chromecast`), which needs no scene of its own.
    var isCasting = false
    /// A TV shows the game: the iPhone shows only the controls.
    var isConnected: Bool { scenes > 0 || isCasting }
    /// The game being played; set by the player.
    var session: EmulatorSession?
    /// A DS or 3DS game shows both screens instead of only the top one (`AppSettings.tvBothScreens`).
    var bothScreens = false
}

extension View {
    /// Gives a second screen its own picture while this view is on screen (see `ExternalDisplayAccessory`).
    func externalDisplayAccessory() -> some View {
        background(ExternalDisplayAccessory())
    }
}

/// From iOS 27 a second screen gets a scene of its own only while a view controller on screen has
/// registered a scene accessory for it; without one, iOS mirrors the iPhone. When more than one is
/// registered, the most recently presented view controller's wins, so the library offers the TV its
/// "pick a game" picture and the player the game. Before iOS 27 the scene came by itself (`AppDelegate`).
private struct ExternalDisplayAccessory: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AccessoryController {
        AccessoryController()
    }

    func updateUIViewController(_ controller: AccessoryController, context: Context) {}

    final class AccessoryController: UIViewController {
        /// The UISceneAccessoryRegistration, which lasts as long as this view controller.
        private var registration: AnyObject?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            if #available(iOS 27.0, *) {
                let configuration = UISceneConfiguration(name: nil, sessionRole: .windowExternalDisplayNonInteractive)
                configuration.delegateClass = ExternalDisplaySceneDelegate.self
                registration = registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))
            }
        }

        #if DEBUG
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            FakeTV.show(in: view.window?.windowScene)
        }
        #endif
    }
}

#if DEBUG
/// Launch with `-AtticFakeTV` for a pretend TV in the Simulator, which cannot connect one from
/// the command line: the TV's picture in a small window over the iPhone's, which plays as with a TV.
@MainActor
private enum FakeTV {
    private static var window: UIWindow?

    static func show(in scene: UIWindowScene?) {
        guard ProcessInfo.processInfo.arguments.contains("-AtticFakeTV"), window == nil, let scene else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.isUserInteractionEnabled = false
        let controller = UIHostingController(rootView: ExternalDisplayView())
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        let bounds = scene.screen.bounds
        let width = min(bounds.width, bounds.height) * 0.6
        window.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height * 0.5, width: width, height: width * 9 / 16)
        window.layer.borderColor = UIColor.white.cgColor
        window.layer.borderWidth = 1
        window.clipsToBounds = true
        window.isHidden = false
        self.window = window
        ExternalDisplay.shared.scenes += 1
    }
}
#endif

/// Gives a second screen its own window instead of a copy of the iPhone screen, before iOS 27.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
        }
        return configuration
    }
}

final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: ExternalDisplayView())
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        ExternalDisplay.shared.scenes += 1
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard window != nil else { return }
        window = nil
        ExternalDisplay.shared.scenes -= 1
    }
}

/// What the TV shows: the game, or a hint to pick one.
private struct ExternalDisplayView: View {
    private let display = ExternalDisplay.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session = display.session, session.isActive {
                // A new screen for each game: MetalScreen keeps the frame buffer it was made with.
                ExternalGameView(session: session)
                    .id(ObjectIdentifier(session))
            } else {
                VStack(spacing: 18) {
                    Text("ATTIC")
                        .font(.text(26, weight: 700))
                        .tracking(6)
                        .foregroundStyle(Palette.textSecondary)
                    Text("Kies een spel op je iPhone")
                        .font(.display(60))
                        .foregroundStyle(Palette.text)
                    Text("Het beeld komt hier, en je iPhone wordt de controller.")
                        .font(.text(24))
                        .foregroundStyle(Palette.muted)
                }
                .multilineTextAlignment(.center)
                .padding(60)
            }
        }
    }
}

private struct ExternalGameView: View {
    let session: EmulatorSession
    private let display = ExternalDisplay.shared

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let aspect = session.aspectRatio
            Group {
                if session.game.system.screen.isDual && !display.bothScreens {
                    // Only the top screen, as large as the TV allows: the touch screen is on the iPhone.
                    let height = min(size.height, size.width / aspect)
                    MetalScreen(frameBuffer: session.frameBuffer, region: session.game.system.screen.topRegion)
                        .frame(width: height * aspect, height: height)
                } else if session.game.system.screen.isDual {
                    // Both screens side by side; the touch screen also stays on the iPhone.
                    let screen = session.game.system.screen
                    let bottomAspect = screen.bottomAspectRatio
                    let height = min(size.height, (size.width - 16) / (aspect + bottomAspect))
                    HStack(spacing: 16) {
                        MetalScreen(frameBuffer: session.frameBuffer, region: screen.topRegion)
                            .frame(width: height * aspect, height: height)
                        MetalScreen(frameBuffer: session.frameBuffer, region: screen.bottomRegion)
                            .frame(width: height * bottomAspect, height: height)
                    }
                } else {
                    let height = min(size.height, size.width / aspect)
                    MetalScreen(frameBuffer: session.frameBuffer)
                        .frame(width: height * aspect, height: height)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
    }
}

/// In the top bar of a DS or 3DS game on the TV, where the iPhone shows only the touch screen.
struct TVLine: View {
    var body: some View {
        Label("Op je tv", systemImage: "tv")
            .font(.text(13, weight: 600))
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
    }
}

/// Shown on the iPhone in place of the game while it plays on the TV.
struct TVNotice: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tv")
                .font(.system(size: 28, weight: .semibold))
            Text("Het spel speelt op je tv")
                .font(.text(15, weight: 600))
            Text("Je iPhone is nu de controller")
                .font(.text(13))
                .foregroundStyle(Palette.muted)
        }
        .foregroundStyle(Palette.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
