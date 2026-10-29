import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
    @Environment(ImportCoordinator.self) private var importer
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let job = importer.current {
                    switch job.outcome {
                    case .duplicate(let game):
                        ImportResultView(job: job, title: "Staat al in je bibliotheek",
                                         message: "\(game.title) heb je al eerder toegevoegd. Er is niets dubbel bewaard.",
                                         primary: "Bekijk spel") {
                            close()
                            router.showLibrary(filter: nil)
                            router.open(game)
                        } secondary: {
                            importer.dismissFinished()
                        }
                    case .failed(let message):
                        ImportResultView(job: job, title: "Toevoegen is niet gelukt", message: message,
                                         primary: "Ander bestand kiezen") {
                            importer.dismissFinished()
                            picking = true
                        } secondary: {
                            importer.dismissFinished()
                        }
                    default:
                        // While adding and once added: one view, so the cover's reveal runs on.
                        ImportRunView(job: job) { game in
                            router.play(game)
                            close()
                        } finish: {
                            router.showLibrary(filter: nil)
                            close()
                        }
                    }
                } else {
                    options
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                importer.enqueue(.init(url: url, securityScoped: true))
            }
        }
    }

    private func close() {
        importer.dismissFinished()
        dismiss()
    }

    /// Which systems can be played, and which are only recognised so far.
    private static var playableSummary: String {
        let later = GameSystem.allCases.filter { !$0.isPlayable }.map(\.name)
        guard !later.isEmpty else { return "Alle systemen zijn speelbaar." }
        let names = later.count == 1 ? later[0] : later.dropLast().joined(separator: ", ") + " en " + later.last!
        return "Alle systemen zijn speelbaar, behalve \(names): die worden al herkend en komen in een volgende versie."
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Spellen toevoegen",
                        subtitle: "Kies back-ups van spellen die je zelf bezit. Een .zip of .7z pakken we uit, daarna herkennen we het spel aan de inhoud.") {
                dismiss()
            }
            VStack(spacing: 10) {
                ImportOption(systemImage: "folder", title: "Bestanden", subtitle: "Kies uit de Bestanden-app of iCloud Drive") {
                    picking = true
                }
                ImportOption(systemImage: "wifi", title: "Via wifi vanaf je computer", subtitle: "Komt in een volgende versie", isLater: true) {
                    notice = "Wifi-overdracht komt in een volgende versie. Gebruik zolang Bestanden of de map Attic in de Bestanden-app."
                }
                ImportOption(systemImage: "eye", title: "Map in de gaten houden",
                             subtitle: settings.watchFolder ? "Staat aan: alles in Bestanden › Attic komt er vanzelf bij" : "Alles in Bestanden › Attic komt er vanzelf bij") {
                    settings.watchFolder = true
                    toasts.show("Bestanden › Attic wordt nu in de gaten gehouden")
                    dismiss()
                }
            }
            if let notice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Palette.muted)
                    Text(notice).font(.text(13)).lineSpacing(2).foregroundStyle(Palette.textSecondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Ondersteund, los of in een .zip of .7z")
                    .font(.text(12))
                    .foregroundStyle(Palette.muted)
                FlowLayout(spacing: 6) {
                    ForEach([".iso", ".rvz", ".wbfs", ".3ds", ".nds", ".gba", ".gbc", ".z64", ".sfc", ".nes", ".cue", ".chd", ".cso", ".md", ".gdi"], id: \.self) {
                        Tag(text: $0, mono: true)
                    }
                }
                Text(Self.playableSummary)
                    .font(.text(12))
                    .lineSpacing(2)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .animation(.easeOut(duration: 0.2), value: notice)
    }
}

