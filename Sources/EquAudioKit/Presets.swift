import Foundation

/// A named sound. Factory presets are built in and read-only; user presets live as JSON files.
///
/// JSON form: `{"format": "equaudio.preset", "version": 1, "id", "name", "summary", "isFactory",
/// "created", "modified" (ISO 8601, UTC), "settings": <DSPSettings>}`. Decoding requires the
/// format tag and readable `settings`; every other field falls back to a sensible value.
/// Dates are kept at whole-second precision so a preset survives a round trip unchanged.
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public static let formatIdentifier = "equaudio.preset"
    public static let formatVersion = 1

    public var id: UUID
    public var name: String
    /// One line describing the intent of the sound.
    public var summary: String
    public var settings: DSPSettings
    public var isFactory: Bool
    public var created: Date
    public var modified: Date

    public init(id: UUID = UUID(), name: String, summary: String = "", settings: DSPSettings,
                isFactory: Bool = false, created: Date = Date(), modified: Date? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.settings = settings
        self.isFactory = isFactory
        self.created = Self.wholeSeconds(created)
        self.modified = Self.wholeSeconds(modified ?? created)
    }

    /// `name` trimmed, with runs of whitespace/newlines collapsed to one space; nil if empty.
    public static func normalizedName(_ name: String) -> String? {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case format, version, id, name, summary, isFactory, created, modified, settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(String.self, forKey: .format)
        guard format == Self.formatIdentifier else {
            throw DecodingError.dataCorruptedError(
                forKey: .format, in: container,
                debugDescription: "Not an EquAudio preset (format \"\(format)\", expected \"\(Self.formatIdentifier)\")")
        }
        settings = try container.decode(DSPSettings.self, forKey: .settings)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = Self.normalizedName((try? container.decodeIfPresent(String.self, forKey: .name)) ?? "") ?? "Untitled Preset"
        summary = ((try? container.decodeIfPresent(String.self, forKey: .summary)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        isFactory = (try? container.decodeIfPresent(Bool.self, forKey: .isFactory)) ?? false
        let created = Self.decodeDate(container, .created) ?? Self.wholeSeconds(Date())
        self.created = created
        modified = Self.decodeDate(container, .modified) ?? created
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatIdentifier, forKey: .format)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(summary, forKey: .summary)
        try container.encode(isFactory, forKey: .isFactory)
        try container.encode(created.formatted(Self.iso8601), forKey: .created)
        try container.encode(modified.formatted(Self.iso8601), forKey: .modified)
        try container.encode(settings, forKey: .settings)
    }

    private static let iso8601 = Date.ISO8601FormatStyle()
    private static let iso8601Fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// ISO 8601 (with or without fractional seconds) or a number of seconds since 1970.
    private static func decodeDate(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let text = try? container.decode(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let date = (try? iso8601.parse(trimmed)) ?? (try? iso8601Fractional.parse(trimmed)) else { return nil }
            return wholeSeconds(date)
        }
        if let seconds = try? container.decode(Double.self, forKey: key), seconds.isFinite {
            return wholeSeconds(Date(timeIntervalSince1970: seconds))
        }
        return nil
    }
}

// MARK: - Factory presets

