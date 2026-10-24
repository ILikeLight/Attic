import Foundation

/// A speed setting for the games of some systems. Settings › Prestaties holds the default for all
/// games (`AppSettings.performance`), and a game can choose its own on its page (`Game.performance`).
struct PerformanceSetting: Identifiable {
    struct Choice: Hashable {
        /// The core option's value.
        let value: String
        let title: String
    }

    /// The core option the setting sets, such as `dolphin_cpu_clock_rate`.
    let id: String
    let systems: Set<GameSystem>
    /// The systems' name, above the setting in Settings, where all systems' settings are listed together.
    let group: String
    let title: String
    let detail: String
    let choices: [Choice]
    let defaultValue: String

    func title(for value: String) -> String {
        choices.first { $0.value == value }?.title ?? value
    }

    static func settings(for system: GameSystem) -> [PerformanceSetting] {
        all.filter { $0.systems.contains(system) }
    }

    static let all = [dolphinClock, dolphinShaders, dreamcastClock]

    /// A slower emulated processor leaves the interpreter less to do each frame.
    static let dolphinClock = PerformanceSetting(
        id: "dolphin_cpu_clock_rate", systems: [.gc, .wii], group: "GameCube en Wii", title: "Processor",
        detail: "Lager laat Dolphin minder rekenen en kan spellen vloeiender maken; sommige spellen worden er juist trager van.",
        choices: [.init(value: "1.00", title: "100%"), .init(value: "0.80", title: "80%"), .init(value: "0.60", title: "60%")],
        defaultValue: "1.00")

    /// Dolphin's ShaderCompilationMode. Each new combination of effects a game draws needs its own
    /// shader, and compiling one takes long enough on an iPhone to show as a hitch.
    static let dolphinShaders = PerformanceSetting(
        id: "dolphin_shader_compilation_mode", systems: [.gc, .wii], group: "GameCube en Wii", title: "Shaders",
        detail: "Hybride tekent iets nieuws eerst met een algemene shader, tot de eigen klaar is: geen haperingen, wel een langere eerste start. Overslaan laat het even weg; Wachten zet het spel stil tot de shader klaar is.",
        choices: [.init(value: "2", title: "Hybride"), .init(value: "3", title: "Overslaan"), .init(value: "0", title: "Wachten")],
        defaultValue: "2")

    /// Flycast's interpreter runs the SH4 at a fraction of its 200 MHz (Cores/patches/flycast/interpreter-clock.diff).
    static let dreamcastClock = PerformanceSetting(
        id: "reicast_sh4clock", systems: [.dc], group: "Dreamcast", title: "Processor",
        detail: "100% is de echte 200 MHz. Hoger laat zware spellen minder haperen, maar laat Flycast meer rekenen; is dat te veel voor de iPhone, dan loopt het spel juist trager.",
        choices: [.init(value: "200", title: "100%"), .init(value: "100", title: "50%"), .init(value: "50", title: "25%")],
        defaultValue: "50")
}
