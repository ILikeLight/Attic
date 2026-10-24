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
    var isConnected: Bool { scenes > 0 }
    /// The game being played; set by the player.
    var session: EmulatorSession?
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
    }
}

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

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let aspect = session.aspectRatio
            Group {
                if session.game.system.screen.isDual {
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

/// Shown on the iPhone in place of the game while it plays on the TV.
struct TVNotice: View {
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            Image(systemName: "tv")
                .font(.system(size: compact ? 20 : 28, weight: .semibold))
            Text("Het spel speelt op je tv")
                .font(.text(compact ? 13 : 15, weight: 600))
            Text("Je iPhone is nu de controller")
                .font(.text(compact ? 12 : 13))
                .foregroundStyle(Palette.muted)
        }
        .foregroundStyle(Palette.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