/// The built-in presets. IDs are stable forever (settings store the selected preset's ID).
public enum FactoryPresets {
    /// All factory presets in menu order; "Flat (Original)" is first.
    public static let all: [Preset] = [
        make(1, "Flat (Original)", "The original sound, untouched apart from the safety limiter."),
        make(2, "Balanced", "A gentle lift at both ends for a fuller, more open everyday sound.",
             eq: [1.5, 1.5, 1, 0, -0.5, 0, 0.5, 1, 1.5, 1.5]) {
            $0.bassBoostDB = 2; $0.clarity = 0.2; $0.loudness = 0.3; $0.stereoWidth = 1.1
        },
        make(3, "Bass Boost", "Punchier, fuller bass that leaves vocals untouched.",
             eq: [4, 4.5, 3.5, 1.5, 0, 0, 0, 0, 0, 0]) {
            $0.bassBoostDB = 6; $0.subBassDB = 3; $0.bassHarmonics = 0.3; $0[.deepBass] = 0.3
        },
        make(4, "Deep Bass", "Deep sub-bass weight for headphones and full-range speakers, kept centred.",
             eq: [6, 5, 3, 0, -1, 0, 0, 0, 0, 0]) {
            $0.subBassDB = 8; $0.bassBoostDB = 5; $0.bassHarmonics = 0.5; $0[.deepBass] = 0.85; $0.bassMono = true
        },
        make(17, "Concert Hall", "A spacious hall: warm reverb tail around full, detailed sound.",
             eq: [2, 2, 1, 0, 0, 0, 0.5, 1, 1.5, 1.5]) {
            $0[.reverbMix] = 0.3; $0[.reverbSize] = 0.8; $0[.reverbDamping] = 0.55; $0.bassBoostDB = 2; $0[.spatial] = 0.3
        },
        make(18, "3D Cinema", "Wide, enveloping and punchy: spatial width, light room and deep bass for movies and games.",
             eq: [4, 3.5, 2, 0, 0, 1, 1.5, 1, 1, 1]) {
            $0[.deepBass] = 0.4; $0[.spatial] = 0.7; $0[.reverbMix] = 0.15; $0[.reverbSize] = 0.55; $0.subBassDB = 4; $0.bassBoostDB = 3
            $0.bassHarmonics = 0.3; $0.clarity = 0.3; $0.loudness = 0.4; $0.stereoWidth = 1.2; $0.bassMono = true
        },
        make(16, "Heavenly Bass", "Rich, deep and punchy: weighty sub, warm low end, harmonics for small speakers, clean mids and a touch of air.",
             eq: [5, 5.5, 4, 1.5, -0.5, 0, 0.5, 1, 1.5, 1.5]) {
            $0.bassBoostDB = 5; $0.subBassDB = 4; $0.bassHarmonics = 0.4; $0[.deepBass] = 0.5; $0.clarity = 0.25; $0.loudness = 0.3
            $0.stereoWidth = 1.1; $0.bassMono = true
        },
        make(5, "Vocal Clarity", "Brings voices forward for podcasts, talk radio and dialogue.",
             eq: [-3, -2, -1, 0, 1, 2, 3, 2.5, 1, 0]) {
            $0.clarity = 0.6; $0.bassMono = true; $0.stereoWidth = 0.9
        },
        make(6, "Treble Detail", "Extra sparkle and air for dull recordings or dark-sounding headphones.",
             eq: [0, 0, 0, 0, 0, 0, 1, 2.5, 4, 4]) {
            $0.trebleDB = 3; $0.clarity = 0.2
        },
        make(7, "Warm", "Smooth and relaxed; tames bright or harsh sources.",
             eq: [2, 2.5, 2, 1, 0, -0.5, -1, -1.5, -2, -2]) {
            $0.trebleDB = -2; $0.bassBoostDB = 2
        },
        make(8, "Rock", "Tight drums, crunchy guitars and crisp cymbals.",
             eq: [4, 3, 1, -1, -2, -1, 1, 3, 3.5, 3]) {
            $0.bassBoostDB = 2; $0.stereoWidth = 1.15
        },
        make(9, "Electronic", "Big sub-bass and shimmering highs for EDM, house and hip-hop.",
             eq: [5, 4, 1.5, 0, -1.5, 0, 1, 1, 3, 4]) {
            $0.subBassDB = 3; $0.bassBoostDB = 2; $0.stereoWidth = 1.2; $0.bassMono = true
        },
        make(10, "Classical", "Natural, spacious orchestral sound with the dynamics left intact.",
             eq: [1, 1, 0, 0, 0, 0, 0, 0.5, 1, 1.5]) {
            $0.loudness = 0.4; $0.stereoWidth = 1.1; $0.limiterReleaseMS = 300
        },
        make(11, "Movies", "Cinematic impact and width with clear dialogue.",
             eq: [3, 2, 1, 0, 0, 1.5, 2, 1, 1, 1]) {
            $0.subBassDB = 3; $0.clarity = 0.4; $0.stereoWidth = 1.25; $0.loudness = 0.4
        },
        make(12, "Gaming (Footstep Detail)", "Highlights footsteps and positional cues and tames explosion rumble.",
             eq: [-4, -3, -2, -1, 0, 2, 4, 5, 3, 1]) {
            $0.clarity = 0.5; $0.stereoWidth = 1.3; $0.bassMono = true; $0.limiterReleaseMS = 80
        },
        make(13, "Headphones", "Crossfeed for a natural, speaker-like stereo image and less listening fatigue.",
             eq: [1.5, 1, 0, 0, 0, 0, 0.5, 0, 0.5, 1]) {
            $0.crossfeedEnabled = true; $0.crossfeedCutoffHz = 700; $0.crossfeedFeedDB = 4.5; $0.loudness = 0.3
        },
        make(14, "Laptop Speakers", "Fuller-sounding bass and clearer detail on small built-in speakers.",
             eq: [-6, -3, 2, 1, 0, 0, 1, 1, 1, 0]) {
            $0.bassHarmonics = 0.6; $0.clarity = 0.3; $0.stereoWidth = 1.2; $0.loudness = 0.4
        },
        make(15, "Late Night", "Clear, full sound at low volume with tamed peaks.") {
            $0.loudness = 0.8; $0.clarity = 0.3; $0.outputGainDB = -3; $0.limiterCeilingDB = -3; $0.limiterReleaseMS = 300
        },
    ]

