import Foundation
import Observation

enum LibraryLayout: String, CaseIterable {
    case grid, list
}

enum CardSize: String, CaseIterable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: "Klein"
        case .medium: "Normaal"
        case .large: "Groot"
        }
    }
}

/// User settings, stored in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var layout: LibraryLayout { didSet { defaults.set(layout.rawValue, forKey: "layout") } }
    var cardSize: CardSize { didSet { defaults.set(cardSize.rawValue, forKey: "cardSize") } }
    /// Visibility of the touch buttons, 0–100. At 0 they are invisible but still work.
    var buttonOpacity: Double { didSet { defaults.set(buttonOpacity, forKey: "buttonOpacity") } }
    var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    var iCloudSync: Bool { didSet { defaults.set(iCloudSync, forKey: "iCloudSync") } }
    var fetchCovers: Bool { didSet { defaults.set(fetchCovers, forKey: "fetchCovers") } }
    var watchFolder: Bool { didSet { defaults.set(watchFolder, forKey: "watchFolder") } }
    var cleanupArchives: Bool { didSet { defaults.set(cleanupArchives, forKey: "cleanupArchives") } }
    var autosave: Bool { didSet { defaults.set(autosave, forKey: "autosave") } }
    var rewind: Bool { didSet { defaults.set(rewind, forKey: "rewind") } }
    /// The default of each speed setting for all games, by core option (see `PerformanceSetting`);
    /// a setting that is not in here has its own default.
    private(set) var performance: [String: String] { didSet { defaults.set(performance, forKey: "performance") } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    /// Games may make controllers and iPhones vibrate (the Rumble Pak and the like).
    var rumble: Bool { didSet { defaults.set(rumble, forKey: "rumble") } }
    /// Changed controller buttons, by way of playing (`ControlScheme.id`), controller button and the
    /// console button it presses (`PadButton` raw value, -1 for none).
    private(set) var controllerMappings: [String: [String: Int]] {
        didSet { defaults.set(controllerMappings, forKey: "controllerMappings") }
    }
    /// Other iPhones with Attic may ask to join a game as players 2 to 4 (`MultiplayerHost`).
    var allowPlayers: Bool { didSet { defaults.set(allowPlayers, forKey: "allowPlayers") } }
    /// Frames per second, speed and processor use over the game while playing.
    var showPerformance: Bool { didSet { defaults.set(showPerformance, forKey: "showPerformance") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "layout": LibraryLayout.grid.rawValue,
            "cardSize": CardSize.medium.rawValue,
            "buttonOpacity": 80.0,
            "accent": AccentChoice.orange.rawValue,
            "iCloudSync": false,
            "fetchCovers": true,
            "watchFolder": false,
            "cleanupArchives": true,
            "autosave": true,
            "rewind": true,
            "haptics": true,
            "allowPlayers": false,
            "rumble": true,
            "showPerformance": false,
        ])
        layout = LibraryLayout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .grid
        cardSize = CardSize(rawValue: defaults.string(forKey: "cardSize") ?? "") ?? .medium
        buttonOpacity = defaults.double(forKey: "buttonOpacity")
        accent = AccentChoice(rawValue: defaults.string(forKey: "accent") ?? "") ?? .orange
        iCloudSync = defaults.bool(forKey: "iCloudSync")
        fetchCovers = defaults.bool(forKey: "fetchCovers")
        watchFolder = defaults.bool(forKey: "watchFolder")
        cleanupArchives = defaults.bool(forKey: "cleanupArchives")
        autosave = defaults.bool(forKey: "autosave")
        rewind = defaults.bool(forKey: "rewind")
        performance = defaults.dictionary(forKey: "performance") as? [String: String] ?? Self.earlierPerformance(defaults)
        haptics = defaults.bool(forKey: "haptics")
        allowPlayers = defaults.bool(forKey: "allowPlayers")
        rumble = defaults.bool(forKey: "rumble")
        controllerMappings = defaults.dictionary(forKey: "controllerMappings") as? [String: [String: Int]] ?? [:]
        showPerformance = defaults.bool(forKey: "showPerformance")
    }

    /// The speed settings from before they could be chosen per game, which had their own keys.
    private static func earlierPerformance(_ defaults: UserDefaults) -> [String: String] {
        var values: [String: String] = [:]
        if let clock = defaults.object(forKey: "dolphinClock") as? Double {
            values[PerformanceSetting.dolphinClock.id] = String(format: "%.2f", clock)
        }
        if let clock = defaults.object(forKey: "dreamcastClock") as? Int {
            values[PerformanceSetting.dreamcastClock.id] = String(clock)
        }
        return values
    }

    /// The default of a speed setting for all games.
    func value(of setting: PerformanceSetting) -> String {
        performance[setting.id] ?? setting.defaultValue
    }

    func setValue(_ value: String, of setting: PerformanceSetting) {
        performance[setting.id] = value
    }

    func mapping(for scheme: ControlScheme) -> ControllerMapping {
        var mapping = ControllerMapping()
        for (button, target) in controllerMappings[scheme.id] ?? [:] {
            guard let button = ControllerButton(rawValue: button) else { continue }
            mapping.changes[button] = target < 0 ? .some(nil) : PadButton(rawValue: target).map { .some($0) }
        }
        return mapping
    }

    /// Makes a controller button press `target` (nil: nothing); back at its default it is no longer stored.
    func setTarget(_ target: PadButton?, for button: ControllerButton, in scheme: ControlScheme) {
        var changes = controllerMappings[scheme.id] ?? [:]
        changes[button.rawValue] = target == button.defaultTarget ? nil : (target?.rawValue ?? -1)
        controllerMappings[scheme.id] = changes.isEmpty ? nil : changes
    }

    func resetMapping(for scheme: ControlScheme) {
        controllerMappings[scheme.id] = nil
    }

    /// Core options from the speed settings: the game's own choice, or else the default for all games.
    func coreOptions(for game: Game) -> [String: String] {
        var options: [String: String] = [:]
        for setting in PerformanceSetting.settings(for: game.system) {
            options[setting.id] = game.performance?[setting.id] ?? value(of: setting)
        }
        // The N64 has one slot in each controller: a Controller Pak for saves, or a Rumble Pak.
        if game.system == .n64, game.rumblePak == true {
            for port in 1...4 {
                options["mupen64plus-pak\(port)"] = "rumble"
            }
        }
        return options
    }
}
