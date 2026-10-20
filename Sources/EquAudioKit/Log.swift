import Foundation
import os

public enum LogLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case debug, info, warning, error

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let date: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public var formatted: String {
        "\(LogStore.timestampFormatter.string(from: date)) [\(level.rawValue.uppercased())] \(category): \(message)"
    }
}

/// Application log: unified logging (Console.app, subsystem "com.equaudio.EquAudio"), an in-memory
/// ring for the Diagnostics view, and a rotating text file in ~/Library/Logs/EquAudio.
/// Thread-safe. Never call from the audio thread.
public final class LogStore: @unchecked Sendable {
    public static let shared = LogStore(fileURL: AppPaths.logFile)

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public let fileURL: URL?
    public let capacity: Int
    /// Called on the main queue after each new entry.
    public var onEntry: ((LogEntry) -> Void)? {
        get { lock.withLock { _onEntry } }
        set { lock.withLock { _onEntry = newValue } }
    }

    private let lock = NSLock()
    private var _onEntry: ((LogEntry) -> Void)?
    private var buffer: [LogEntry] = []
    private var nextID: UInt64 = 0
    private var fileHandle: FileHandle?
    private let fileQueue = DispatchQueue(label: "com.equaudio.log.file", qos: .utility)
    private static let maxFileBytes: UInt64 = 2 * 1024 * 1024

    public init(fileURL: URL?, capacity: Int = 2000) {
        self.fileURL = fileURL
        self.capacity = capacity
        if let fileURL { openFile(fileURL) }
    }

    public var entries: [LogEntry] { lock.withLock { buffer } }

    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        let entry: LogEntry = lock.withLock {
            nextID += 1
            let e = LogEntry(id: nextID, date: Date(), level: level, category: category, message: message)
            buffer.append(e)
            if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
            return e
        }
        let logger = Logger(subsystem: "com.equaudio.EquAudio", category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        let line = entry.formatted + "\n"
        fileQueue.async { [weak self] in self?.append(line) }
        if let callback = onEntry { DispatchQueue.main.async { callback(entry) } }
    }

    public func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    public func info(_ category: String, _ message: String) { log(.info, category, message) }
    public func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category, message) }

    public func exportText(minimumLevel: LogLevel = .debug) -> String {
        entries.filter { $0.level >= minimumLevel }.map(\.formatted).joined(separator: "\n")
    }

    public func clear() { lock.withLock { buffer.removeAll() } }

    /// Waits until queued file writes are on disk (tests, shutdown).
    public func flush() { fileQueue.sync { try? fileHandle?.synchronize() } }

    private func openFile(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > Self.maxFileBytes {
            let old = url.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        try? fileHandle?.write(contentsOf: data)
    }
}
