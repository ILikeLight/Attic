import GameController
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accent) private var accent
    @Environment(\.openURL) private var openURL
    @State private var showLicenses = false
    @State private var showControllers = false
    @State private var controllerName = GameControllerInput.connected.first?.vendorName

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "Attic")
                    ScreenTitle(text: "Instellingen")
                }

                TitledSection(title: "Weergave") {
                    RowGroup {
                        SegmentRow(label: "Bibliotheek") {
                            SegmentedChoice(options: [.init(value: LibraryLayout.grid, title: "Raster"),
                                                      .init(value: LibraryLayout.list, title: "Lijst")],
                                            selection: $settings.layout)
                        }
                        SegmentRow(label: "Grootte") {
                            SegmentedChoice(options: CardSize.allCases.map { .init(value: $0, title: $0.title) },
                                            selection: $settings.cardSize)
                        }
                        SegmentRow(label: "Accentkleur") {
                            HStack(spacing: 10) {
                                ForEach(AccentChoice.allCases) { choice in
                                    Button {
                                        settings.accent = choice
                                    } label: {
                                        Circle()
                                            .fill(choice.color)
                                            .frame(width: 26, height: 26)
                                            .overlay(Circle().strokeBorder(Palette.text, lineWidth: settings.accent == choice ? 2 : 0).padding(-4))
                                            .padding(4)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(choice.name)
                                    .accessibilityAddTraits(settings.accent == choice ? .isSelected : [])
                                }
                            }
                        }
                    }
                }

                TitledSection(title: "Bibliotheek") {
                    RowGroup {
                        ToggleRow(label: "iCloud-synchronisatie", detail: "Spellen, saves en instellingen op al je apparaten. Komt in een volgende versie.",
                                  isOn: $settings.iCloudSync)
                            .disabled(true)
                        ToggleRow(label: "Hoesjes automatisch ophalen", detail: "Hoesjes van GameTDB en libretro. Titels en jaartallen komen uit de libretro-database, die in de app zit.",
                                  isOn: $settings.fetchCovers)
                        ToggleRow(label: "Map in de gaten houden", detail: "Nieuwe spellen in Bestanden › Attic komen er vanzelf bij",
                                  isOn: $settings.watchFolder)
                        ToggleRow(label: "Archief opruimen na uitpakken", detail: "Verwijdert de .zip of .7z, dat scheelt ruimte",
                                  isOn: $settings.cleanupArchives)
                    }
                }

                TitledSection(title: "Spelen") {
                    RowGroup {
                        OpacityRow(value: $settings.buttonOpacity)
                        ToggleRow(label: "Automatisch opslaan bij stoppen", isOn: $settings.autosave)
                        ToggleRow(label: "Terugspoelen", detail: "Houd ⏪ ingedrukt tijdens het spelen om tot een minuut terug te gaan. Kost wat extra geheugen en batterij.",
                                  isOn: $settings.rewind)
                        ToggleRow(label: "Trillen bij knoppen", isOn: $settings.haptics)
                        ToggleRow(label: "Trillen in spellen", detail: "Als een spel trilt (Rumble Pak, Wii Remote), trilt je controller mee, of zonder controller je iPhone",
                                  isOn: $settings.rumble)
                        ValueRow(label: "Controllers", value: controllerName ?? "Geen verbonden") {
                            showControllers = true
                        }
                        LaterRow(label: "Skin", value: "Donker", detail: "Andere skins kiezen komt in een volgende versie")
                    }
                }

                TitledSection(title: "Prestaties") {
                    Text("De standaard voor alle spellen. Op de pagina van een spel kies je zo nodig iets anders voor dat spel.")
                        .font(.text(13))
                        .lineSpacing(2)
                        .foregroundStyle(Palette.muted)
                    RowGroup {
                        ToggleRow(label: "Prestaties tonen", detail: "Beelden per seconde, snelheid en processorgebruik boven het spel",
                                  isOn: $settings.showPerformance)
                        ForEach(PerformanceSetting.all) { setting in
                            SegmentRow(label: "\(setting.group) · \(setting.title)", detail: setting.detail) {
                                SegmentedChoice(options: setting.choices.map { .init(value: $0.value, title: $0.title) },
                                                selection: Binding { settings.value(of: setting) } set: { settings.setValue($0, of: setting) })
                            }
                        }
                    }
                }

                TitledSection(title: "Over") {
                    RowGroup {
                        ValueRow(label: "Emulators en licenties", value: "") {
                            showLicenses = true
                        }
                        ValueRow(label: "Broncode", value: "GitHub") {
                            openURL(AtticLinks.source)
                        }
                        ValueRow(label: "Privacybeleid", value: "") {
                            openURL(AtticLinks.privacy)
                        }
                        InfoRow(label: "Versie", value: Self.version)
                    }
                }

                Text("Attic bevat geen spellen. Je speelt alleen back-ups van spellen die je zelf bezit.")
                    .font(.text(12))
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .sheet(isPresented: $showLicenses) {
            LicensesView()
                .presentationDetents([.large])
                .atticSheet()
        }
        .sheet(isPresented: $showControllers) {
            ControllersView()
                .presentationDetents([.large])
                .atticSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            controllerName = GameControllerInput.connected.first?.vendorName
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            controllerName = GameControllerInput.connected.first?.vendorName
        }
    }

    /// "0.4 (4)": the version and build number Xcode puts in the app (MARKETING_VERSION, CURRENT_PROJECT_VERSION).
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

