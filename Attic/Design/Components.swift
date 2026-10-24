import SwiftUI

/// Small uppercase label above titles and sections ("BIBLIOTHEEK", "SAVE STATES").
struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.text(12, weight: 700))
            .tracking(1.44)
            .foregroundStyle(Palette.muted)
    }
}

/// The large screen title in Bricolage Grotesque.
struct ScreenTitle: View {
    let text: String
    var size: CGFloat = 34

    var body: some View {
        Text(text)
            .font(.display(size))
            .tracking(-size * 0.02)
            .foregroundStyle(Palette.text)
    }
}

/// Dims and shrinks a button slightly while it is pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

/// A rounded group of rows with hairlines between them, as used for settings and tables.
struct RowGroup<Content: View>: View {
    var background: Color = Palette.surface
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    VStack(spacing: 0) {
                        if index > 0 {
                            Rectangle().fill(Palette.line).frame(height: 1)
                        }
                        row
                    }
                }
            }
        }
        .background(background, in: RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous))
    }
}

/// A titled section: eyebrow label plus content.
struct TitledSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: title)
            content
        }
    }
}

/// The wide accent button ("Spelen", "Verder spelen").
struct PrimaryButton: View {
    @Environment(\.accent) private var accent
    let title: String
    var systemImage: String? = nil
    var height: CGFloat = Metrics.primaryHeight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 16, weight: .bold))
                }
                Text(title).font(.text(17, weight: 700))
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(Palette.ink)
            .background(accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.pressable)
    }
}

struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.text(16, weight: 600))
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.primaryHeight)
                .foregroundStyle(Palette.text)
                .background(Palette.button, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.pressable)
    }
}

/// Round icon button, e.g. the view and add buttons in the library header.
struct CircleButton: View {
    let systemImage: String
    var size: CGFloat = 48
    var background: Color = Palette.control
    var foreground: Color = Palette.text
    var iconSize: CGFloat = 19
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(background, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
    }
}

struct CloseButton: View {
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        CircleButton(systemImage: "xmark", size: size, background: Palette.button, iconSize: 15, label: "Sluiten", action: action)
    }
}

/// Title row of a bottom sheet with a close button.
struct SheetHeader: View {
    let title: String
    var subtitle: String? = nil
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.display(24))
                    .tracking(-0.24)
                    .foregroundStyle(Palette.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.text(14))
                        .lineSpacing(3)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            CloseButton(action: close)
        }
    }
}

/// Segmented choice with a light pill for the selected option.
struct SegmentedChoice<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var systemImage: String? = nil
    }

    let options: [Option]
    @Binding var selection: Value
    var large = false

    var body: some View {
        HStack(spacing: large ? 4 : 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 8) {
                        if let systemImage = option.systemImage {
                            Image(systemName: systemImage).font(.system(size: 14, weight: .semibold))
                        }
                        Text(option.title).font(.text(large ? 14 : 13, weight: 600))
                    }
                    .frame(maxWidth: large ? .infinity : nil)
                    .padding(.horizontal, large ? 0 : 10)
                    .frame(height: large ? 42 : 32)
                    .foregroundStyle(isSelected ? Palette.ink : Palette.textSecondary)
                    .background(isSelected ? Palette.text : .clear, in: RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(large ? 4 : 3)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: large ? 14 : 11, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// Small rounded tag, used for file formats and system names.
struct Tag: View {
    let text: String
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? .mono(12) : .text(12, weight: 600))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Wrapping layout for tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Grab handle at the top of the custom sheets.
struct SheetGrabber: View {
    var body: some View {
        Capsule()
            .fill(Palette.lineStrong)
            .frame(width: 40, height: 5)
    }
}

extension View {
    /// Keeps scrolled content from showing through behind the clock and battery.
    func statusBarScrim() -> some View {
        overlay(alignment: .top) {
            GeometryReader { geometry in
                Palette.background
                    .opacity(0.94)
                    .frame(height: geometry.safeAreaInsets.top)
                    .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
        }
    }

    /// The dark bottom-sheet look of the prototype.
    func atticSheet() -> some View {
        presentationBackground(Palette.surface)
            .presentationCornerRadius(Metrics.sheetRadius)
            .presentationDragIndicator(.visible)
    }
}
