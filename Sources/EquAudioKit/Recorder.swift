import AudioToolbox
import Darwin
import Foundation

// MARK: - Formats and options

/// Recording file formats. All are lossless, and each was verified to be writable through
/// ExtAudioFile on macOS 26 / Apple silicon, including sample-rate conversion from the float32 client.
public enum RecordingFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case wav16, wav24, wav32Float, alac, flac

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wav16: "WAV 16-bit"
        case .wav24: "WAV 24-bit"
        case .wav32Float: "WAV 32-bit float"
        case .alac: "Apple Lossless (.m4a)"
        case .flac: "FLAC"
        }
    }

    public var fileExtension: String {
        switch self {
        case .wav16, .wav24, .wav32Float: "wav"
        case .alac: "m4a"
        case .flac: "flac"
        }
    }

    public var fileType: AudioFileTypeID {
        switch self {
        case .wav16, .wav24, .wav32Float: kAudioFileWAVEType
        case .alac: kAudioFileM4AType
        case .flac: kAudioFileFLACType
        }
    }

    /// Bits per sample in the file (the lossless codecs encode 24-bit source data).
    public var bitDepth: Int {
        switch self {
        case .wav16: 16
        case .wav24, .alac, .flac: 24
        case .wav32Float: 32
        }
    }

    public var isFloat: Bool { self == .wav32Float }

    /// Uncompressed RIFF WAVE: limited to 4 GiB per file, so long recordings are split into parts.
    public var isWAV: Bool { fileType == kAudioFileWAVEType }

    /// The file's data format at `sampleRate`.
    public func fileFormat(sampleRate: Double, channels: UInt32 = 2) -> AudioStreamBasicDescription {
        switch self {
        case .wav16, .wav24, .wav32Float:
            let bytes = UInt32(bitDepth / 8)
            let flags = isFloat ? kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked
                                : kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                mBytesPerPacket: bytes * channels, mFramesPerPacket: 1, mBytesPerFrame: bytes * channels,
                mChannelsPerFrame: channels, mBitsPerChannel: UInt32(bitDepth), mReserved: 0)
        case .alac, .flac:
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: self == .alac ? kAudioFormatAppleLossless : kAudioFormatFLAC,
                mFormatFlags: UInt32(kAppleLosslessFormatFlag_24BitSourceData), mBytesPerPacket: 0,
                mFramesPerPacket: self == .alac ? 4096 : 0, mBytesPerFrame: 0, mChannelsPerFrame: channels,
                mBitsPerChannel: 0, mReserved: 0)
        }
    }
}

/// Which signal a recording captures.
public enum RecordingSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case processed, raw, both

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .processed: "Processed output"
        case .raw: "Raw system audio (before processing)"
        case .both: "Both (two files)"
        }
    }

    /// The streams written, one file each (processed first).
    public var streams: [RecordingStream] {
        switch self {
        case .processed: [.processed]
        case .raw: [.raw]
        case .both: [.processed, .raw]
        }
    }
}

/// One recorded signal: the engine output, or the tap input before any processing.
public enum RecordingStream: String, Codable, CaseIterable, Sendable {
    case processed, raw

    /// Value of the `{source}` file-name token.
    public var displayName: String { self == .processed ? "Processed" : "Raw" }

    /// Appended to file names when one recording writes both streams.
    public var fileSuffix: String { self == .processed ? " (processed)" : " (raw)" }

    /// First channel of the stream in the engine's 4-channel recording frame (rawL, rawR, procL, procR).
    var ringChannelOffset: Int { self == .processed ? 2 : 0 }
}

/// Recording options (persisted in `AppSettings`).
///
/// File names come from `filenameTemplate` with the tokens `{date}` (2026-10-19), `{time}`
/// (14.05.09), `{preset}` (preset name, "Custom" when none) and `{source}` (Processed/Raw); they are
/// sanitised for every common file system. Existing files are never overwritten: " 2", " 3", ... is
/// appended instead. A `.both` recording adds " (processed)" / " (raw)" unless the template already
/// contains `{source}`.
public struct RecordingSettings: Codable, Hashable, Sendable {
    public static let defaultFilenameTemplate = "EquAudio {date} {time}"
    /// File sample rates offered in the UI; nil means the device rate.
    public static let offeredSampleRates = [44100, 48000, 88200, 96000]
    public static let templateTokens = ["{date}", "{time}", "{preset}", "{source}"]
    /// Used when a template expands to nothing usable.
    public static let fallbackFileName = "EquAudio Recording"

