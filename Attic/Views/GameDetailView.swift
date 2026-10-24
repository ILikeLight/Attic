import SwiftUI

struct GameDetailView: View {
    @Environment(Library.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(SaveStateStore.self) private var saveStates
    @Environment(AppSettings.self) private var settings
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    let gameID: UUID
    @State private var confirmDelete = false

    var body: some View {
        if let game = library.game(gameID) {
            content(game)
                .onAppear {
                    if game.isNew {
                        library.update(game.id) { $0.isNew = false }
                    }
                }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private func content(_ game: Game) -> some View {
        let states = saveStates.states(for: game.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                topBar(game)
                hero(game)
                PrimaryButton(title: "Spelen", systemImage: "play.fill") {
                    router.play(game, from: saveStates.autosave(for: game.id))
                }
                stats(game, saveCount: states.count)
                saveStateSection(game, states: states)
                wiiControlsSection(game)
                n64PakSection(game)
                performanceSection(game)
                TitledSection(title: "Herkenning") {
                    RowGroup {
                        InfoRow(label: "Herkend via", value: recognitionText(game), monospaced: game.gameCode != nil)
                        InfoRow(label: "Titel uit", value: titleSource(game))
                        if let name = game.databaseName {
                            InfoRow(label: "In de database", value: name)
                        }
                        InfoRow(label: "Hoes", value: coverSource(game))
                        InfoRow(label: "Bestand", value: game.fileName, monospaced: true)
                        if let archive = game.archiveName {
                            InfoRow(label: "Uitgepakt uit", value: archive, monospaced: true)
                        }
                        if let crc = game.crc32 {
                            InfoRow(label: "CRC32", value: crc, monospaced: true)
                        }
                    }
                }
                TitledSection(title: "Emulatie") {
                    RowGroup {
                        InfoRow(label: "Emulator", value: game.system.isPlayable
                            ? game.system.coreName
                            : "\(game.system.coreName) · \(game.system.availability.lowercased())")
                        InfoRow(label: "Besturing", value: game.system == .wii ? game.wiiSettings.controller.title : game.system.controlsDescription)
                        InfoRow(label: "Beeld", value: game.system.is3D ? "2× resolutie" : "Scherpe pixels")
                    }
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text("Verwijderen uit bibliotheek")
                        .font(.text(15, weight: 600))
                        .foregroundStyle(Palette.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .confirmationDialog("\(game.title) verwijderen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Verwijderen", role: .destructive) {
                        library.remove(game.id)
                        saveStates.forget(game.id)
                        dismiss()
                    }
                } message: {
                    Text("Het spel en alle saves worden van deze iPhone verwijderd.")
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 4)
            .padding(.bottom, 48)
        }
        .background(Palette.background)
        .statusBarScrim()
        .toolbar(.hidden, for: .navigationBar)
    }

    private func topBar(_ game: Game) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold))
                    Text("Bibliotheek").font(.text(16, weight: 600))
                }
                .foregroundStyle(accent)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            Spacer()
            CircleButton(systemImage: game.isFavorite ? "star.fill" : "star", size: 44,
                         foreground: game.isFavorite ? accent : Palette.textSecondary, iconSize: 18,
                         label: game.isFavorite ? "Geen favoriet meer" : "Favoriet") {
                library.update(game.id) { $0.isFavorite.toggle() }
            }
        }
    }

    private func hero(_ game: Game) -> some View {
        HStack(alignment: .bottom, spacing: 18) {
            GameCover(game: game, metrics: .detail, showNewBadge: false)
                .frame(width: 148, height: 196)
                .shadow(color: .black.opacity(0.45), radius: 20, y: 18)
            VStack(alignment: .leading, spacing: 8) {
                Text(game.system.name)
                    .font(.text(12, weight: 600))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(game.title)
                    .font(.display(26))
                    .tracking(-0.52)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text([game.region, game.year, DisplayText.fileSize(game.fileSize)].compactMap { $0 }.joined(separator: " · "))
                    .font(.text(13))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.bottom, 4)
        }
    }

    private func stats(_ game: Game, saveCount: Int) -> some View {
        HStack(spacing: 8) {
            StatTile(label: "Gespeeld", value: DisplayText.lastPlayed(game.lastPlayedAt))
            StatTile(label: "Speeltijd", value: DisplayText.playTime(game.playTime, played: game.lastPlayedAt != nil))
            StatTile(label: "Saves", value: "\(saveCount)")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func saveStateSection(_ game: Game, states: [SaveState]) -> some View {
        TitledSection(title: "Save states") {
            if states.isEmpty {
                Text("Nog geen save states. Tijdens het spelen bewaar je er een via Menu › Opslaan. Houd er een ingedrukt om hem te verwijderen.")
                    .font(.text(14))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(states) { state in
                            Button {
                                router.play(game, from: state)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    CoverThumbnail(game: game, radius: 12, image: saveStates.thumbnail(for: state, gameID: game.id))
                                        .frame(width: 132, height: 84)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(state.label).font(.text(13, weight: 600)).foregroundStyle(Palette.text)
                                        Text(DisplayText.savedAt(state.date)).font(.text(12)).foregroundStyle(Palette.muted)
                                    }
                                }
                                .frame(width: 132, alignment: .leading)
                            }
                            .buttonStyle(.pressable)
                            // Hold a save state to delete it.
                            .contextMenu {
                                Button("Verwijderen", systemImage: "trash", role: .destructive) {
                                    saveStates.delete(state, gameID: game.id)
                                }
                            }
                            .accessibilityLabel("\(state.label), \(DisplayText.savedAt(state.date)). Speel verder vanaf hier.")
                        }
                    }
                    .padding(.horizontal, Metrics.screenPadding)
                }
                .padding(.horizontal, -Metrics.screenPadding)
            }
        }
    }

    /// How a Wii game is played: which controller, and whether the Wii Remote moves with the iPhone.
    @ViewBuilder
    private func wiiControlsSection(_ game: Game) -> some View {
        if game.system == .wii {
            let controls = Binding {
                game.wiiSettings
            } set: { value in
                library.update(game.id) { $0.wiiControls = value }
            }
            TitledSection(title: "Besturing") {
                Text("Kies de controller die het spel verwacht; op de doos van het spel staat welke het ondersteunt. Het geldt vanaf de volgende keer dat je het spel start.")
                    .font(.text(13))
                    .lineSpacing(2)
                    .foregroundStyle(Palette.muted)
                RowGroup {
                    WiiControllerRow(selection: controls.controller)
                    Toggle(isOn: controls.motion) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Beweging van de iPhone").font(.text(15)).foregroundStyle(Palette.text)
                            Text(game.wiiSettings.controller.isWiiRemote
                                 ? "Kantel, zwaai en schud je iPhone zoals een Wii Remote. Hoe je hem houdt als het spel start, telt als recht; met de ⌖-knop bovenin zet je dat (en het midden van de aanwijzer) opnieuw."
                                 : "Alleen met een Wii Remote")
                                .font(.text(12))
                                .lineSpacing(2)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .tint(accent)
                    .disabled(!game.wiiSettings.controller.isWiiRemote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    /// What sits in the slot of an N64 controller: a Controller Pak keeps saves of games that use
    /// one, a Rumble Pak makes the controller (or the iPhone) vibrate.
    @ViewBuilder
    private func n64PakSection(_ game: Game) -> some View {
        if game.system == .n64 {
            TitledSection(title: "Besturing") {
                Text("Op de N64 zit er één ding in de controller: een Controller Pak voor saves, of een Rumble Pak die trilt. Spellen die hun saves op de cartridge bewaren, hebben de Controller Pak niet nodig. Het geldt vanaf de volgende keer dat je het spel start.")
                    .font(.text(13))
                    .lineSpacing(2)
                    .foregroundStyle(Palette.muted)
                RowGroup {
                    HStack(spacing: 12) {
                        Text("In de controller").font(.text(15)).foregroundStyle(Palette.text)
                        Spacer(minLength: 0)
                        SegmentedChoice(options: [.init(value: false, title: "Controller Pak"), .init(value: true, title: "Rumble Pak")],
                                        selection: Binding {
                            game.rumblePak ?? false
                        } set: { value in
                            library.update(game.id) { $0.rumblePak = value ? true : nil }
                        })
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    /// The speed settings of the game's system: each follows the default for all games until the game gets its own.
    @ViewBuilder
    private func performanceSection(_ game: Game) -> some View {
        let performanceSettings = PerformanceSetting.settings(for: game.system)
        if !performanceSettings.isEmpty {
            TitledSection(title: "Prestaties") {
                Text("Hapert dit spel of loopt het te traag, kies dan iets anders dan de standaard. Uitleg staat in Instellingen › Prestaties.")
                    .font(.text(13))
                    .lineSpacing(2)
                    .foregroundStyle(Palette.muted)
                RowGroup {
                    ForEach(performanceSettings) { setting in
                        PerformanceRow(setting: setting, defaultValue: settings.value(of: setting), selection: Binding {
                            game.performance?[setting.id]
                        } set: { value in
                            library.update(game.id) { game in
                                var choices = game.performance ?? [:]
                                choices[setting.id] = value
                                game.performance = choices.isEmpty ? nil : choices
                            }
                        })
                    }
                }
            }
        }
    }

    private func recognitionText(_ game: Game) -> String {
        switch game.recognizedBy {
        case .gameCode: "Spelcode \(game.gameCode ?? "")"
        case .header: "Spelkop"
        case .fileExtension: "Bestandsextensie"
        }
    }

    private func titleSource(_ game: Game) -> String {
        if game.databaseName != nil {
            return "libretro-database"
        }
        if let header = game.headerTitle, TitleFormatter.titleCase(header) == game.title || header == game.title {
            return "Spelkop"
        }
        return "Bestandsnaam"
    }

    private func coverSource(_ game: Game) -> String {
        if let art = game.boxArt { return art.source.name }
        return game.boxArtCheckedAt == nil ? "Nog niet opgehaald" : "Niet gevonden"
    }
}

private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.text(12)).foregroundStyle(Palette.muted)
            Text(value)
                .font(.text(14, weight: 600))
                .foregroundStyle(Palette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.text(14))
                .foregroundStyle(Palette.muted)
                .fixedSize()
            Spacer(minLength: 0)
            Text(value)
                .font(monospaced ? .mono(14, weight: 600) : .text(14, weight: 600))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// A speed setting for one game: the default for all games, or a choice of its own.
private struct PerformanceRow: View {
    @Environment(\.accent) private var accent
    let setting: PerformanceSetting
    /// The default for all games, from Settings › Prestaties.
    let defaultValue: String
    /// The game's own choice; nil follows the default.
    @Binding var selection: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(setting.title).font(.text(15)).foregroundStyle(Palette.text)
                Text(selection == nil ? "Volgt de standaard" : "Alleen dit spel · standaard is \(setting.title(for: defaultValue))")
                    .font(.text(12))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Menu {
                Picker(setting.title, selection: $selection) {
                    Text("Standaard (\(setting.title(for: defaultValue)))").tag(String?.none)
                    ForEach(setting.choices, id: \.value) { choice in
                        Text(choice.title).tag(String?.some(choice.value))
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(selection.map(setting.title(for:)) ?? "Standaard (\(setting.title(for: defaultValue)))")
                        .font(.text(14, weight: 600))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(selection == nil ? Palette.textSecondary : accent)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("\(setting.title): \(selection.map(setting.title(for:)) ?? "standaard")")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The controller a Wii game is played with.
private struct WiiControllerRow: View {
    @Environment(\.accent) private var accent
    @Binding var selection: WiiController

    var body: some View {
        HStack(spacing: 12) {
            Text("Controller").font(.text(15)).foregroundStyle(Palette.text)
            Spacer(minLength: 0)
            Menu {
                Picker("Controller", selection: $selection) {
                    ForEach(WiiController.allCases) { controller in
                        Text(controller.title).tag(controller)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(selection.title).font(.text(14, weight: 600))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("Controller: \(selection.title)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
