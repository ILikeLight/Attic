import SwiftUI

@main
struct AtticApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var library: Library
    @State private var settings: AppSettings
    @State private var router = AppRouter()
    @State private var toasts: ToastCenter
    @State private var saveStates = SaveStateStore()
    @State private var covers = CoverStore()
    @State private var importer: ImportCoordinator
    @State private var watcher: FolderWatcher
    @State private var refresher: MetadataRefresher

    init() {
        let library = Library()
        let settings = AppSettings()
        let toasts = ToastCenter()
        let importer = ImportCoordinator(library: library, settings: settings, toasts: toasts)
        _library = State(initialValue: library)
        _settings = State(initialValue: settings)
        _toasts = State(initialValue: toasts)
        _importer = State(initialValue: importer)
        _watcher = State(initialValue: FolderWatcher(coordinator: importer))
        _refresher = State(initialValue: MetadataRefresher(library: library, settings: settings))
        if CoreBenchmark.isRequested {
            CoreBenchmark.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(settings)
                .environment(router)
                .environment(toasts)
                .environment(saveStates)
                .environment(covers)
                .environment(importer)
                .environment(\.accent, settings.accent.color)
                .tint(settings.accent.color)
                .preferredColorScheme(.dark)
                .onOpenURL(perform: open)
                .onAppear(perform: updateWatcher)
                .onChange(of: settings.watchFolder) { updateWatcher() }
                .onChange(of: settings.fetchCovers) { refresher.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    if settings.watchFolder {
                        watcher.scheduleScan(after: 0.3)
                    }
                    // Also catches covers that could not be fetched while offline.
                    if !CoreBenchmark.isRequested {
                        refresher.refresh()
                    }
                }
                #if DEBUG
                .task { applyTestOrientation() }
                #endif
        }
    }

    #if DEBUG
    /// Launch with `-AtticLandscape` to turn the interface sideways, for checking the
    /// landscape player in the Simulator without rotating it by hand.
    private func applyTestOrientation() {
        guard ProcessInfo.processInfo.arguments.contains("-AtticLandscape"),
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
    }
    #endif

    private func updateWatcher() {
        if settings.watchFolder {
            watcher.start()
        } else {
            watcher.stop()
        }
    }

    /// A file shared to Attic ("Open in Attic") or opened from the Files app.
    private func open(_ url: URL) {
        let inbox = LibraryPaths.shared.documents.appendingPathComponent("Inbox").path
        let ours = url.path.hasPrefix(inbox) || url.path.hasPrefix(LibraryPaths.shared.documents.path)
        importer.enqueue(.init(url: url, securityScoped: !ours, ownsSource: url.path.hasPrefix(inbox)))
        if router.playing != nil {
            // Closing the game now would leave it unsaved and its emulator loaded.
            router.importAfterPlaying = true
            toasts.show("Wordt toegevoegd; je ziet het als je stopt")
        } else {
            router.showImport = true
        }
    }
}
