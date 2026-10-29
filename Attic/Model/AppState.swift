import Foundation
import Observation
import SwiftUI

enum AppTab: Hashable {
    case library, systems, settings
}

/// A request to open the player, optionally from a save state.
struct PlayRequest: Identifiable, Hashable {
    let id = UUID()
    let gameID: UUID
    var saveState: SaveState? = nil
}

/// Navigation and transient UI state shared by all screens.
@MainActor
@Observable
final class AppRouter {
    var tab: AppTab = .library
    var path: [UUID] = []
    var libraryFilter: GameSystem?
    var playing: PlayRequest?
    var showImport = false
    /// A file came in through "Open in Attic" while a game was being played: its import is shown
    /// once the game is stopped, instead of closing the game unsaved.
    var importAfterPlaying = false
    /// A game whose removal was chosen from its context menu, waiting for confirmation.
    var removalRequest: UUID?
    /// This iPhone joins a game on another iPhone as its controller (`ControllerView`).
    var showController = false

    func open(_ game: Game) {
        if path.last != game.id {
            path.append(game.id)
        }
    }

    func play(_ game: Game, from saveState: SaveState? = nil) {
        playing = PlayRequest(gameID: game.id, saveState: saveState)
    }

    func showLibrary(filter: GameSystem?) {
        libraryFilter = filter
        path.removeAll()
        tab = .library
    }
}

/// Short confirmation messages ("Opgeslagen in slot 2").
@MainActor
@Observable
final class ToastCenter {
    private(set) var message: String?
    private(set) var isError = false
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, isError: Bool = false) {
        self.message = message
        self.isError = isError
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self?.message = nil
            }
        }
    }
}

struct ToastOverlay: View {
    @Environment(ToastCenter.self) private var toasts
    var edge: VerticalEdge = .bottom

    var body: some View {
        VStack {
            if edge == .bottom { Spacer() }
            if let message = toasts.message {
                HStack(spacing: 10) {
                    Image(systemName: toasts.isError ? "exclamationmark.circle" : "checkmark")
                        .font(.system(size: 15, weight: .bold))
                    Text(message)
                        .font(.text(14, weight: 600))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Palette.text, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
                .padding(.horizontal, 20)
                .transition(.move(edge: edge == .bottom ? .bottom : .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
            }
            if edge == .top { Spacer() }
        }
        .animation(.spring(duration: 0.3), value: toasts.message)
        .allowsHitTesting(false)
    }
}
