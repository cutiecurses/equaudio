import Foundation

/// Everything EquAudio remembers between launches.
///
/// Decoding is tolerant: missing keys take their default, invalid values fall back to the default
/// (or are clamped, for `bufferFrames`), unknown keys are ignored. A newer app can therefore add
/// keys without breaking older settings files, and a hand-edited file never prevents launch.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// IO buffer sizes offered in the UI (powers of two).
    public static let bufferFrameOptions = [64, 128, 256, 512, 1024, 2048, 4096]
    public static let defaultBufferFrames = 512

    /// Format version of the file this was read from; always written as `currentVersion`.
    public var version = AppSettings.currentVersion
    /// The current sound (may differ from the selected preset after edits).
    public var dsp = DSPSettings.defaults
    /// Preset the current sound started from; nil when none is selected.
    public var selectedPresetID: UUID? = FactoryPresets.flat.id
    /// Master on/off: whether EquAudio routes and processes system audio at all.
    public var processingEnabled = true
    /// A/B bypass of the processing chain while routing stays active.
    public var bypass = false
    public var output: OutputSelection = .systemDefault
    /// Optional second device (e.g. a loopback device) that receives a copy of the processed signal.
    public var mirrorDeviceUID: String?
    /// IO buffer size in frames: a power of two in 64 ... 4096 (always valid; see `validatedBufferFrames`).
    public var bufferFrames = AppSettings.defaultBufferFrames {
        didSet { bufferFrames = Self.validatedBufferFrames(bufferFrames) }
    }
    public var recording = RecordingSettings()
    public var launchAtLogin = false
    public var showMenuBarIcon = true

    public init() {}

    /// The nearest power of two (in octaves) within 64 ... 4096.
    public static func validatedBufferFrames(_ frames: Int) -> Int {
        let clamped = min(max(frames, bufferFrameOptions[0]), bufferFrameOptions[bufferFrameOptions.count - 1])
        let exponent = (log2(Double(clamped))).rounded()
        return Int(exp2(exponent))
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version, dsp, selectedPresetID, processingEnabled, bypass, output, mirrorDeviceUID, bufferFrames,
             recording, launchAtLogin, showMenuBarIcon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let value = try? c.decode(Int.self, forKey: .version), value >= 1 { version = value }
        if let value = try? c.decode(DSPSettings.self, forKey: .dsp) { dsp = value }
        if c.contains(.selectedPresetID) {
            if (try? c.decodeNil(forKey: .selectedPresetID)) == true {
                selectedPresetID = nil
            } else if let value = try? c.decode(UUID.self, forKey: .selectedPresetID) {
                selectedPresetID = value
            }
        }
        if let value = try? c.decode(Bool.self, forKey: .processingEnabled) { processingEnabled = value }
        if let value = try? c.decode(Bool.self, forKey: .bypass) { bypass = value }
        if let value = try? c.decode(OutputSelection.self, forKey: .output) { output = value }
        if let value = try? c.decode(String.self, forKey: .mirrorDeviceUID) {
            mirrorDeviceUID = value.isEmpty ? nil : value
        }
        if let value = try? c.decode(Int.self, forKey: .bufferFrames) {
            bufferFrames = Self.validatedBufferFrames(value)
        } else if let value = try? c.decode(Double.self, forKey: .bufferFrames), value.isFinite {
            bufferFrames = Self.validatedBufferFrames(Int(min(max(value, 0), 1_000_000)))
        }
        if let value = try? c.decode(RecordingSettings.self, forKey: .recording) { recording = value }
        if let value = try? c.decode(Bool.self, forKey: .launchAtLogin) { launchAtLogin = value }
        if let value = try? c.decode(Bool.self, forKey: .showMenuBarIcon) { showMenuBarIcon = value }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(dsp, forKey: .dsp)
        try c.encode(selectedPresetID, forKey: .selectedPresetID) // null when nothing is selected
        try c.encode(processingEnabled, forKey: .processingEnabled)
        try c.encode(bypass, forKey: .bypass)
        try c.encode(output, forKey: .output)
        try c.encodeIfPresent(mirrorDeviceUID, forKey: .mirrorDeviceUID)
        try c.encode(bufferFrames, forKey: .bufferFrames)
        try c.encode(recording, forKey: .recording)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
    }
}

