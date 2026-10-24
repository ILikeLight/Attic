import SwiftUI

/// The coloured background with one big shape.
struct CoverArt: View {
    let style: CoverStyle

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let motif = style.motif
            let size = width * motif.size
            ZStack(alignment: .topLeading) {
                style.background
                RoundedRectangle(cornerRadius: size * motif.radius, style: .continuous)
                    .fill(style.motifColor)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(motif.rotation))
                    .offset(x: width * motif.x, y: height * motif.y)
            }
        }
        .clipped()
    }
}

/// Text sizes of a cover at one of the three card sizes (SIZES in the prototype).
struct CoverMetrics {
    let stripHeight: CGFloat
    let stripFont: CGFloat
    let padding: CGFloat
    let preFont: CGFloat
    let radius: CGFloat
    /// Title sizes for ≤3, ≤6, ≤10 and longer main titles.
    let titleSizes: [CGFloat]

    static let small = CoverMetrics(stripHeight: 20, stripFont: 9, padding: 8, preFont: 9, radius: 12, titleSizes: [36, 20, 16, 13])
    static let medium = CoverMetrics(stripHeight: 26, stripFont: 11, padding: 12, preFont: 11, radius: 16, titleSizes: [56, 34, 26, 21])
    static let large = CoverMetrics(stripHeight: 30, stripFont: 12, padding: 18, preFont: 14, radius: 20, titleSizes: [110, 56, 48, 38])
    static let detail = CoverMetrics(stripHeight: 26, stripFont: 11, padding: 12, preFont: 11, radius: 16, titleSizes: [56, 34, 26, 21])
    static let badge = CoverMetrics(stripHeight: 20, stripFont: 9, padding: 8, preFont: 9, radius: 12, titleSizes: [36, 22, 18, 14])

    static func forSize(_ size: CardSize) -> CoverMetrics {
        switch size {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    func titleSize(for text: String) -> CGFloat {
        switch text.count {
        case ...3: titleSizes[0]
        case ...6: titleSizes[1]
        case ...10: titleSizes[2]
        default: titleSizes[3]
        }
    }
}

/// Box art of any shape on a card: whole, below the system strip, on its own average colour.
struct BoxArtView: View {
    let image: UIImage
    let art: BoxArt
    /// Room left free for the system strip.
    var top: CGFloat = 0

    var body: some View {
        ZStack {
            Color(hex: art.backdrop)
            Color.black.opacity(0.3)
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(.top, top)
        }
    }
}

/// A complete cover: box art when it was fetched, otherwise generated art with the title;
/// either way with the system strip.
struct GameCover: View {
    @Environment(\.accent) private var accent
    @Environment(CoverStore.self) private var covers
    let game: Game
    var metrics: CoverMetrics = .medium
    var showNewBadge = true

    var body: some View {
        let lines = game.coverLines
        let style = game.cover
        let image = covers.image(for: game)
        ZStack {
            if let image, let art = game.boxArt {
                BoxArtView(image: image, art: art, top: metrics.stripHeight)
            } else {
                CoverArt(style: style)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(game.shortLabel)
                    Spacer(minLength: 4)
                    if showNewBadge && game.isNew {
                        Text("NIEUW")
                            .tracking(metrics.stripFont * 0.04)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .foregroundStyle(Palette.ink)
                            .background(accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .font(.text(metrics.stripFont, weight: 700))
                .tracking(metrics.stripFont * 0.08)
                .foregroundStyle(.white)
                .padding(.horizontal, metrics.padding)
                .frame(height: metrics.stripHeight)
                .background(.black.opacity(0.45))

                Spacer(minLength: 0)

                if image == nil {
                    VStack(alignment: .leading, spacing: 3) {
                        if let pre = lines.pre {
                            Text(pre)
                                .font(.text(metrics.preFont, weight: 600))
                                .lineLimit(2)
                        }
                        Text(lines.main)
                            .font(.display(metrics.titleSize(for: lines.main)))
                            .tracking(-metrics.titleSize(for: lines.main) * 0.02)
                            .lineLimit(3)
                            .minimumScaleFactor(0.5)
                    }
                    .foregroundStyle(style.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(metrics.padding)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius, style: .continuous))
    }
}

/// A small cover thumbnail with only the system label, for lists and "Verder spelen".
struct CoverThumbnail: View {
    @Environment(CoverStore.self) private var covers
    let game: Game
    var stripHeight: CGFloat = 16
    var stripFont: CGFloat = 9
    var radius: CGFloat = 8
    var image: UIImage? = nil

    var body: some View {
        ZStack(alignment: .top) {
            if let image {
                // The whole picture in the system's screen shape, never cropped.
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(game.system.screen.aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let art = game.boxArt, let boxArt = covers.image(for: game) {
                    BoxArtView(image: boxArt, art: art, top: stripHeight)
                } else {
                    CoverArt(style: game.cover)
                }
                Text(game.shortLabel)
                    .font(.text(stripFont, weight: 700))
                    .tracking(stripFont * 0.06)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: stripHeight)
                    .background(.black.opacity(0.45))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
