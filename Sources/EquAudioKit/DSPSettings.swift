import EquCore
import Foundation

/// A complete sound: one value for every engine parameter except `.bypass`.
///
/// Bypass is session state (the A/B switch), not part of a sound, so presets and saved settings
/// never carry it. Values are always valid: every write goes through `ParameterInfo.validate` and is
/// then quantised to 4 decimals (the precision of the JSON form), so settings survive a save/load
/// round trip bit-exactly and equality is meaningful ("is this still preset X?").
///
/// JSON form: `{"format": "equaudio.dsp", "version": 1, "values": {"<identifier>": number}}`.
/// Decoding is tolerant: unknown identifiers are ignored, missing or non-numeric values take their
/// default, out-of-range values are clamped. Only a wrong or missing `format` is an error.
public struct DSPSettings: Codable, Hashable, Sendable {
    /// Document type tag written to and required in the JSON form.
    public static let formatIdentifier = "equaudio.dsp"
    public static let formatVersion = 1

    /// The stored parameters, in ID order (every parameter except `.bypass`).
    public static let parameters: [EquParam] = ParameterInfo.all.map(\.param).filter { $0 != .bypass }

    /// Every parameter at its default value.
    public static let defaults = DSPSettings()

    /// Number of graphic-EQ bands (`eqBands.count`).
    public static let eqBandCount = Int(EQU_EQ_BAND_COUNT)

    /// Values indexed by `EquParam.rawValue`; index 0 (bypass) is unused and stays 0.
    private var values: [Float]

    /// Defaults for every parameter.
    public init() {
        values = Self.infos.map { $0.param == .bypass ? 0 : $0.defaultValue }
    }

    /// Captures the engine's current (target) parameter values.
    public init(engine: DSPEngine) {
        self.init()
        for param in Self.parameters { self[param] = engine[param] }
    }

    /// Writes every value to the engine. Parameters that already have the value are skipped, so
    /// re-applying a preset does not restart parameter smoothing or rerun the EQ solver.
    public func apply(to engine: DSPEngine) {
        for param in Self.parameters where engine[param] != self[param] {
            engine[param] = self[param]
        }
    }

    /// Value of a parameter in its stored unit. Writes are validated (NaN/Inf -> default, clamped,
    /// toggles -> 0/1) and quantised to 4 decimals. `.bypass` is not stored: it reads as 0 and
    /// writes to it are ignored.
    public subscript(param: EquParam) -> Float {
        get {
            let index = Int(param.rawValue)
            return param == .bypass || index >= values.count ? 0 : values[index]
        }
        set {
            let index = Int(param.rawValue)
            guard param != .bypass, index < values.count else { return }
            values[index] = Self.canonical(newValue, for: param)
        }
    }

    // MARK: Typed accessors

    public var preampDB: Float {
        get { self[.preampDB] }
        set { self[.preampDB] = newValue }
    }

    public var autoHeadroom: Bool {
        get { flag(.autoHeadroom) }
        set { setFlag(.autoHeadroom, newValue) }
    }

    public var eqEnabled: Bool {
        get { flag(.eqEnabled) }
        set { setFlag(.eqEnabled, newValue) }
    }

    /// Graphic-EQ slider gains in dB, band 0 (31 Hz) ... 9 (16 kHz). On assignment, extra values
    /// are ignored and missing trailing bands are set to 0 dB.
    public var eqBands: [Float] {
        get { (0..<Self.eqBandCount).map { self[.eqBand($0)] } }
        set {
            for band in 0..<Self.eqBandCount {
                self[.eqBand(band)] = band < newValue.count ? newValue[band] : 0
            }
        }
    }

    public var bassBoostDB: Float {
        get { self[.bassBoostDB] }
        set { self[.bassBoostDB] = newValue }
    }

    public var subBassDB: Float {
        get { self[.subBassDB] }
        set { self[.subBassDB] = newValue }
    }

    /// 0 ... 1.
    public var bassHarmonics: Float {
        get { self[.bassHarmonics] }
        set { self[.bassHarmonics] = newValue }
    }

    public var trebleDB: Float {
        get { self[.trebleDB] }
        set { self[.trebleDB] = newValue }
    }

    /// 0 ... 1.
    public var clarity: Float {
        get { self[.clarity] }
        set { self[.clarity] = newValue }
    }

