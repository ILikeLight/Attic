import GameController
import SwiftUI

/// Settings › Controllers: the Bluetooth controllers that are connected, and per system which
/// console button each controller button presses (`ControllerMapping`).
struct ControllersView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var connected: [GCController] = GameControllerInput.connected
    /// The way of playing shown; at first that of the game played last.
    @State private var chosenScheme: ControlScheme?

    private var scheme: ControlScheme {
        chosenScheme ?? library.continueGame.map(ControlScheme.of) ?? ControlScheme.all[0]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SheetHeader(title: "Controllers",
                            subtitle: "Koppel een controller via Instellingen › Bluetooth van je iPhone. De eerste controller speelt speler 1; in spellen voor meer spelers wordt elke volgende speler 2, 3 en 4.") {
                    dismiss()
                }
                connectedSection
                mappingSection
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            connected = GameControllerInput.connected
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            connected = GameControllerInput.connected
        }
    }

    private var connectedSection: some View {
        TitledSection(title: "Verbonden") {
            RowGroup(background: Palette.raised) {
                if connected.isEmpty {
                    Text("Geen controller verbonden")
                        .font(.text(15))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
                ForEach(Array(connected.enumerated()), id: \.offset) { index, controller in
                    HStack(spacing: 12) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(controller.vendorName ?? "Controller").font(.text(15, weight: 600)).foregroundStyle(Palette.text)
                            Text(detail(controller, index: index)).font(.text(12)).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var mappingSection: some View {
        let mapping = settings.mapping(for: scheme)
        return TitledSection(title: "Knoppen") {
            Text("Kies per systeem wat elke knop van je controller doet. Het geldt voor alle controllers en vanaf het volgende spel dat je start.")
                .font(.text(13))
                .lineSpacing(2)
                .foregroundStyle(Palette.muted)
            RowGroup(background: Palette.raised) {
                HStack(spacing: 12) {
                    Text("Systeem").font(.text(15)).foregroundStyle(Palette.text)
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(ControlScheme.all) { choice in
                            Button(choice.title) { chosenScheme = choice }
                        }
                    } label: {
                        choiceLabel(scheme.title, color: Palette.text)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                ForEach(ControllerButton.allCases) { button in
                    let target = mapping.target(of: button)
                    let changed = mapping.changes[button] != nil
                    HStack(spacing: 12) {
                        Text(button.title).font(.text(15)).foregroundStyle(Palette.text)
                        Spacer(minLength: 0)
                        Menu {
                            ForEach(scheme.targets, id: \.button) { choice in
                                Button {
                                    settings.setTarget(choice.button, for: button, in: scheme)
                                } label: {
                                    if choice.button == target {
                                        Label(choice.title, systemImage: "checkmark")
                                    } else {
                                        Text(choice.title)
                                    }
                                }
                            }
                            Button {
                                settings.setTarget(nil, for: button, in: scheme)
                            } label: {
                                if target == nil {
                                    Label("Niets", systemImage: "checkmark")
                                } else {
                                    Text("Niets")
                                }
                            }
                        } label: {
                            choiceLabel(scheme.title(of: target), color: changed ? accent : Palette.textSecondary)
                        }
                        .accessibilityLabel("\(button.title): \(scheme.title(of: target))")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            SecondaryButton(title: "Standaard herstellen") {
                settings.resetMapping(for: scheme)
            }
            .disabled(mapping.changes.isEmpty)
            .opacity(mapping.changes.isEmpty ? 0.5 : 1)
            .padding(.top, 4)
        }
    }

    private func choiceLabel(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.text(14, weight: 600))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func detail(_ controller: GCController, index: Int) -> String {
        var parts = [index == 0 ? "Speler 1" : "Speler \(index + 1) in spellen voor meer spelers"]
        if let battery = controller.battery, battery.batteryState != .unknown {
            parts.append("batterij \(Int((battery.batteryLevel * 100).rounded()))%")
        }
        if controller.haptics != nil {
            parts.append("kan trillen")
        }
        return parts.joined(separator: " · ")
    }
}
