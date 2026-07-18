import Foundation

enum LibraryTransferPhase: Equatable {
    case queued
    case running
    case pausing
    case paused
    case cancelling
    case failed
}

/// Estado presentable de una operación de biblioteca en curso. Se construye únicamente con los
/// datos que ya exponen las tiendas; no conserva tareas, rutas ni credenciales.
struct LibraryTransferItem: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    let fractionCompleted: Double?
    let phase: LibraryTransferPhase
    let canPause: Bool
    let canCancel: Bool
    let canPrioritize: Bool
    let canRetry: Bool

    init(
        id: String,
        title: String,
        message: String,
        fractionCompleted: Double?,
        phase: LibraryTransferPhase = .running,
        canPause: Bool = false,
        canCancel: Bool = false,
        canPrioritize: Bool = false,
        canRetry: Bool = false
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.fractionCompleted = fractionCompleted
        self.phase = phase
        self.canPause = canPause
        self.canCancel = canCancel
        self.canPrioritize = canPrioritize
        self.canRetry = canRetry
    }
}

enum LibraryTransferSnapshot {
    static func items(
        games: [StoreGame],
        activeIDs: Set<String>,
        progressFor: (String) -> String?,
        percentFor: (String) -> Double?,
        titleFor: (String) -> String? = { _ in nil },
        phaseFor: (String) -> LibraryTransferPhase = { _ in .running },
        positionFor: (String) -> Int? = { _ in nil },
        canPauseFor: (String) -> Bool = { _ in false },
        canCancelFor: (String) -> Bool = { _ in false },
        canPrioritizeFor: (String) -> Bool = { _ in false },
        canRetryFor: (String) -> Bool = { _ in false }
    ) -> [LibraryTransferItem] {
        games
            .filter { activeIDs.contains($0.id) }
            .map { game in
                LibraryTransferItem(
                    id: game.id,
                    title: titleFor(game.id) ?? game.title,
                    message: normalizedMessage(progressFor(game.id)),
                    fractionCompleted: percentFor(game.id).map { min(1, max(0, $0)) },
                    phase: phaseFor(game.id),
                    canPause: canPauseFor(game.id),
                    canCancel: canCancelFor(game.id),
                    canPrioritize: canPrioritizeFor(game.id),
                    canRetry: canRetryFor(game.id)
                )
            }
            .sorted {
                if let lhsPosition = positionFor($0.id), let rhsPosition = positionFor($1.id),
                   lhsPosition != rhsPosition {
                    return lhsPosition < rhsPosition
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    /// El progreso conjunto solo se muestra cuando todas las operaciones tienen una fracción
    /// conocida. Mezclar porcentajes reales con fases indeterminadas ofrecería una cifra engañosa.
    static func overallProgress(for items: [LibraryTransferItem]) -> Double? {
        guard !items.isEmpty else { return nil }
        let measurable = items.filter { [.running, .pausing].contains($0.phase) }
        guard !measurable.isEmpty else { return nil }
        let values = measurable.compactMap(\.fractionCompleted)
        guard values.count == measurable.count else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func normalizedMessage(_ message: String?) -> String {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Preparando…" : trimmed
    }
}