/// Reads and writes `AppSettings` as JSON.
///
/// Thread-safe. All writes run on one private serial queue, so a debounced save can never land after
/// (and overwrite) a newer explicit `save`. Writes are atomic: a crash leaves the old or the new file.
public final class SettingsStore: @unchecked Sendable {
    /// Delay between the last `scheduleSave` and the write.
    public static let debounceInterval: TimeInterval = 0.5

    public let fileURL: URL

    private let log: LogStore
    private let queue = DispatchQueue(label: "com.equaudio.settings", qos: .utility)
    // Guarded by `queue`.
    private var pending: AppSettings?
    private var pendingWork: DispatchWorkItem?

    public init(fileURL: URL = AppPaths.settingsFile, log: LogStore = .shared) {
        self.fileURL = fileURL
        self.log = log
    }

    deinit {
        // Only reachable when no work item holds `self`, so touching `pending` directly is safe.
        pendingWork?.cancel()
        if let pending { try? write(pending) }
    }

    /// Loads the settings; defaults if there is no file yet. A file that cannot be parsed is moved
    /// aside as `<name>.corrupt-<yyyyMMdd-HHmmss>.json` (kept for inspection) and defaults are returned.
    /// A pending debounced save is written first, so the result is always the newest state.
    public func load() -> AppSettings {
        queue.sync {
            writePendingNow()
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                log.info("Settings", "No settings file yet; using defaults")
                return AppSettings()
            } catch {
                log.error("Settings", "Could not read \(fileURL.path): \(PresetStore.describe(error)); using defaults")
                return AppSettings()
            }
            do {
                return try JSONDecoder().decode(AppSettings.self, from: data)
            } catch {
                let backup = moveAsideCorruptFile()
                log.warning("Settings", "Settings file is damaged (\(PresetStore.describe(error))); using defaults"
                            + (backup.map { ". The damaged file was kept as \($0.lastPathComponent)" } ?? ""))
                return AppSettings()
            }
        }
    }

    /// Writes immediately (atomically) and cancels any pending debounced save.
    public func save(_ settings: AppSettings) throws {
        try queue.sync {
            pendingWork?.cancel()
            pendingWork = nil
            pending = nil
            try write(settings)
        }
    }

    /// Saves after `debounceInterval` without further calls; each call replaces the pending settings
    /// and restarts the delay. Errors are logged. Callable from any thread.
    public func scheduleSave(_ settings: AppSettings) {
        queue.async {
            self.pending = settings
            self.pendingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.writePendingNow() }
            self.pendingWork = work
            self.queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
        }
    }

    /// Writes a pending debounced save now (call on quit). Returns when it is on disk.
    public func flush() {
        queue.sync { writePendingNow() }
    }

    /// True while a debounced save is waiting.
    public var hasPendingSave: Bool { queue.sync { pending != nil } }

    // MARK: Private (on `queue`)

    private func writePendingNow() {
        pendingWork?.cancel()
        pendingWork = nil
        guard let settings = pending else { return }
        pending = nil
        do {
            try write(settings)
        } catch {
            log.error("Settings", "Could not save settings: \(PresetStore.describe(error))")
        }
    }

    private func write(_ settings: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
        try data.write(to: fileURL, options: .atomic)
    }

    /// Renames the unreadable settings file so it is neither lost nor read again; returns the new URL.
    private func moveAsideCorruptFile() -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let directory = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "" : ".\(fileURL.pathExtension)"
        var candidate = directory.appendingPathComponent("\(stem).corrupt-\(stamp)\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem).corrupt-\(stamp)-\(number)\(ext)")
            number += 1
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: candidate)
            return candidate
        } catch {
            log.error("Settings", "Could not keep the damaged settings file: \(PresetStore.describe(error))")
            return nil
        }
    }
}
