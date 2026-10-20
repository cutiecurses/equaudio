import Foundation

/// Every location EquAudio writes to. uninstall.sh removes exactly these (except recordings).
public enum AppPaths {
    public static let bundleIdentifier = "com.equaudio.EquAudio"

    /// Overrides the support directory (tests, self-test). Set before first use.
    nonisolated(unsafe) public static var supportDirectoryOverride: URL?

    /// ~/Library/Application Support/EquAudio
    public static var supportDirectory: URL {
        if let o = supportDirectoryOverride { return o }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("EquAudio", isDirectory: true)
    }

    /// User presets (one JSON file per preset).
    public static var presetsDirectory: URL { supportDirectory.appendingPathComponent("Presets", isDirectory: true) }

    /// Current settings (DSP values, device choice, recording options).
    public static var settingsFile: URL { supportDirectory.appendingPathComponent("Settings.json") }

    /// ~/Library/Logs/EquAudio
    public static var logsDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library.appendingPathComponent("Logs/EquAudio", isDirectory: true)
    }

    public static var logFile: URL { logsDirectory.appendingPathComponent("EquAudio.log") }

    /// Default recordings folder: ~/Music/EquAudio Recordings (user data; never removed by uninstall).
    public static var defaultRecordingsDirectory: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        return music.appendingPathComponent("EquAudio Recordings", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
