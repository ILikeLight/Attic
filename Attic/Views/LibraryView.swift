import SwiftUI

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(SaveStateStore.self) private var saveStates
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.accent) private var accent
    @State private var query = ""
    @State private var showViewOptions = false
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var visibleGames: [Game] {
        library.sortedGames.filter { game in
            (router.libraryFilter == nil || game.system == router.libraryFilter)
                && (trimmedQuery.isEmpty || game.title.lowercased().contains(trimmedQuery))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if library.games.isEmpty {
                    EmptyLibrary()
                } else {
                    // The view options sit with the search, so the title keeps room for two buttons.
                    HStack(spacing: 10) {
                        searchField
                        CircleButton(systemImage: settings.layout == .grid ? "square.grid.2x2" : "list.bullet", size: 46,
                                     iconSize: 17, label: "Weergave") {
                            showViewOptions = true
                        }
                    }
                    if trimmedQuery.isEmpty && router.libraryFilter == nil, let game = library.continueGame {
                        ContinueCard(game: game)
                    }
                    filterChips
                    let games = visibleGames
                    if games.isEmpty {
                        Text(trimmedQuery.isEmpty ? "Geen spellen voor dit systeem" : "Geen spellen gevonden voor “\(query)”")
                            .font(.text(14))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else if settings.layout == .grid {
                        GameGrid(games: games, size: settings.cardSize)
                    } else {
                        GameList(games: games, size: settings.cardSize)
                    }
                    AddMoreButton { router.showImport = true }
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .sheet(isPresented: $showViewOptions) {
            ViewOptionsSheet()
                .presentationDetents([.height(390)])
                .atticSheet()
        }
        // Removing from the context menu asks first, as on the game's page.
        .confirmationDialog(removalTitle, isPresented: Binding { router.removalRequest != nil } set: { if !$0 { router.removalRequest = nil } },
                            titleVisibility: .visible) {
            Button("Verwijderen", role: .destructive) {
                if let id = router.removalRequest {
                    library.remove(id)
                    saveStates.forget(id)
                }
                router.removalRequest = nil
            }
        } message: {
            Text("Het spel en alle saves worden van deze iPhone verwijderd.")
        }
    }

    private var removalTitle: String {
        router.removalRequest.flatMap(library.game).map { "\($0.title) verwijderen?" } ?? "Verwijderen?"
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: "Attic")
                ScreenTitle(text: "Bibliotheek")
            }
            Spacer()
            // This iPhone as a controller for a game on another one.
            CircleButton(systemImage: "gamecontroller", label: "Meedoen als controller") {
                router.showController = true
            }
            CircleButton(systemImage: "plus", background: accent, foreground: Palette.ink, iconSize: 20, label: "Spellen toevoegen") {
                router.showImport = true
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.muted)
            TextField("", text: $query, prompt: Text(library.games.count == 1 ? "Zoek in 1 spel" : "Zoek in \(library.games.count) spellen")
                .foregroundStyle(Palette.muted))
                .font(.text(15))
                .foregroundStyle(Palette.text)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                }
                .accessibilityLabel("Zoekopdracht wissen")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Palette.control, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var filterChips: some View {
        let systems = GameSystem.allCases.filter { library.count(of: $0) > 0 }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "Alles", count: library.games.count, isSelected: router.libraryFilter == nil) {
                    router.libraryFilter = nil
                }
                ForEach(systems) { system in
                    FilterChip(title: system.shortName, count: library.count(of: system), isSelected: router.libraryFilter == system) {
                        router.libraryFilter = system
                    }
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
        }
        .padding(.horizontal, -Metrics.screenPadding)
    }
}

private struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.text(14, weight: 600))
                Text("\(count)").font(.text(14, weight: 500)).opacity(0.7)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .foregroundStyle(isSelected ? Palette.ink : Palette.textSecondary)
            .background(isSelected ? Palette.text : Palette.control, in: Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Continue playing

private struct ContinueCard: View {
    @Environment(AppRouter.self) private var router
    @Environment(SaveStateStore.self) private var saveStates
    @Environment(\.accent) private var accent
    let game: Game

    var body: some View {
        let autosave = saveStates.autosave(for: game.id)
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Verder spelen")
            HStack(spacing: 12) {
                Button {
                    router.open(game)
                } label: {
                    HStack(spacing: 14) {
                        ZStack(alignment: .bottomLeading) {
                            CoverThumbnail(game: game, radius: 12, image: autosave.flatMap { saveStates.thumbnail(for: $0, gameID: game.id) })
                                .frame(width: 108, height: 72)
                            if autosave != nil {
                                Text("Auto-save")
                                    .font(.text(10, weight: 600))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .padding(6)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(game.title)
                                .font(.text(15, weight: 600))
                                .foregroundStyle(Palette.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text("\(game.shortLabel) · \(DisplayText.lastPlayed(game.lastPlayedAt))")
                                .font(.text(13))
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)

                CircleButton(systemImage: "play.fill", size: 44, background: accent, foreground: Palette.ink, iconSize: 16, label: "Verder spelen") {
                    router.play(game, from: autosave)
                }
            }
            .padding(12)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

// MARK: - Grid and list

private struct GameGrid: View {
    @Environment(AppRouter.self) private var router
    let games: [Game]
    let size: CardSize

    private var columns: [GridItem] {
        switch size {
        case .small: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)
        case .medium: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2)
        case .large: [GridItem(.flexible(), alignment: .top)]
        }
    }

    private var coverHeight: CGFloat {
        switch size {
        case .small: 150
        case .medium: 212
        case .large: 300
        }
    }

    private var titleFont: CGFloat {
        switch size {
        case .small: 12
        case .medium: 14
        case .large: 16
        }
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: size == .small ? 16 : (size == .medium ? 20 : 24)) {
            ForEach(games) { game in
                Button {
                    router.open(game)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        GameCover(game: game, metrics: .forSize(size))
                            .frame(height: coverHeight)
                            .overlay {
                                if game.isNew {
                                    NewGameRing(radius: CoverMetrics.forSize(size).radius)
                                }
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.title)
                                .font(.text(titleFont, weight: 600))
                                .foregroundStyle(Palette.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if size != .small {
                                Text([game.system.name, game.region].compactMap { $0 }.joined(separator: " · "))
                                    .font(.text(12))
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .contextMenu { GameContextMenu(game: game) }
                .accessibilityLabel("\(game.title), \(game.system.name)")
            }
        }
    }
}

/// Accent ring around a freshly imported game.
private struct NewGameRing: View {
    @Environment(\.accent) private var accent
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
            .strokeBorder(accent, lineWidth: 2)
            .padding(-4)
            .allowsHitTesting(false)
    }
}

private struct GameList: View {
    @Environment(AppRouter.self) private var router
    @Environment(SaveStateStore.self) private var saveStates
    @Environment(\.accent) private var accent
    let games: [Game]
    let size: CardSize

    private var thumbnailSize: CGSize {
        switch size {
        case .small: CGSize(width: 40, height: 52)
        case .medium: CGSize(width: 54, height: 70)
        case .large: CGSize(width: 72, height: 94)
        }
    }

    var body: some View {
        RowGroup {
            ForEach(games) { game in
                HStack(spacing: 12) {
                    Button {
                        router.open(game)
                    } label: {
                        HStack(spacing: 12) {
                            CoverThumbnail(game: game,
                                           stripHeight: size == .small ? 14 : (size == .medium ? 16 : 18),
                                           stripFont: size == .small ? 8 : (size == .medium ? 9 : 10))
                                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(game.title)
                                        .font(.text(size == .small ? 14 : (size == .medium ? 15 : 16), weight: 600))
                                        .foregroundStyle(Palette.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if game.isNew {
                                        Text("NIEUW")
                                            .font(.text(10, weight: 700))
                                            .tracking(0.4)
                                            .foregroundStyle(Palette.ink)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                }
                                Text("\(game.system.name) · \(DisplayText.lastPlayed(game.lastPlayedAt))")
                                    .font(.text(12))
                                    .foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)

                    CircleButton(systemImage: "play.fill", size: 40, background: Palette.button, foreground: accent, iconSize: 14,
                                 label: "Speel \(game.title)") {
                        router.play(game, from: saveStates.autosave(for: game.id))
                    }
                }
                .padding(.horizontal, size == .large ? 14 : 12)
                .padding(.vertical, size == .small ? 8 : (size == .medium ? 10 : 12))
                .contextMenu { GameContextMenu(game: game) }
            }
        }
    }
}

struct GameContextMenu: View {
    @Environment(AppRouter.self) private var router
    @Environment(Library.self) private var library
    @Environment(SaveStateStore.self) private var saveStates
    let game: Game

    var body: some View {
        Button {
            router.play(game, from: saveStates.autosave(for: game.id))
        } label: {
            Label("Spelen", systemImage: "play.fill")
        }
        Button {
            library.update(game.id) { $0.isFavorite.toggle() }
        } label: {
            Label(game.isFavorite ? "Geen favoriet meer" : "Favoriet", systemImage: game.isFavorite ? "star.slash" : "star")
        }
        Button(role: .destructive) {
            router.removalRequest = game.id
        } label: {
            Label("Verwijderen", systemImage: "trash")
        }
    }
}

private struct AddMoreButton: View {
    @Environment(\.accent) private var accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 44, height: 44)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meer spellen toevoegen")
                        .font(.text(15, weight: 600))
                        .foregroundStyle(Palette.text)
                    Text("Zip en 7z worden vanzelf uitgepakt en herkend")
                        .font(.text(13))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
                    .strokeBorder(Palette.lineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

private struct EmptyLibrary: View {
    @Environment(AppRouter.self) private var router
    @Environment(ImportCoordinator.self) private var importer
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                CoverArt(style: CoverStyle(seed: 0))
                VStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 34, weight: .semibold))
                    Text("Je zolder is nog leeg")
                        .font(.display(24))
                }
                .foregroundStyle(Color(hex: 0xFFD34D))
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text("Voeg back-ups toe van spellen die je zelf bezit. Een .zip of .7z pakt Attic vanzelf uit, daarna herkent hij het spel aan de inhoud van het bestand.")
                .font(.text(15))
                .lineSpacing(3)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            PrimaryButton(title: "Spellen toevoegen", systemImage: "plus") {
                router.showImport = true
            }
            SecondaryButton(title: "Probeer de demo-cartridge") {
                importer.importDemo()
                router.showImport = true
            }
            Text("De demo is een klein testprogramma voor de Game Boy Advance, gemaakt voor Attic. Zo zie je meteen of beeld, geluid en knoppen werken.")
                .font(.text(12))
                .lineSpacing(2)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - View options

struct ViewOptionsSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Weergave")
                    .font(.display(22))
                    .foregroundStyle(Palette.text)
                Spacer()
                CloseButton { dismiss() }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Indeling").font(.text(13)).foregroundStyle(Palette.muted)
                SegmentedChoice(options: [
                    .init(value: LibraryLayout.grid, title: "Raster", systemImage: "square.grid.2x2"),
                    .init(value: LibraryLayout.list, title: "Lijst", systemImage: "list.bullet"),
                ], selection: $settings.layout, large: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Grootte").font(.text(13)).foregroundStyle(Palette.muted)
                SegmentedChoice(options: CardSize.allCases.map { .init(value: $0, title: $0.title) },
                                selection: $settings.cardSize, large: true)
            }
            Text("Je keuze staat ook in Instellingen › Weergave.")
                .font(.text(12))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 28)
    }
}
