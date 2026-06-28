import Foundation
import os

@MainActor
@Observable
final class LogStore {
    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let message: String
    }

    static let shared = LogStore()

    private(set) var entries: [Entry] = []
    private let logger = Logger(subsystem: "com.swondev.vessel", category: "general")
    private let logFile: URL

    init() {
        // Logs en ~/Library/Logs/Vessel, escribible siempre (incluso con sandbox)
        let logsDir = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Logs/Vessel")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.logFile = logsDir.appendingPathComponent("vessel.log")
    }

    func log(_ message: String, level: Level = .info) {
        let entry = Entry(timestamp: Date(), level: level, message: message)
        entries.append(entry)
        if entries.count > 1000 { entries.removeFirst(entries.count - 1000) }

        let line = "[\(entry.timestamp.formatted(.iso8601))] [\(level.rawValue)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFile)
            }
        }

        switch level {
        case .info: logger.info("\(message)")
        case .warn: logger.warning("\(message)")
        case .error: logger.error("\(message)")
        case .debug: logger.debug("\(message)")
        }
    }

    func clear() {
        entries.removeAll()
    }

    func logFilePath() -> URL { logFile }
}