private struct SegmentRow<Content: View>: View {
    let label: String
    var detail: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        // With an explanation the choices go underneath, so neither the text nor the choices are squeezed.
        let layout = detail == nil ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.text(15)).foregroundStyle(Palette.text)
                if let detail {
                    Text(detail).font(.text(12)).lineSpacing(2).foregroundStyle(Palette.muted)
                }
            }
            if detail == nil {
                Spacer(minLength: 0)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct ToggleRow: View {
    @Environment(\.accent) private var accent
    @Environment(\.isEnabled) private var isEnabled
    let label: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.text(15)).foregroundStyle(Palette.text)
                if let detail {
                    Text(detail).font(.text(12)).lineSpacing(2).foregroundStyle(Palette.muted)
                }
            }
        }
        .tint(accent)
        .opacity(isEnabled ? 1 : 0.55)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct ValueRow: View {
    let label: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(label).font(.text(15)).foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                Text(value).font(.text(14)).foregroundStyle(Palette.muted)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

/// A setting that is not built yet: what it is now, and that more comes in a later version.
private struct LaterRow: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.text(15)).foregroundStyle(Palette.text)
                Text(detail).font(.text(12)).lineSpacing(2).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Text(value).font(.text(14)).foregroundStyle(Palette.muted)
        }
        .opacity(0.55)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// The visibility slider with a small preview of the buttons over a game.