    /// "Flat (Original)": every parameter at its default.
    public static var flat: Preset { all[0] }

    public static func preset(id: UUID) -> Preset? { all.first { $0.id == id } }

    /// Case-insensitive lookup by name.
    public static func preset(named name: String) -> Preset? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// 2026-10-01T00:00:00Z, the creation date shown for every factory preset.
    private static let releaseDate = Date(timeIntervalSinceReferenceDate: 812_505_600)

    /// Stable ID E9A0D100-FAC7-4000-8000-0000000000NN.
    private static func id(_ number: UInt8) -> UUID {
        UUID(uuid: (0xE9, 0xA0, 0xD1, 0x00, 0xFA, 0xC7, 0x40, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, number))
    }

    private static func make(_ number: UInt8, _ name: String, _ summary: String, eq: [Float]? = nil,
                             _ configure: (inout DSPSettings) -> Void = { _ in }) -> Preset {
        var settings = DSPSettings.defaults
        if let eq { settings.eqBands = eq }
        configure(&settings)
        return Preset(id: id(number), name: name, summary: summary, settings: settings, isFactory: true,
                      created: releaseDate, modified: releaseDate)
    }
}

// MARK: - Store

public enum PresetError: LocalizedError, Equatable {
    case factoryPresetIsReadOnly
    case notFound
    case emptyName
    /// The file is not an EquAudio preset or is damaged (file name, reason).
    case invalidFile(String, String)
    /// Reading, writing or deleting a file failed (description).
    case fileError(String)

    public var errorDescription: String? {
        switch self {
        case .factoryPresetIsReadOnly:
            "Built-in presets can’t be changed. Duplicate the preset to make your own version."
        case .notFound:
            "The preset no longer exists."
        case .emptyName:
            "Enter a name for the preset."
        case let .invalidFile(name, reason):
            "“\(name)” is not an EquAudio preset or is damaged (\(reason))."
        case let .fileError(description):
            description
        }
    }
}

/// Factory presets plus the user's presets, one `<uuid>.json` file each in `directory`.
///
/// Not thread-safe: use it from the main thread. Every mutation writes atomically before the
/// in-memory list changes, so a failed write leaves both unchanged.
public final class PresetStore {
    /// Extension of exported preset files.
    public static let fileExtension = "equpreset"

