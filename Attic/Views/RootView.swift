import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(ImportCoordinator.self) private var importer

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            Group {
                switch router.tab {
                case .library: LibraryView()
                case .systems: SystemsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
            .statusBarScrim()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TabBar(selection: $router.tab)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                GameDetailView(gameID: id)
            }
        }
        .externalDisplayAccessory()
        .overlay {
            ToastOverlay(edge: .bottom)
                .padding(.bottom, router.path.isEmpty ? 76 : 24)
        }
        .sheet(isPresented: $router.showImport, onDismiss: importer.dismissFinished) {
            ImportSheet()
                .presentationDetents([.large])
                .atticSheet()
        }
        .fullScreenCover(item: $router.playing, onDismiss: showImportAfterPlaying) { request in
            PlayerView(request: request)
        }
        .fullScreenCover(isPresented: $router.showController) {
            ControllerView()
        }
    }

    private func showImportAfterPlaying() {
        guard router.importAfterPlaying else { return }
        router.importAfterPlaying = false
        router.showImport = true
    }
}

private struct TabBar: View {
    @Environment(\.accent) private var accent
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 0) {
            item(.library, title: "Bibliotheek", systemImage: "square.grid.2x2")
            item(.systems, title: "Systemen", systemImage: "cpu")
            item(.settings, title: "Instellingen", systemImage: "slider.horizontal.3")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(height: 54, alignment: .top)
        .background(Palette.tabBar.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.tabBarLine).frame(height: 1)
        }
    }

    private func item(_ tab: AppTab, title: String, systemImage: String) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 21, weight: .medium))
                Text(title).font(.text(11, weight: 600))
            }
            .foregroundStyle(isSelected ? accent : Palette.tabInactive)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
