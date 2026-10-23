import Foundation

/// A tiny thread-safe logger. Notification content is deliberately not logged.
enum AppLogger {
    private static let lock = NSLock()
    private static let logURL: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("NotifyBridge.log")
    }()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func info(_ message: String) {
        write("INFO", message)
    }

    static func error(_ message: String) {
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
        print(line, terminator: "")
        lock.lock()
        defer { lock.unlock() }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attributes[.size] as? NSNumber,
           size.intValue > 2 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: logURL)
        }

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Logging must never crash the receiver.
        }
    }
}
