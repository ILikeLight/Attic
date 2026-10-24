import SwiftUI

struct SystemsView: View {
    @Environment(Library.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.accent) private var accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "Attic")
                    ScreenTitle(text: "Systemen")
                    Text("\(GameSystem.allCases.count) systemen in één app, elk met een eigen open-source emulator. Tik op een systeem om de spellen ervan te zien.")
                        .font(.text(14))
                        .lineSpacing(3)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(GameSystem.Group.allCases, id: \.self) { group in
                    TitledSection(title: group.rawValue) {
                        RowGroup {
                            ForEach(GameSystem.allCases.filter { $0.group == group }) { system in
                                row(system)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }

    private func row(_ system: GameSystem) -> some View {
        let count = library.count(of: system)
        return Button {
            if count > 0 {
                router.showLibrary(filter: system)
            } else {
                toasts.show("Nog geen spellen voor \(system.name)")
            }
        } label: {
            HStack(spacing: 12) {
                Text(system.shortName)
                    .font(.mono(11, weight: 600))
                    .foregroundStyle(Palette.text)
                    .frame(width: 44, height: 44)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(system.name).font(.text(15, weight: 600)).foregroundStyle(Palette.text)
                        Text(system.availability)
                            .font(.text(10, weight: 700))
                            .foregroundStyle(system.isPlayable ? Palette.ink : Palette.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(system.isPlayable ? accent : Palette.raised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Text(system.coreName).font(.text(12)).foregroundStyle(Palette.muted)
                    Text(system.formatList).font(.mono(11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                Text(count == 0 ? "Geen" : (count == 1 ? "1 spel" : "\(count) spellen"))
                    .font(.text(13))
                    .foregroundStyle(count > 0 ? Palette.text : Palette.muted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}