    /// Folder for new recordings; `~` is expanded and an empty path means the default folder.
    public var directoryPath: String
    public var filenameTemplate: String
    public var format: RecordingFormat
    /// File sample rate in Hz; nil records at the device rate (no conversion).
    public var sampleRate: Int?
    public var source: RecordingSource

    public init(directoryPath: String = AppPaths.defaultRecordingsDirectory.path,
                filenameTemplate: String = RecordingSettings.defaultFilenameTemplate,
                format: RecordingFormat = .wav24, sampleRate: Int? = nil, source: RecordingSource = .processed) {
        self.directoryPath = directoryPath
        self.filenameTemplate = filenameTemplate
        self.format = format
        self.sampleRate = sampleRate
        self.source = source
    }

    /// The resolved recordings folder.
    public var directoryURL: URL {
        let path = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return AppPaths.defaultRecordingsDirectory }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// Sample rate of the files for a device running at `deviceSampleRate`.
    public func fileSampleRate(deviceSampleRate: Double) -> Double {
        sampleRate.map(Double.init) ?? deviceSampleRate
    }

    /// The template expanded for one stream and sanitised (no extension, uniqueness number or suffix).
    public func expandedFileName(date: Date, presetName: String?, stream: RecordingStream) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH.mm.ss"
        let preset = presetName.flatMap(Preset.normalizedName) ?? "Custom"
        var name = filenameTemplate
        for (token, value) in [("{date}", dateFormatter.string(from: date)), ("{time}", timeFormatter.string(from: date)),
                               ("{preset}", preset), ("{source}", stream.displayName)] {
            name = name.replacingOccurrences(of: token, with: value, options: .caseInsensitive)
        }
        return Self.sanitizedFileName(name)
    }

    /// The files a recording started at `date` would create, one per stream (processed first),
    /// none of which exists yet.
    public func plannedFileURLs(date: Date = Date(), presetName: String?) -> [URL] {
        planFiles(date: date, presetName: presetName).urls
    }

    /// File-name stems (template + uniqueness number) and URLs, one per stream.
    func planFiles(date: Date, presetName: String?) -> (stems: [String], suffixes: [String], urls: [URL]) {
        let streams = source.streams
        let names = streams.map { expandedFileName(date: date, presetName: presetName, stream: $0) }
        let needsSuffix = streams.count > 1 && !filenameTemplate.localizedCaseInsensitiveContains("{source}")
        let suffixes = streams.map { needsSuffix ? $0.fileSuffix : "" }
        let (stems, urls) = Self.uniqueFileURLs(in: directoryURL, stems: names, suffixes: suffixes,
                                                fileExtension: format.fileExtension)
        return (stems, suffixes, urls)
    }

    /// `stems[i] + [" N"] + suffixes[i] + "." + ext` with the smallest N (none, 2, 3, ...) for which
    /// none of the files exists, so that the files of one recording keep matching names.
    static func uniqueFileURLs(in directory: URL, stems: [String], suffixes: [String],
                               fileExtension: String) -> (stems: [String], urls: [URL]) {
        var number = 1
        while true {
            let numbered = stems.map { number == 1 ? $0 : "\($0) \(number)" }
            let urls = zip(numbered, suffixes).map {
                directory.appendingPathComponent("\($0)\($1)").appendingPathExtension(fileExtension)
            }
            if !urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                return (numbered, urls)
            }
            number += 1
        }
    }

    /// A safe file name: path separators and characters reserved on FAT/exFAT/SMB (`/ \ : * ? " < > |`)
    /// become "-", control characters and whitespace runs one space, leading dots are removed, and the
    /// result is limited to 200 UTF-8 bytes.
    public static func sanitizedFileName(_ raw: String) -> String {
        let reserved = Set("/\\:*?\"<>|")
        var cleaned = ""
        var pendingSpace = false
        for character in raw {
            if character.isWhitespace || character.isNewline || character.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) {
                pendingSpace = !cleaned.isEmpty
                continue
            }
            if pendingSpace { cleaned.append(" "); pendingSpace = false }
            cleaned.append(reserved.contains(character) ? "-" : character)
        }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        var limited = ""
        var bytes = 0
        for character in cleaned {
            bytes += character.utf8.count
            if bytes > 200 { break }
            limited.append(character)
        }
        let result = limited.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? fallbackFileName : result
    }

    // MARK: Codable (tolerant)

    private enum CodingKeys: String, CodingKey { case directoryPath, filenameTemplate, format, sampleRate, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let value = try? c.decode(String.self, forKey: .directoryPath),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            directoryPath = value
        }
        if let value = try? c.decode(String.self, forKey: .filenameTemplate),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filenameTemplate = value
        }
        if let value = try? c.decode(String.self, forKey: .format), let format = RecordingFormat(rawValue: value) {
            self.format = format
        }
        if let value = try? c.decode(Int.self, forKey: .sampleRate), Self.offeredSampleRates.contains(value) {
            sampleRate = value
        }
        if let value = try? c.decode(String.self, forKey: .source), let source = RecordingSource(rawValue: value) {
            self.source = source
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(directoryPath, forKey: .directoryPath)
        try c.encode(filenameTemplate, forKey: .filenameTemplate)
        try c.encode(format, forKey: .format)
        try c.encode(sampleRate, forKey: .sampleRate) // null = device rate
        try c.encode(source, forKey: .source)
    }
}

