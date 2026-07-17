import Foundation

/// Coincidencia compartida por la búsqueda visible y Apertura rápida. Está pensada para títulos
/// de juegos: ignora diacríticos y puntuación, acepta fragmentos por palabra y abreviaturas.
enum LibraryTitleSearch {
    static func matches(title: String, query: String) -> Bool {
        score(title: title, query: query) != nil
    }

    /// Menor puntuación = coincidencia más precisa.
    static func score(title: String, query: String) -> Int? {
        let normalizedQuery = normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return 0 }

        let normalizedTitle = normalize(title)
        if normalizedTitle == normalizedQuery { return 0 }
        if normalizedTitle.hasPrefix(normalizedQuery) { return 1 }

        let queryTerms = terms(in: normalizedQuery)
        let titleTerms = terms(in: normalizedTitle)
        guard !queryTerms.isEmpty else { return nil }

        if queryTerms.allSatisfy({ queryTerm in
            titleTerms.contains(where: { $0.hasPrefix(queryTerm) })
        }) {
            return 2
        }

        if queryTerms.allSatisfy(normalizedTitle.contains) { return 3 }

        let compactQuery = compact(normalizedQuery)
        let compactTitle = compact(normalizedTitle)
        // En consultas de una o dos letras, unir palabras produciría demasiado ruido ("c b"
        // coincidiría con cualquier frontera entre palabras). Reservamos esa tolerancia para
        // abreviaturas de tres caracteres o más; las siglas cortas siguen cubiertas debajo.
        if compactQuery.count >= 3, compactTitle.contains(compactQuery) { return 4 }

        let acronym = titleTerms.compactMap(\.first).map(String.init).joined()
        if compactQuery.count >= 2, acronym.hasPrefix(compactQuery) { return 5 }

        return nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased(with: .current)
    }

    private static func terms(in value: String) -> [String] {
        value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func compact(_ value: String) -> String {
        String(value.filter { $0.isLetter || $0.isNumber })
    }
}