    public let directory: URL

    /// User presets sorted by name (case-insensitive).
    public private(set) var userPresets: [Preset] = []

    /// Called after every change of `userPresets` (load, save, update, rename, delete, ...).
    public var onChange: (() -> Void)?

    private let log: LogStore
    /// File each user preset was loaded from, when it is not the canonical `<uuid>.json`.
    private var legacyFiles: [UUID: URL] = [:]

    public init(directory: URL = AppPaths.presetsDirectory, log: LogStore = .shared) {
        self.directory = directory
        self.log = log
    }

    /// Factory presets in their fixed order, then user presets by case-insensitive name.
    public var allPresets: [Preset] { FactoryPresets.all + userPresets }

    public func preset(id: UUID) -> Preset? {
        FactoryPresets.preset(id: id) ?? userPresets.first { $0.id == id }
    }

    /// Reads every `*.json` file in `directory`. Unreadable or corrupt files, duplicate IDs and
    /// files claiming a factory preset's ID are skipped with a logged warning.
    @discardableResult
    public func load() -> [Preset] {
        var loaded: [Preset] = []
        var seen = Set<UUID>()
        var legacy: [UUID: URL] = [:]
        for url in presetFiles() {
            let preset: Preset
            do {
                preset = try Self.decoder.decode(Preset.self, from: Data(contentsOf: url))
            } catch {
                log.warning("Presets", "Skipped preset file \(url.lastPathComponent): \(Self.describe(error))")
                continue
            }
            if FactoryPresets.preset(id: preset.id) != nil {
                log.warning("Presets", "Skipped preset file \(url.lastPathComponent): it uses the ID of a built-in preset")
                continue
            }
            guard seen.insert(preset.id).inserted else {
                log.warning("Presets", "Skipped preset file \(url.lastPathComponent): another file has the same preset ID")
                continue
            }
            var user = preset
            user.isFactory = false
            loaded.append(user)
            if url.lastPathComponent != fileURL(for: user.id).lastPathComponent { legacy[user.id] = url }
        }
        userPresets = Self.sorted(loaded)
        legacyFiles = legacy
        log.info("Presets", "Loaded \(loaded.count) user preset(s) from \(directory.path)")
        onChange?()
        return allPresets
    }

    /// Saves the settings as a new user preset. The name is trimmed; if another preset already uses
    /// it (case-insensitively) " 2", " 3", ... is appended.
    @discardableResult
    public func save(name: String, settings: DSPSettings, summary: String = "") throws -> Preset {
        guard let base = Preset.normalizedName(name) else { throw PresetError.emptyName }
        let preset = Preset(name: uniqueName(for: base), summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                            settings: settings)
        try write(preset)
        userPresets = Self.sorted(userPresets + [preset])
        log.info("Presets", "Saved preset “\(preset.name)”")
        onChange?()
        return preset
    }

