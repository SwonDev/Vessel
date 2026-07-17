import Foundation

/// Estado presentable de una operación de biblioteca en curso. Se construye únicamente con los
/// datos que ya exponen las tiendas; no conserva tareas, rutas ni credenciales.
struct LibraryTransferItem: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    let fractionCompleted: Double?
}

enum LibraryTransferSnapshot {
    static func items(
        games: [StoreGame],
        activeIDs: Set<String>,
        progressFor: (String) -> String?,
        percentFor: (String) -> Double?
    ) -> [LibraryTransferItem] {
        games
            .filter { activeIDs.contains($0.id) }
            .map { game in
                LibraryTransferItem(
                    id: game.id,
                    title: game.title,
                    message: normalizedMessage(progressFor(game.id)),
                    fractionCompleted: percentFor(game.id).map { min(1, max(0, $0)) }
                )
            }
            .sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    /// El progreso conjunto solo se muestra cuando todas las operaciones tienen una fracción
    /// conocida. Mezclar porcentajes reales con fases indeterminadas ofrecería una cifra engañosa.
    static func overallProgress(for items: [LibraryTransferItem]) -> Double? {
        guard !items.isEmpty else { return nil }
        let values = items.compactMap(\.fractionCompleted)
        guard values.count == items.count else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func normalizedMessage(_ message: String?) -> String {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Preparando…" : trimmed
    }
}