// MARK: - Status and errors

/// Snapshot of the recorder. After a recording ends it keeps describing that recording (files,
/// duration, ...) with `isRecording == false` until the next start.
public struct RecordingStatus: Equatable, Sendable {
    public var isRecording = false
    /// Every file of the recording in creation order (processed before raw; WAV parts appended).
    public var files: [URL] = []
    public var startedAt: Date?
    /// Recorded time: frames taken from the engine / device sample rate.
    public var duration: TimeInterval = 0
    /// Total size of `files`, refreshed at most every 0.5 s while recording.
    public var bytesOnDisk: Int64 = 0
    /// Frames the engine had to drop because the recorder did not keep up.
    public var droppedFrames: UInt64 = 0
    /// Highest sample peak recorded so far in dBFS (before clamping, so overs read above 0).
    public var peakDBFS: Float = -120
    /// Samples beyond full scale that were clamped to +-1 for an integer format.
    public var clippedSamples: UInt64 = 0
    public var deviceSampleRate: Double = 0
    public var fileSampleRate: Double = 0
    public var format: RecordingFormat = .wav24
    public var source: RecordingSource = .processed
    /// Why the last recording failed to start or stopped on its own; nil after a clean start.
    public var lastError: String?

    public init() {}
}

public enum RecorderError: LocalizedError, Equatable {
    case alreadyRecording
    case invalidSampleRate(Double)
    case directoryUnavailable(path: String, reason: String)
    case directoryNotWritable(path: String)
    case insufficientDiskSpace(path: String, availableBytes: Int64)
    case audioFile(operation: String, path: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already running."
        case let .invalidSampleRate(rate):
            return "Cannot record at a sample rate of \(rate) Hz."
        case let .directoryUnavailable(path, reason):
            return "Cannot use the recordings folder “\(path)”: \(reason)"
        case let .directoryNotWritable(path):
            return "The recordings folder “\(path)” is not writable. Choose another folder in Settings."
        case let .insufficientDiskSpace(path, available):
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Not enough disk space to record in “\(path)” (\(free) free)."
        case let .audioFile(operation, path, status):
            let file = (path as NSString).lastPathComponent
            if status == OSStatus(dskFulErr) { return "Could not \(operation) “\(file)”: the disk is full." }
            return "Could not \(operation) “\(file)” (\(Self.describe(status)))."
        }
    }

    /// OSStatus as a four-character code when printable, else the number.
    static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "error \(status)" }
        return "error '\(String(decoding: bytes, as: UTF8.self))' (\(status))"
    }
}

// MARK: - Recorder