private struct OpacityRow: View {
    @Environment(\.accent) private var accent
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Zichtbaarheid knoppen").font(.text(15)).foregroundStyle(Palette.text)
                Spacer()
                Text("\(Int(value))%").font(.mono(13)).foregroundStyle(Palette.textSecondary)
            }
            Slider(value: $value, in: 0...100, step: 5)
                .tint(accent)
                .accessibilityLabel("Zichtbaarheid knoppen")
            ZStack {
                CoverArt(style: CoverStyle(seed: 0))
                HStack {
                    Circle()
                        .fill(Color(hex: 0x0D0E12, opacity: 0.45))
                        .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                        .frame(width: 48, height: 48)
                    Spacer()
                    HStack(spacing: 8) {
                        ForEach(["B", "A"], id: \.self) { label in
                            Text(label)
                                .font(.text(15, weight: 700))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Color(hex: 0x0D0E12, opacity: 0.45), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .opacity(value / 100)
                VStack {
                    Spacer()
                    Text("Voorbeeld").font(.text(10)).foregroundStyle(.white.opacity(0.75)).padding(.bottom, 6)
                }
            }
            .frame(height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
            Text("Bij 0% zijn de knoppen onzichtbaar, maar ze werken nog")
                .font(.text(12))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// Where Attic's source and privacy policy are published (GPL 3: the source must be available).
enum AtticLinks {
    static let source = URL(string: "https://github.com/ILikeLight/Attic")!
    static let privacy = URL(string: "https://github.com/ILikeLight/Attic/blob/main/PRIVACY.md")!
}

struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var shown: String?

    private let components: [(name: String, role: String, license: String, file: String)] = [
        ("Attic", "Deze app · ILikeLight. De broncode staat op github.com/ILikeLight/Attic. De naam Attic en het logo vallen niet onder de GPL (artikel 7e): een aangepaste versie krijgt een eigen naam en icoon.", "GPL 3", "GPL-3.0-Attic"),
        ("mGBA", "Emulator voor Game Boy, Game Boy Color en Game Boy Advance · Jeffrey Pfau en anderen", "Mozilla Public License 2.0", "MPL-2.0-mGBA"),
        ("Nestopia UE", "Emulator voor NES · Martin Freij, Nestopia UE-bijdragers en Rupert Carmichael", "GPL 2 of later", "GPL-2.0-Nestopia"),
        ("bsnes", "Emulator voor Super Nintendo · byuu en anderen", "GPL 3", "GPL-3.0-bsnes"),
        ("melonDS", "Emulator voor Nintendo DS · Arisotura en het melonDS-team", "GPL 3", "GPL-3.0-melonDS"),
        ("PCSX ReARMed", "Emulator voor PlayStation · notaz, het PCSX-team en anderen", "GPL 2 of later", "GPL-2.0-PCSX-ReARMed"),
        ("Mupen64Plus-Next", "Emulator voor Nintendo 64 · het Mupen64Plus-team, Mupen64 en de libretro-bijdragers", "GPL 2 of later", "GPL-2.0-Mupen64Plus-Next"),
        ("GLideN64", "N64-beeld met OpenGL ES in Mupen64Plus-Next · Sergey Lipskiy en anderen", "GPL 2, delen MIT, BSD en LGPL 3", "GPL-2.0-GLideN64"),
        ("Dolphin", "Emulator voor GameCube en Wii, met onder meer curl, mbedtls, zlib-ng, zstd, fmt, glslang, Vulkan Memory Allocator en imgui, en Dolphins eigen systeembestanden (spelaanpassingen en een vervangende DSP-ROM) · het Dolphin-team", "GPL 2 of later; bibliotheken MIT, BSD, zlib, Apache en LGPL", "GPL-2.0-Dolphin"),
        ("iCube", "De snellere Cached Interpreter voor GameCube en Wii zonder JIT, uit dolphin-ios-jitless · het iCube-project van Provenance-Emu", "GPL 2 of later", "GPL-2.0-iCube"),
        ("Droid Sans", "Basis van de GameCube-lettertypes in Dolphin · Google", "Apache 2.0", "Apache-2.0-DroidSans"),
        ("Flycast", "Emulator voor Dreamcast, met onder meer xBRZ, picoTCP, libchdr, libzip, zstd en xxHash · flyinghead en de Flycast-bijdragers", "GPL 2 of later; xBRZ GPL 3; bibliotheken BSD, zlib en Boost", "GPL-2.0-Flycast"),
        ("Azahar", "Emulator voor Nintendo 3DS, met onder meer dynarmic, Boost, Crypto++, glslang, SPIRV-Tools, FAAD2, LibreSSL en SoundTouch · het Azahar-team en de Citra-bijdragers", "GPL 2 of later; bibliotheken MIT, BSD, Boost, Apache, LGPL en GPL", "GPL-2.0-Azahar"),
        ("MoltenVK", "Vulkan op Metal, voor het beeld van de 3DS, GameCube en Wii · The Khronos Group", "Apache 2.0", "Apache-2.0-MoltenVK"),
        ("Vulkan-Headers", "Vulkan-definities voor de koppeling tussen Attic en MoltenVK · The Khronos Group", "Apache 2.0", "Apache-2.0-Vulkan-Headers"),
        ("PPSSPP", "Emulator voor PSP, met vervangende PSP-lettertypes en onder meer FFmpeg, glslang, SPIRV-Cross, Lua, libzip en xBRZ · Henrik Rydgård en de PPSSPP-bijdragers", "GPL 2 of later; FFmpeg LGPL 2.1; xBRZ GPL 3; bibliotheken MIT, BSD en Apache", "GPL-2.0-PPSSPP"),
        ("libretro API", "Koppeling tussen Attic en de emulators, en libretro-common in de kernen · The RetroArch team", "MIT", "MIT-libretro"),
        ("SameBoy", "Super Game Boy in bsnes · Lior Halphon", "MIT", "MIT-SameBoy"),
        ("libco en nall", "Hulpbibliotheken van bsnes · byuu", "ISC", "ISC-libco"),
        ("nes_ntsc", "NTSC-beeldfilter in Nestopia · Shay Green", "LGPL 2.1", "LGPL-2.1-nes_ntsc"),
        ("FreeBIOS", "Vervangende DS-BIOS in melonDS · Gilead Kutnick", "BSD 2-clause", "BSD-FreeBIOS"),
        ("Teakra", "DSi-geluidschip in melonDS · Weiyi Wang", "MIT", "MIT-Teakra"),
        ("FatFs", "Bestandssysteem in melonDS · ChaN", "FatFs-licentie (BSD-stijl)", "BSD-FatFs"),
        ("tiny-AES-c", "Versleuteling in melonDS · kokke en anderen", "Unlicense", "Unlicense-tiny-AES-c"),
        ("xxHash", "Hashfunctie in melonDS en GLideN64 · Yann Collet", "BSD 2-clause", "BSD-xxHash"),
        ("SHA-1 in C", "Hashfunctie in melonDS · Steve Reid", "Publiek domein", "PublicDomain-SHA-1"),
        ("libchdr", "CHD-schijfbestanden in PCSX ReARMed · Romain Tisserand en anderen", "BSD 3-clause", "BSD-libchdr"),
        ("Zstandard", "Decompressie in libchdr · Meta Platforms", "BSD of GPL 2", "BSD-zstd"),
        ("miniz", "Deflate in libchdr · Rich Geldreich en anderen", "MIT", "MIT-miniz"),
        ("LZMA SDK", "Uitpakken van .7z, en LZMA in libchdr · Igor Pavlov", "Publiek domein", "PublicDomain-LZMA-SDK"),
        ("inih", "Instellingenbestanden in mGBA · Ben Hoyt", "BSD 3-clause", "BSD-inih"),
        ("libpng", "PNG-bestanden in GLideN64 · Glenn Randers-Pehrson en anderen", "libpng-licentie", "Libpng"),
        ("MD5", "Spelherkenning in Mupen64Plus-Next · L. Peter Deutsch", "zlib-licentie", "Zlib-MD5"),
        ("libretro-database", "Titels, jaartallen, regio's en spelcodes uit de No-Intro-, Redump- en GameTDB-lijsten, door Attic bewerkt tot een kleinere database in de app (GameDB.sqlite, ook CC BY-SA 4.0) · The libretro team en bijdragers, github.com/libretro/libretro-database", "CC BY-SA 4.0", "CC-BY-SA-4.0-libretro-database"),
        ("Bricolage Grotesque", "Lettertype voor koppen", "SIL Open Font License 1.1", "OFL-BricolageGrotesque"),
        ("Inter", "Lettertype voor tekst", "SIL Open Font License 1.1", "OFL-Inter"),
        ("JetBrains Mono", "Lettertype voor bestandsnamen en codes", "SIL Open Font License 1.1", "OFL-JetBrainsMono"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(title: "Emulators en licenties",
                            subtitle: "Attic is vrije software onder de GPL 3 en gebouwd op open-source werk van anderen. Tik op een onderdeel voor de licentietekst. De app bevat geen spellen en geen BIOS of firmware van Nintendo, Sony of Sega: waar dat nodig is, gebruiken de emulators hun eigen vervangingen.") {
                    dismiss()
                }
                RowGroup(background: Palette.raised) {
                    ForEach(components, id: \.name) { component in
                        Button {
                            shown = shown == component.file ? nil : component.file
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(component.name).font(.text(15, weight: 600)).foregroundStyle(Palette.text)
                                    Spacer()
                                    Text(component.license).font(.text(12)).foregroundStyle(Palette.muted)
                                }
                                Text(component.role).font(.text(12)).foregroundStyle(Palette.muted).multilineTextAlignment(.leading)
                                if shown == component.file, let text = licenseText(component.file) {
                                    Text(text)
                                        .font(.mono(10))
                                        .foregroundStyle(Palette.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, 4)
                                }
                            }
                            .padding(16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
    }

    private func licenseText(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
