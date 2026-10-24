import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// The colours of the prototype (prototype/project/Main.dc.html).
enum Palette {
    static let background = Color(hex: 0x0D0E12)
    static let surface = Color(hex: 0x17191F)
    static let raised = Color(hex: 0x1F2229)
    static let raisedHigh = Color(hex: 0x2A2E37)
    static let control = Color(hex: 0x1A1C22)
    static let button = Color(hex: 0x262A33)
    static let line = Color(hex: 0x262A33)
    static let lineStrong = Color(hex: 0x3A3E48)
    static let text = Color(hex: 0xF2F3F5)
    static let textSecondary = Color(hex: 0xC9CDD4)
    static let muted = Color(hex: 0x9AA0AC)
    static let faint = Color(hex: 0x5D636E)
    static let tabInactive = Color(hex: 0x8B919C)
    static let tabBar = Color(hex: 0x121318)
    static let tabBarLine = Color(hex: 0x23262E)
    /// Text on the accent colour and on light chips.
    static let ink = Color(hex: 0x0D0E12)
    static let danger = Color(hex: 0xFF5A52)
}

enum AccentChoice: String, CaseIterable, Identifiable, Codable {
    case orange, green, blue, yellow

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .orange: Color(hex: 0xFF6B3D)
        case .green: Color(hex: 0x3DDC97)
        case .blue: Color(hex: 0x4D8DFF)
        case .yellow: Color(hex: 0xFFC53D)
        }
    }

    var name: String {
        switch self {
        case .orange: "Oranje"
        case .green: "Groen"
        case .blue: "Blauw"
        case .yellow: "Geel"
        }
    }
}

extension EnvironmentValues {
    @Entry var accent: Color = AccentChoice.orange.color
}

/// Corner radii and sizes that repeat across screens.
enum Metrics {
    static let screenPadding: CGFloat = 20
    static let groupRadius: CGFloat = 18
    static let sheetRadius: CGFloat = 28
    static let primaryHeight: CGFloat = 54
}