/// Records the engine's recording ring (raw and/or processed stereo) to audio files.
///
/// A dedicated writer thread drains the ring every ~20 ms into preallocated buffers and writes with
/// ExtAudioFile, which converts the float32 client data (device rate) to the file's sample rate and
/// bit depth. Samples beyond full scale are clamped for integer formats and counted. Problems (disk
/// full, file errors) stop the recording cleanly and are reported in `status.lastError`; the files
/// written so far stay valid. Methods are thread-safe; use one Recorder per engine.
public final class Recorder: @unchecked Sendable {
    /// WAV files are split into parts below RIFF's 4 GiB limit (ExtAudioFile fails at the limit).
    public static let defaultWAVPartBytes: Int64 = 4_000_000_000
    /// Starting needs this much free space; a running recording stops below `stopFreeBytes`.
    public static let minimumFreeBytes: Int64 = 200 * 1_048_576
    public static let stopFreeBytes: Int64 = 64 * 1_048_576

    public let engine: DSPEngine

    /// Thread-safe snapshot.
    public var status: RecordingStatus { state.snapshot }
    public var isRecording: Bool { state.snapshot.isRecording }

    /// Called on the main queue, at most 10 times per second, with the latest status.
    public var onStatusChange: ((RecordingStatus) -> Void)? {
        get { state.callback }
        set { state.callback = newValue }
    }

    private let log: LogStore
    private let wavPartBytes: Int64
    private let state = RecorderState()
    private let controlLock = NSLock() // serialises start/stop/routeDidChange; never taken by the writer
    private var session: RecordingSession? // guarded by controlLock

    /// - Parameter wavPartBytes: size at which WAV recordings continue in a new "part N" file.
    public init(engine: DSPEngine, log: LogStore = .shared, wavPartBytes: Int64 = Recorder.defaultWAVPartBytes) {
        self.engine = engine
        self.log = log
        self.wavPartBytes = max(wavPartBytes, 64 * 1024)
    }

    deinit {
        if let session {
            session.requestStop()
            session.join()
        }
    }

    /// Opens the file(s) and starts recording what the engine processes from now on.
    /// - Parameters:
    ///   - deviceSampleRate: rate the engine runs at (the client rate of the files).
    ///   - presetName: value of the `{preset}` token; nil gives "Custom".
    /// - Returns: the files being written (processed first for `.both`).
    @discardableResult
    public func start(settings: RecordingSettings, deviceSampleRate: Double, presetName: String?) throws -> [URL] {
        controlLock.lock()
        defer { controlLock.unlock() }
        if let current = session {
            guard current.isFinished else { throw RecorderError.alreadyRecording }
            current.join()
            session = nil
        }
        do {
            let newSession = try makeSession(settings: settings, deviceSampleRate: deviceSampleRate, presetName: presetName)
            session = newSession
            var initial = RecordingStatus()
            initial.isRecording = true
            initial.files = newSession.initialURLs
            initial.startedAt = Date()
            initial.deviceSampleRate = deviceSampleRate
            initial.fileSampleRate = newSession.fileRate
            initial.format = settings.format
            initial.source = settings.source
            state.update { $0 = initial }
            newSession.start()
            log.info("Recorder", "Recording \(settings.source.rawValue) audio as \(settings.format.displayName) at "
                     + "\(Self.rateDescription(newSession.fileRate)) to \(newSession.initialURLs.map(\.path).joined(separator: ", "))")
            state.notify()
            return newSession.initialURLs
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            var failed = RecordingStatus()
            failed.format = settings.format
            failed.source = settings.source
            failed.lastError = message
            state.update { $0 = failed }
            state.notify()
            log.error("Recorder", "Recording did not start: \(message)")
            throw error
        }
    }

    /// Stops recording: disables the ring, writes what is left in it and closes the files.
    /// Returns the final status. Does nothing (but return the status) when not recording.
    @discardableResult
    public func stop() -> RecordingStatus {
        controlLock.lock()
        defer { controlLock.unlock() }
        stopLocked(reason: nil)
        return state.snapshot
    }

    /// Tells the recorder that the output route was rebuilt. The files' client rate is fixed, so a
    /// recording stops (with `lastError` explaining why) if the device rate changed. Returns true if
    /// a recording was stopped.
    @discardableResult
    public func routeDidChange(newSampleRate: Double) -> Bool {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard let current = session, !current.isFinished else { return false }
        guard !newSampleRate.isFinite || abs(newSampleRate - current.deviceRate) >= 0.5 else { return false }
        let message = "Recording stopped because the output device changed "
            + "(\(Self.rateDescription(current.deviceRate)) -> \(Self.rateDescription(newSampleRate)))"
        stopLocked(reason: message)
        log.warning("Recorder", message)
        return true
    }

