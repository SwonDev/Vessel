import Foundation

/// Lee únicamente las decisiones que Steam exige durante un intento nuevo de lanzamiento.
enum SteamGameActionLog {
    /// Confirma que una espera de Steam persiste durante varios sondeos. El cliente escribe primero
    /// `waiting for user response` y, para avisos informativos ya vistos, escribe `continues` hasta
    /// un segundo después. Reaccionar a la primera línea mata un lanzamiento que ya estaba avanzando.
    struct SustainedWaitingTask {
        private var task: String?
        private var consecutiveSamples = 0

        mutating func observe(
            _ candidate: String?,
            requiredConsecutiveSamples: Int
        ) -> String? {
            guard let candidate, !candidate.isEmpty else {
                task = nil
                consecutiveSamples = 0
                return nil
            }
            if task?.caseInsensitiveCompare(candidate) == .orderedSame {
                consecutiveSamples += 1
            } else {
                task = candidate
                consecutiveSamples = 1
            }
            return consecutiveSamples >= max(1, requiredConsecutiveSamples)
                ? candidate
                : nil
        }
    }

    static func waitingTask(
        in current: Data,
        after baseline: Data,
        appId: String
    ) -> String? {
        guard !appId.isEmpty, appId.allSatisfy(\.isNumber) else { return nil }
        let text = SteamAuthorizationLog.delta(in: current, after: baseline)
        let escapedAppID = NSRegularExpression.escapedPattern(for: appId)
        let linePattern = #"(?i)GameAction[ \t]+\[AppID[ \t]+"#
            + escapedAppID
            + #"(?=[,\]])[^\r\n]*"#
        guard let lineExpression = try? NSRegularExpression(pattern: linePattern),
              let waitingExpression = try? NSRegularExpression(
                pattern: #"(?i)waiting for user response to[ \t]+([A-Za-z0-9_]+)"#
              ),
              let actionExpression = try? NSRegularExpression(
                pattern: #"(?i)ActionID[ \t]+([^,\]]+)"#
              ) else { return nil }

        var currentActionID: String?
        var pendingTask: String?
        for match in lineExpression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) {
            guard let lineRange = Range(match.range, in: text) else { continue }
            let line = String(text[lineRange])
            let wholeLineRange = NSRange(line.startIndex..., in: line)
            let actionID = actionExpression.firstMatch(in: line, range: wholeLineRange)
                .flatMap { Range($0.range(at: 1), in: line) }
                .map { String(line[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? "legacy"

            // Un ActionID posterior reemplaza cualquier espera abandonada de un intento anterior.
            if currentActionID != actionID {
                currentActionID = actionID
                pendingTask = nil
            }

            if let waiting = waitingExpression.firstMatch(in: line, range: wholeLineRange),
               let taskRange = Range(waiting.range(at: 1), in: line) {
                pendingTask = String(line[taskRange])
                continue
            }

            guard pendingTask != nil else { continue }
            let lowered = line.lowercased()
            if lowered.contains("continues with user response")
                || lowered.contains("changed task to")
                || lowered.contains("cancel") {
                pendingTask = nil
            }
        }
        return pendingTask
    }
}