    /// Replaces a user preset's settings (and optionally its summary).
    @discardableResult
    public func update(id: UUID, settings: DSPSettings, summary: String? = nil) throws -> Preset {
        let index = try userIndex(of: id)
        var preset = userPresets[index]
        preset.settings = settings
        if let summary { preset.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines) }
        preset.modified = Preset.wholeSeconds(Date())
        try write(preset)
        userPresets[index] = preset
        onChange?()
        return preset
    }

    /// Renames a user preset (same trimming and de-duplication as `save`).
    @discardableResult
    public func rename(id: UUID, to newName: String) throws -> Preset {
        let index = try userIndex(of: id)
        guard let base = Preset.normalizedName(newName) else { throw PresetError.emptyName }
        var preset = userPresets[index]
        preset.name = uniqueName(for: base, excluding: id)
        preset.modified = Preset.wholeSeconds(Date())
        try write(preset)
        userPresets[index] = preset
        userPresets = Self.sorted(userPresets)
        onChange?()
        return preset
    }

    public func delete(id: UUID) throws {
        let index = try userIndex(of: id)
        for url in [fileURL(for: id), legacyFiles[id]].compactMap({ $0 }) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                throw PresetError.fileError("Could not delete the preset file: \(Self.describe(error))")
            }
        }
        legacyFiles[id] = nil
        let removed = userPresets.remove(at: index)
        log.info("Presets", "Deleted preset “\(removed.name)”")
        onChange?()
    }

    /// Copies any preset (factory or user) into a new user preset named "<name> Copy".
    @discardableResult
    public func duplicate(id: UUID) throws -> Preset {
        guard let source = preset(id: id) else { throw PresetError.notFound }
        let copy = Preset(name: uniqueName(for: "\(source.name) Copy"), summary: source.summary, settings: source.settings)
        try write(copy)
        userPresets = Self.sorted(userPresets + [copy])
        onChange?()
        return copy
    }

    /// Writes a preset (factory or user) as a shareable `.equpreset` file.
    public func export(id: UUID, to url: URL) throws {
        guard var preset = preset(id: id) else { throw PresetError.notFound }
        preset.isFactory = false
        do {
            try Self.encoder.encode(preset).write(to: url, options: .atomic)
        } catch {
            throw PresetError.fileError("Could not export the preset: \(Self.describe(error))")
        }
    }

    /// Adds the preset in an `.equpreset` (or bare DSP settings) file as a new user preset with a
    /// new ID. The imported name is de-duplicated like `save`.
    @discardableResult
    public func importPreset(from url: URL) throws -> Preset {
        let fileName = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresetError.fileError("Could not read “\(fileName)”: \(Self.describe(error))")
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let source: Preset
        do {
            source = try Self.decoder.decode(Preset.self, from: data)
        } catch {
            guard let settings = try? Self.decoder.decode(DSPSettings.self, from: data) else {
                throw PresetError.invalidFile(fileName, Self.describe(error))
            }
            source = Preset(name: Preset.normalizedName(stem) ?? "Imported Preset", settings: settings)
        }
        let preset = Preset(name: uniqueName(for: source.name), summary: source.summary, settings: source.settings)
        try write(preset)
        userPresets = Self.sorted(userPresets + [preset])
        log.info("Presets", "Imported preset “\(preset.name)” from \(fileName)")
        onChange?()
        return preset
    }

    /// `base` if no other preset uses it (case-insensitively), otherwise the first free "base N".
    public func uniqueName(for base: String, excluding id: UUID? = nil) -> String {
        let taken = Set(allPresets.lazy.filter { $0.id != id }.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: Private

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func userIndex(of id: UUID) throws -> Int {
        if FactoryPresets.preset(id: id) != nil { throw PresetError.factoryPresetIsReadOnly }
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { throw PresetError.notFound }
        return index
    }

    private func presetFiles() -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            log.error("Presets", "Could not read the presets folder \(directory.path): \(Self.describe(error))")
            return []
        }
    }

    /// Atomically writes `<uuid>.json`, then removes a differently named file the preset was loaded from.
    private func write(_ preset: Preset) throws {
        let url = fileURL(for: preset.id)
        do {
            try AppPaths.ensureDirectory(directory)
            try Self.encoder.encode(preset).write(to: url, options: .atomic)
        } catch {
            log.error("Presets", "Could not save preset “\(preset.name)”: \(Self.describe(error))")
            throw PresetError.fileError("Could not save the preset: \(Self.describe(error))")
        }
        if let legacy = legacyFiles.removeValue(forKey: preset.id) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    private static func sorted(_ presets: [Preset]) -> [Preset] {
        presets.sorted {
            switch $0.name.localizedCaseInsensitiveCompare($1.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.created == $1.created ? $0.id.uuidString < $1.id.uuidString : $0.created < $1.created
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case let .dataCorrupted(context), let .keyNotFound(_, context), let .typeMismatch(_, context),
                 let .valueNotFound(_, context):
                return context.debugDescription
            @unknown default:
                return decoding.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