    /// "48 kHz", "44.1 kHz", "88.2 kHz", "22.05 kHz".
    public static func rateDescription(_ rate: Double) -> String {
        guard rate.isFinite, rate > 0 else { return "unknown rate" }
        var text = String(format: "%.2f", rate / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text) kHz"
    }

    // MARK: Private

    private func stopLocked(reason: String?) {
        guard let current = session else { return }
        current.requestStop()
        current.join()
        session = nil
        if let reason { state.update { $0.lastError = reason } }
        let final = state.snapshot
        if let error = final.lastError, reason == nil {
            log.warning("Recorder", "Recording ended with an error: \(error)")
        }
        let size = ByteCountFormatter.string(fromByteCount: final.bytesOnDisk, countStyle: .file)
        log.info("Recorder", "Recording stopped: \(String(format: "%.1f", final.duration)) s, \(size), "
                 + "\(final.droppedFrames) dropped frame(s), \(final.clippedSamples) clipped sample(s)")
        state.notify()
    }

    private func makeSession(settings: RecordingSettings, deviceSampleRate: Double,
                             presetName: String?) throws -> RecordingSession {
        let validRates = 8000.0...384_000.0
        guard deviceSampleRate.isFinite, validRates.contains(deviceSampleRate) else {
            throw RecorderError.invalidSampleRate(deviceSampleRate)
        }
        let fileRate = settings.fileSampleRate(deviceSampleRate: deviceSampleRate)
        guard fileRate.isFinite, validRates.contains(fileRate) else { throw RecorderError.invalidSampleRate(fileRate) }

        let directory = settings.directoryURL
        do {
            try AppPaths.ensureDirectory(directory)
        } catch {
            throw RecorderError.directoryUnavailable(path: directory.path, reason: PresetStore.describe(error))
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw RecorderError.directoryNotWritable(path: directory.path)
        }
        if let available = RecordingSession.availableBytes(at: directory), available < Self.minimumFreeBytes {
            throw RecorderError.insufficientDiskSpace(path: directory.path, availableBytes: available)
        }
        let plan = settings.planFiles(date: Date(), presetName: presetName)
        let session = RecordingSession(engine: engine, state: state, log: log, format: settings.format,
                                       streams: settings.source.streams, deviceRate: deviceSampleRate,
                                       fileRate: fileRate, directory: directory, stems: plan.stems,
                                       suffixes: plan.suffixes, wavPartBytes: wavPartBytes)
        try session.openInitialFiles(plan.urls)
        return session
    }
}

/// Status shared by the recorder and its writer thread, plus the coalesced main-queue notification.
private final class RecorderState: @unchecked Sendable {
    private static let minimumNotifyInterval: UInt64 = 100_000_000 // ns: <= 10 Hz

    private let lock = NSLock()
    private var status = RecordingStatus()
    private var onChange: ((RecordingStatus) -> Void)?
    private var notifyScheduled = false
    private var lastNotify: UInt64 = 0

    var snapshot: RecordingStatus { lock.withLock { status } }

    var callback: ((RecordingStatus) -> Void)? {
        get { lock.withLock { onChange } }
        set { lock.withLock { onChange = newValue } }
    }

    func update(_ change: (inout RecordingStatus) -> Void) {
        lock.withLock { change(&status) }
    }

    /// Schedules one delivery of the then-latest status on the main queue, no sooner than 100 ms
    /// after the previous one. Calls while a delivery is pending are coalesced into it.
    func notify() {
        let delay: UInt64? = lock.withLock {
            guard onChange != nil, !notifyScheduled else { return nil }
            notifyScheduled = true
            let elapsed = DispatchTime.now().uptimeNanoseconds &- lastNotify
            return elapsed >= Self.minimumNotifyInterval ? 0 : Self.minimumNotifyInterval - elapsed
        }
        guard let delay else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
            self?.deliver()
        }
    }

    private func deliver() {
        let (callback, current): (((RecordingStatus) -> Void)?, RecordingStatus) = lock.withLock {
            notifyScheduled = false
            lastNotify = DispatchTime.now().uptimeNanoseconds
            return (onChange, status)
        }
        callback?(current)
    }
}

