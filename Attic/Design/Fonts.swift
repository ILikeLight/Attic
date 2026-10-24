import SwiftUI
import UIKit

/// The three typefaces of the design. All are variable fonts, so weights and
/// optical sizes are set through their variation axes.
enum Typeface {
    /// Bricolage Grotesque, for headings and cover titles.
    case display
    /// Inter, for running text.
    case text
    /// JetBrains Mono, for file names and codes.
    case mono

    fileprivate var postScriptName: String {
        switch self {
        case .display: "BricolageGrotesque-96ptExtraBold"
        case .text: "Inter-Regular"
        case .mono: "JetBrainsMono-Regular"
        }
    }

    fileprivate var opticalSizes: ClosedRange<CGFloat>? {
        switch self {
        case .display: 12...96
        case .text: 14...32
        case .mono: nil
        }
    }

    fileprivate func fallback(size: CGFloat, weight: CGFloat) -> UIFont {
        let systemWeight: UIFont.Weight = switch weight {
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        default: .heavy
        }
        switch self {
        case .mono: return .monospacedSystemFont(ofSize: size, weight: systemWeight)
        default: return .systemFont(ofSize: size, weight: systemWeight)
        }
    }
}

private final class FontCache: @unchecked Sendable {
    static let shared = FontCache()

    private let lock = NSLock()
    private var fonts: [String: Font] = [:]

    private static let weightAxis = NSNumber(value: 0x7767_6874)  // 'wght'
    private static let opticalSizeAxis = NSNumber(value: 0x6F70_737A)  // 'opsz'

    func font(_ face: Typeface, size: CGFloat, weight: CGFloat) -> Font {
        let key = "\(face)-\(size)-\(weight)"
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[key] {
            return font
        }
        let font = Font(Self.makeFont(face, size: size, weight: weight))
        fonts[key] = font
        return font
    }

    static func makeFont(_ face: Typeface, size: CGFloat, weight: CGFloat) -> UIFont {
        guard UIFont(name: face.postScriptName, size: size) != nil else {
            return face.fallback(size: size, weight: weight)
        }
        var axes: [NSNumber: NSNumber] = [weightAxis: NSNumber(value: Double(weight))]
        if let range = face.opticalSizes {
            axes[opticalSizeAxis] = NSNumber(value: Double(min(max(size, range.lowerBound), range.upperBound)))
        }
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: face.postScriptName,
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): axes,
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
}

extension Font {
    static func display(_ size: CGFloat, weight: CGFloat = 800) -> Font {
        FontCache.shared.font(.display, size: size, weight: weight)
    }

    static func text(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        FontCache.shared.font(.text, size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: CGFloat = 500) -> Font {
        FontCache.shared.font(.mono, size: size, weight: weight)
    }
}