    /// 0 ... 1.
    public var loudness: Float {
        get { self[.loudness] }
        set { self[.loudness] = newValue }
    }

    /// 0 (mono) ... 2 (200 % side level); 1 is unchanged.
    public var stereoWidth: Float {
        get { self[.stereoWidth] }
        set { self[.stereoWidth] = newValue }
    }

    public var bassMono: Bool {
        get { flag(.bassMono) }
        set { setFlag(.bassMono, newValue) }
    }

    public var crossfeedEnabled: Bool {
        get { flag(.crossfeedEnabled) }
        set { setFlag(.crossfeedEnabled, newValue) }
    }

    public var crossfeedCutoffHz: Float {
        get { self[.crossfeedCutoffHz] }
        set { self[.crossfeedCutoffHz] = newValue }
    }

    public var crossfeedFeedDB: Float {
        get { self[.crossfeedFeedDB] }
        set { self[.crossfeedFeedDB] = newValue }
    }

    public var outputGainDB: Float {
        get { self[.outputGainDB] }
        set { self[.outputGainDB] = newValue }
    }

    public var limiterEnabled: Bool {
        get { flag(.limiterEnabled) }
        set { setFlag(.limiterEnabled, newValue) }
    }

    public var limiterCeilingDB: Float {
        get { self[.limiterCeilingDB] }
        set { self[.limiterCeilingDB] = newValue }
    }

    public var limiterReleaseMS: Float {
        get { self[.limiterReleaseMS] }
        set { self[.limiterReleaseMS] = newValue }
    }

    public var limiterTruePeak: Bool {
        get { flag(.limiterTruePeak) }
        set { setFlag(.limiterTruePeak, newValue) }
    }

    /// Parameters whose value differs from `other`, in ID order.
    public func differences(from other: DSPSettings) -> [EquParam] {
        Self.parameters.filter { self[$0] != other[$0] }
    }

    private func flag(_ param: EquParam) -> Bool { self[param] >= 0.5 }
    private mutating func setFlag(_ param: EquParam, _ on: Bool) { self[param] = on ? 1 : 0 }

    // MARK: Validation

    /// Parameter metadata indexed by raw value.
    private static let infos: [ParameterInfo] = ParameterInfo.all

    /// Stored-parameter lookup by stable identifier (bypass deliberately absent).
    private static let paramsByIdentifier: [String: EquParam] = Dictionary(
        uniqueKeysWithValues: parameters.map { (infos[Int($0.rawValue)].identifier, $0) })

    /// Validated, 4-decimal-quantised value; -0 becomes 0. Idempotent, and a quantised value
    /// survives `rounded4` -> JSON -> Float conversion unchanged.
    private static func canonical(_ value: Float, for param: EquParam) -> Float {
        let valid = infos[Int(param.rawValue)].validate(value)
        let quantised = Float(rounded4(valid))
        return quantised == 0 ? 0 : quantised
    }

    private static func rounded4(_ value: Float) -> Double {
        (Double(value) * 10_000).rounded() / 10_000
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case format, version, values }

    private struct IdentifierKey: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(String.self, forKey: .format)
        guard format == Self.formatIdentifier else {
            throw DecodingError.dataCorruptedError(
                forKey: .format, in: container,
                debugDescription: "Not EquAudio DSP settings (format \"\(format)\", expected \"\(Self.formatIdentifier)\")")
        }
        self.init()
        guard let stored = try? container.nestedContainer(keyedBy: IdentifierKey.self, forKey: .values) else { return }
        for key in stored.allKeys {
            guard let param = Self.paramsByIdentifier[key.stringValue],
                  let number = try? stored.decode(Double.self, forKey: key), number.isFinite else { continue }
            // Clamp in Double first so values beyond Float's range clamp instead of becoming Inf.
            let info = Self.infos[Int(param.rawValue)]
            self[param] = Float(min(max(number, Double(info.minValue)), Double(info.maxValue)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatIdentifier, forKey: .format)
        try container.encode(Self.formatVersion, forKey: .version)
        var stored = container.nestedContainer(keyedBy: IdentifierKey.self, forKey: .values)
        for param in Self.parameters {
            let key = IdentifierKey(stringValue: Self.infos[Int(param.rawValue)].identifier)
            try stored.encode(Self.rounded4(self[param]), forKey: key)
        }
    }
}