/// One recording: the open files and the writer thread that feeds them.
private final class RecordingSession: @unchecked Sendable {
    /// Frames per ring read (~43 ms at 192 kHz).
    private static let chunkFrames = 8192
    private static let pollInterval = DispatchTimeInterval.milliseconds(20)
    private static let bytesRefreshInterval: UInt64 = 500_000_000 // ns
    private static let diskSpaceCheckInterval: UInt64 = 5_000_000_000 // ns

    private struct OpenFile {
        let stream: RecordingStream
        let url: URL
        let ref: ExtAudioFileRef
    }

    let deviceRate: Double
    let fileRate: Double
    private(set) var initialURLs: [URL] = []

    private let engine: DSPEngine
    private let state: RecorderState
    private let log: LogStore
    private let format: RecordingFormat
    private let streams: [RecordingStream]
    private let directory: URL
    private let stems: [String]
    private let suffixes: [String]
    private let wavPartBytes: Int64

    // Writer-thread state (set up before the thread starts).
    private var files: [OpenFile] = []
    private var allURLs: [URL] = []
    private var part = 1
    private var partFileFrames = 0.0 // estimated frames in the current WAV part

    private let wake = DispatchSemaphore(value: 0)
    private let done = DispatchGroup()
    private let flagLock = NSLock()
    private var stopFlag = false
    private var finished = false

    init(engine: DSPEngine, state: RecorderState, log: LogStore, format: RecordingFormat, streams: [RecordingStream],
         deviceRate: Double, fileRate: Double, directory: URL, stems: [String], suffixes: [String], wavPartBytes: Int64) {
        self.engine = engine
        self.state = state
        self.log = log
        self.format = format
        self.streams = streams
        self.deviceRate = deviceRate
        self.fileRate = fileRate
        self.directory = directory
        self.stems = stems
        self.suffixes = suffixes
        self.wavPartBytes = wavPartBytes
    }

    /// True once the writer thread has ended (stopped or failed).
    var isFinished: Bool { flagLock.withLock { finished } }

    func requestStop() {
        flagLock.withLock { stopFlag = true }
        wake.signal()
    }

    /// Waits until the writer thread has closed the files. Safe to call repeatedly.
    func join() { done.wait() }

    private var stopRequested: Bool { flagLock.withLock { stopFlag } }

    func openInitialFiles(_ urls: [URL]) throws {
        files = try openFiles(urls)
        initialURLs = urls
        allURLs = urls
    }

    /// Enables the engine's ring (so everything processed from now on is captured) and starts the writer.
    func start() {
        engine.setRecordingEnabled(true)
        done.enter()
        let thread = Thread { [self] in
            run()
            flagLock.withLock { finished = true }
            done.leave()
            state.notify()
        }
        thread.name = "EquAudio Recorder"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: Writer thread

    private func run() {
        let chunk = Self.chunkFrames
        let ring = UnsafeMutablePointer<Float>.allocate(capacity: chunk * DSPEngine.recordingChannels)
        let stereo = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        defer {
            ring.deallocate()
            stereo.deallocate()
        }
        let ringChannels = DSPEngine.recordingChannels
        let clamps = !format.isFloat
        let maxFramesPerPass = max(Int(deviceRate), chunk) // keep the status fresh under heavy load
        var framesRead: Int64 = 0
        var peak: Float = 0
        var clipped: UInt64 = 0
        var failure: String?
        var stopping = false
        var lastBytesRefresh: UInt64 = 0
        var lastSpaceCheck = DispatchTime.now().uptimeNanoseconds

        while true {
            if !stopping && stopRequested {
                // Disable first, then drain: everything pushed before this point is written.
                stopping = true
                engine.setRecordingEnabled(false)
            }
            var passFrames = 0
            var ringEmpty = false
            while failure == nil && (stopping || passFrames < maxFramesPerPass) {
                let frames = engine.readRecording(into: ring, maxFrames: chunk)
                if frames == 0 { ringEmpty = true; break }
                if format.isWAV, let error = rollOverIfNeeded(adding: frames) { failure = error; break }
                for file in files {
                    let offset = file.stream.ringChannelOffset
                    for i in 0..<frames {
                        for channel in 0..<2 {
                            var sample = ring[i * ringChannels + offset + channel]
                            if !sample.isFinite { sample = 0 }
                            let magnitude = abs(sample)
                            if magnitude > peak { peak = magnitude }
                            if clamps && magnitude > 1 {
                                sample = sample > 0 ? 1 : -1
                                clipped += 1
                            }
                            stereo[i * 2 + channel] = sample
                        }
                    }
                    var buffers = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8),
                                              mData: UnsafeMutableRawPointer(stereo)))
                    let status = ExtAudioFileWrite(file.ref, UInt32(frames), &buffers)
                    if status != noErr {
                        failure = "Recording stopped: "
                            + (RecorderError.audioFile(operation: "write to", path: file.url.path, status: status).errorDescription ?? "")
                        break
                    }
                }
                framesRead += Int64(frames)
                passFrames += frames
            }