private struct ImportOption: View {
    @Environment(\.accent) private var accent
    let systemImage: String
    let title: String
    let subtitle: String
    /// Not built yet: shown dimmed, with "Later" instead of the arrow.
    var isLater = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 44, height: 44)
                    .background(Palette.raisedHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.text(15, weight: 600)).foregroundStyle(Palette.text)
                    Text(subtitle).font(.text(13)).foregroundStyle(Palette.muted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if isLater {
                    Text("Later").font(.text(12, weight: 600)).foregroundStyle(Palette.muted)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(14)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous))
            .opacity(isLater ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Progress

/// The game being added: its cover and title decode while the archive unpacks (`DecodingCover`,
/// `DecodingText`), and once it is added the same view offers to play it.
private struct ImportRunView: View {
    @Environment(\.accent) private var accent
    let job: ImportJob
    let play: (Game) -> Void
    let finish: () -> Void

    private var added: [Game]? {
        if case .added(let games, _) = job.outcome { games } else { nil }
    }

    private var game: Game? { added?.first ?? job.preview }

    /// The cover follows the unpacking once the game is known; it is whole when the game is added.
    private var coverProgress: Double {
        guard game != nil else { return 0 }
        if added != nil { return 1 }
        return job.current == .extract ? job.progress : 1
    }

    /// The title is readable well before the cover is whole.
    private var titleProgress: Double {
        game == nil ? 0 : min(1, coverProgress * 1.6 + 0.1)
    }

    /// Until the game is known, the letters search for the archive's name without its tags.
    private var title: String {
        if let game { return game.title }
        let name = (job.sourceName as NSString).deletingPathExtension
        let bare = name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        return bare.isEmpty ? name : bare
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                DecodingCover(game: game, progress: coverProgress, size: CGSize(width: 104, height: 138))
                    .padding(2)
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(added != nil ? accent : Palette.lineStrong, lineWidth: 2))
                VStack(alignment: .leading, spacing: 6) {
                    if added != nil {
                        Label("Toegevoegd", systemImage: "checkmark")
                            .font(.text(13, weight: 700))
                            .foregroundStyle(accent)
                    } else {
                        Eyebrow(text: "Stap \(job.current.rawValue + 1) van 4")
                    }
                    DecodingText(text: title, progress: titleProgress)
                        .font(.display(24))
                        .tracking(-0.48)
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let added, let game = added.first {
                        Text([game.system.name, game.region, DisplayText.fileSize(game.fileSize)].compactMap { $0 }.joined(separator: " · "))
                            .font(.text(13))
                            .foregroundStyle(Palette.muted)
                        if let code = game.gameCode {
                            Text("spelcode \(code)")
                                .font(.mono(12))
                                .foregroundStyle(Palette.muted)
                        }
                        if added.count > 1 {
                            Text("+ \(added.count - 1) \(added.count == 2 ? "ander spel" : "andere spellen")")
                                .font(.text(12, weight: 600))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    } else {
                        Text("\(job.sourceName) · \(DisplayText.fileSize(job.sourceSize))")
                            .font(.mono(13))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            ImportSteps(job: job)
            if let game = added?.first {
                VStack(spacing: 10) {
                    if game.system.isPlayable {
                        PrimaryButton(title: "Nu spelen", systemImage: "play.fill") { play(game) }
                    } else {
                        Text("\(game.system.coreName) voor \(game.system.name) \(game.system.arrival). Het spel staat alvast in je bibliotheek.")
                            .font(.text(13))
                            .lineSpacing(2)
                            .foregroundStyle(Palette.muted)
                    }
                    SecondaryButton(title: "Naar bibliotheek", action: finish)
                }
            }
        }
    }
}

private struct ImportSteps: View {
    let job: ImportJob

    var body: some View {
        RowGroup(background: Palette.raised) {
            ForEach(ImportJob.Step.allCases, id: \.self) { step in
                StepRow(step: step, state: job.state(of: step), progress: step == .extract ? job.progress : nil)
            }
        }
    }
}

private struct StepRow: View {
    @Environment(\.accent) private var accent
    let step: ImportJob.Step
    let state: ImportJob.StepState
    let progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            indicator.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.text(15, weight: 600))
                    .foregroundStyle(state.status == .waiting ? Palette.muted : Palette.text)
                Text(state.detail)
                    .font(state.monospaced ? .mono(13) : .text(13))
                    .foregroundStyle(state.status == .failed ? Palette.danger : Palette.muted)
                    .lineLimit(3)
                if state.status == .active, let progress {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.lineStrong)
                            Capsule().fill(accent).frame(width: geometry.size.width * progress)
                        }
                    }
                    .frame(height: 6)
                    .padding(.top, 6)
                    .animation(.linear(duration: 0.1), value: progress)
                }
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var indicator: some View {
        switch state.status {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Palette.ink)
                .frame(width: 28, height: 28)
                .background(accent, in: Circle())
        case .active:
            Spinner()
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Palette.ink)
                .frame(width: 28, height: 28)
                .background(Palette.danger, in: Circle())
        case .waiting:
            Circle().fill(Palette.lineStrong).frame(width: 10, height: 10)
        }
    }
}

private struct Spinner: View {
    @Environment(\.accent) private var accent
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(Palette.lineStrong, lineWidth: 3)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: 24, height: 24)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

// MARK: - Results

private struct ImportResultView: View {
    let job: ImportJob
    let title: String
    let message: String
    let primary: String
    let primaryAction: () -> Void
    let secondary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(job.sourceName)
                    .font(.mono(13))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ScreenTitle(text: title, size: 24)
                Text(message)
                    .font(.text(14))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ImportSteps(job: job)
            PrimaryButton(title: primary, action: primaryAction)
            SecondaryButton(title: "Terug", action: secondary)
        }
    }
}