            let now = DispatchTime.now().uptimeNanoseconds
            var bytes: Int64?
            if now &- lastBytesRefresh >= Self.bytesRefreshInterval {
                lastBytesRefresh = now
                bytes = allURLs.reduce(0) { $0 + Self.fileSize($1) }
            }
            if failure == nil && !stopping && now &- lastSpaceCheck >= Self.diskSpaceCheckInterval {
                lastSpaceCheck = now
                if let available = Self.availableBytes(at: directory), available < Recorder.stopFreeBytes {
                    failure = "Recording stopped because the disk is almost full ("
                        + ByteCountFormatter.string(fromByteCount: available, countStyle: .file) + " free)."
                }
            }
            let dropped = engine.recordingDroppedFrames
            let urls = allURLs
            state.update {
                $0.duration = Double(framesRead) / deviceRate
                $0.droppedFrames = dropped
                $0.peakDBFS = peak.linearToDB
                $0.clippedSamples = clipped
                $0.files = urls
                if let bytes { $0.bytesOnDisk = bytes }
            }
            if failure != nil || (stopping && ringEmpty) { break }
            state.notify()
            if ringEmpty { _ = wake.wait(timeout: .now() + Self.pollInterval) }
        }

        if !stopping { engine.setRecordingEnabled(false) }
        if let error = closeFiles(), failure == nil { failure = error }
        let bytes = allURLs.reduce(0) { $0 + Self.fileSize($1) }
        let dropped = engine.recordingDroppedFrames
        state.update {
            $0.isRecording = false
            $0.bytesOnDisk = bytes
            $0.droppedFrames = dropped
            if let failure { $0.lastError = failure }
        }
        if let failure { log.error("Recorder", failure) }
    }

    /// Before writing `frames` more device frames to a WAV part that would then exceed the part size,
    /// closes the current files and continues in "<name> part N". Returns an error message on failure.
    private func rollOverIfNeeded(adding frames: Int) -> String? {
        let bytesPerFrame = Double(format.bitDepth / 8 * 2)
        let added = Double(frames) * fileRate / deviceRate
        // Margin for the header and data the sample-rate converter still holds. A part always
        // receives at least one chunk, so a tiny part size cannot produce empty files.
        let projected = (partFileFrames + added + 4096) * bytesPerFrame + 65536
        guard partFileFrames > 0, projected > Double(wavPartBytes) else {
            partFileFrames += added
            return nil
        }
        if let error = closeFiles() { return error }
        part += 1
        let partStems = stems.map { "\($0) part \(part)" }
        let urls = RecordingSettings.uniqueFileURLs(in: directory, stems: partStems, suffixes: suffixes,
                                                    fileExtension: format.fileExtension).urls
        do {
            files = try openFiles(urls)
        } catch {
            return "Recording stopped: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        allURLs += urls
        partFileFrames = added
        log.info("Recorder", "WAV size limit reached; continuing in \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        return nil
    }

    /// Finalises and releases every open file. Returns an error message if one could not be finalised.
    private func closeFiles() -> String? {
        var failure: String?
        for file in files {
            let status = ExtAudioFileDispose(file.ref)
            if status != noErr && failure == nil {
                failure = "Recording stopped: "
                    + (RecorderError.audioFile(operation: "finish", path: file.url.path, status: status).errorDescription ?? "")
            }
        }
        files = []
        return failure
    }

    // MARK: Files

    /// Creates one file per stream (never overwriting). On failure nothing is left behind.
    private func openFiles(_ urls: [URL]) throws -> [OpenFile] {
        var opened: [OpenFile] = []
        do {
            for (stream, url) in zip(streams, urls) {
                opened.append(OpenFile(stream: stream, url: url, ref: try createFile(at: url)))
            }
            return opened
        } catch {
            for file in opened {
                ExtAudioFileDispose(file.ref)
                try? FileManager.default.removeItem(at: file.url)
            }
            throw error
        }
    }

    private func createFile(at url: URL) throws -> ExtAudioFileRef {
        var fileFormat = format.fileFormat(sampleRate: fileRate)
        var created: ExtAudioFileRef?
        // No kAudioFileFlags_EraseFile: creation fails rather than overwrite a file that appeared meanwhile.
        var status = ExtAudioFileCreateWithURL(url as CFURL, format.fileType, &fileFormat, nil, 0, &created)
        guard status == noErr, let file = created else {
            throw RecorderError.audioFile(operation: "create", path: url.path, status: status)
        }
        var client = Self.clientFormat(sampleRate: deviceRate)
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else {
            ExtAudioFileDispose(file)
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.audioFile(operation: "set up", path: url.path, status: status)
        }
        configureConverter(file, client: &client)
        return file
    }

    /// Mastering-quality sample-rate conversion (flat to 20 kHz) and TPDF dither for 16-bit files.
    /// Each property is only set where it applies: a rejected property can leave the converter
    /// unusable, in which case the client format is set again to rebuild it with default settings.
    private func configureConverter(_ file: ExtAudioFileRef, client: inout AudioStreamBasicDescription) {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr,
              let converter else { return }
        var properties: [(AudioConverterPropertyID, UInt32)] = []
        if fileRate != deviceRate {
            properties.append((kAudioConverterSampleRateConverterComplexity, kAudioConverterSampleRateConverterComplexity_Mastering))
            properties.append((kAudioConverterSampleRateConverterQuality, UInt32(kAudioConverterQuality_Max)))
        }
        if format == .wav16 {
            properties.append((kAudioConverterPropertyDithering, UInt32(kDitherAlgorithm_TPDF)))
            properties.append((kAudioConverterPropertyDitherBitDepth, 16))
        }
        guard !properties.isEmpty else { return }
        for (property, value) in properties {
            var value = value
            let status = AudioConverterSetProperty(converter, property, UInt32(MemoryLayout<UInt32>.size), &value)
            if status != noErr {
                log.warning("Recorder", "Converter setting \(RecorderError.describe(OSStatus(bitPattern: property))) "
                            + "rejected (\(RecorderError.describe(status))); using defaults")
                _ = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
                return
            }
        }
        // A NULL converter configuration makes ExtAudioFile adopt the converter's new settings.
        var config: UnsafeRawPointer?
        _ = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig,
                                    UInt32(MemoryLayout<UnsafeRawPointer?>.size), &config)
    }

    /// Interleaved float32 stereo, the layout of the split ring data.
    private static func clientFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8,
                                    mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                                    mBitsPerChannel: 32, mReserved: 0)
    }

    static func fileSize(_ url: URL) -> Int64 {
        var info = stat()
        let ok = url.withUnsafeFileSystemRepresentation { path in path.map { stat($0, &info) == 0 } ?? false }
        return ok ? Int64(info.st_size) : 0
    }

    /// Free space on the volume holding `url` (including purgeable space where macOS reports it).
    static func availableBytes(at url: URL) -> Int64? {
        var fs = statfs()
        let basic: Int64? = statfs(url.path, &fs) == 0 ? Int64(fs.f_bavail) * Int64(fs.f_bsize) : nil
        let fresh = URL(fileURLWithPath: url.path) // resource values are cached per URL instance
        let important = (try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        switch (basic, important) {
        case let (b?, i?): return max(b, i)
        case let (b?, nil): return b
        case let (nil, i?): return i
        case (nil, nil): return nil
        }
    }
}
