import CoreAudio
import EquCore
import Foundation

/// Metadata for one engine parameter (mirrors `EquParamInfo`).
public struct ParameterInfo: Identifiable, Hashable, Sendable {
    public let param: EquParam
    public let identifier: String
    public let displayName: String
    public let unit: String
    public let minValue: Float
    public let maxValue: Float
    public let defaultValue: Float
    /// Multiply stored values by this for display (100 for percentages).
    public let displayScale: Float
    public let isToggle: Bool

    public var id: UInt32 { param.rawValue }

    /// All parameters in ID order.
    public static let all: [ParameterInfo] = (0..<EquParam.count.rawValue).compactMap { ParameterInfo(EquParam(rawValue: $0)!) }

    public init?(_ param: EquParam) {
        var info = EquParamInfo()
        guard equ_param_info(param, &info) else { return nil }
        self.param = param
        identifier = info.identifier.map { String(cString: $0) } ?? ""
        displayName = info.displayName.map { String(cString: $0) } ?? ""
        unit = info.unit.map { String(cString: $0) } ?? ""
        minValue = info.minValue
        maxValue = info.maxValue
        defaultValue = info.defaultValue
        displayScale = info.displayScale
        isToggle = info.isToggle
    }

    public static func info(_ param: EquParam) -> ParameterInfo { ParameterInfo(param)! }

    public static func param(forIdentifier identifier: String) -> EquParam? {
        var p = EquParam.bypass
        return identifier.withCString { equ_param_from_identifier($0, &p) } ? p : nil
    }

    /// NaN/Inf -> default, clamped to range, toggles -> 0/1.
    public func validate(_ value: Float) -> Float { equ_param_validate(param, value) }
}

public extension EquParam {
    /// Graphic EQ band parameter (0 ... 9).
    static func eqBand(_ index: Int) -> EquParam {
        precondition((0..<Int(EQU_EQ_BAND_COUNT)).contains(index), "EQ band out of range")
        return EquParam(rawValue: EquParam.eqBand0.rawValue + UInt32(index))!
    }

    var info: ParameterInfo { ParameterInfo.info(self) }
}

/// Graphic EQ band centre frequencies in Hz.
public let eqBandFrequencies: [Double] = (0..<UInt32(EQU_EQ_BAND_COUNT)).map { equ_eq_band_frequency($0) }

/// Which stages `DSPEngine.response` includes.
public struct ResponseStages: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let eq = ResponseStages(rawValue: UInt32(EquResponseEQ))
    public static let tone = ResponseStages(rawValue: UInt32(EquResponseTone))
    public static let gain = ResponseStages(rawValue: UInt32(EquResponseGain))
    public static let all: ResponseStages = [.eq, .tone, .gain]
}

/// Owning Swift wrapper around the C++ `EquEngine`.
///
/// Parameter access, meters and response queries are safe from any thread. `prepare`/`reset` must
/// only be called while no IOProc is running for this engine (EngineController guarantees that).
public final class DSPEngine: @unchecked Sendable {
    /// The underlying `EquEngine *`, e.g. as IOProc client data.
    public let handle: OpaquePointer

    public init() {
        guard let engine = equ_engine_create() else { fatalError("EquCore: out of memory creating engine") }
        handle = engine
    }

    deinit { equ_engine_destroy(handle) }

    // MARK: Lifecycle

    @discardableResult
    public func prepare(sampleRate: Double, maxFrames: UInt32) -> Bool {
        equ_engine_prepare(handle, sampleRate, maxFrames)
    }

    public func reset() { equ_engine_reset(handle) }

    public var sampleRate: Double { equ_engine_sample_rate(handle) }

    /// Processing latency (look-ahead) in frames at the current sample rate.
    public var latencyFrames: UInt32 { equ_engine_latency_frames(handle) }

    // MARK: Parameters

    public subscript(param: EquParam) -> Float {
        get { equ_engine_get_param(handle, param) }
        set { equ_engine_set_param(handle, param, newValue) }
    }

    public var bypass: Bool {
        get { self[.bypass] > 0.5 }
        set { self[.bypass] = newValue ? 1 : 0 }
    }

    /// Output device volume in dB for loudness compensation; nil if the device has no volume control.
    public func setHostVolume(dB: Float?) {
        equ_engine_set_host_volume_db(handle, dB ?? 0, dB != nil)
    }

    /// Process/meter/record but send silence to the device.
    public func setOutputMuted(_ muted: Bool) { equ_engine_set_output_muted(handle, muted) }

    public var autoHeadroomDB: Float { equ_engine_auto_headroom_db(handle) }

    /// Static magnitude response (dB) of the selected stages at the given frequencies.
    public func response(frequencies: [Float], stages: ResponseStages = .all) -> [Float] {
        var out = [Float](repeating: 0, count: frequencies.count)
        frequencies.withUnsafeBufferPointer { f in
            out.withUnsafeMutableBufferPointer { o in
                equ_engine_response_db(handle, f.baseAddress!, o.baseAddress!, UInt32(frequencies.count), stages.rawValue)
            }
        }
        return out
    }

    /// Filter gains (dB) the graphic-EQ solver applies for the current slider positions.
    public func eqFilterGains() -> [Float] {
        var gains = [Float](repeating: 0, count: Int(EQU_EQ_BAND_COUNT))
        gains.withUnsafeMutableBufferPointer { equ_engine_eq_filter_gains(handle, $0.baseAddress!) }
        return gains
    }

    // MARK: Processing (offline use, tests)

    /// Processes planar stereo in place.
    public func process(left: inout [Float], right: inout [Float]) {
        precondition(left.count == right.count)
        let n = UInt32(left.count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                equ_engine_process(handle, l.baseAddress!, r.baseAddress!, l.baseAddress!, r.baseAddress!, n)
            }
        }
    }

    // MARK: IO

    public func setIOLayout(_ layout: EquIOLayout) {
        var l = layout
        equ_engine_set_io_layout(handle, &l)
    }

    /// The C IOProc to register with `AudioDeviceCreateIOProcID`, using `handle` as client data.
    public static let ioProc: AudioDeviceIOProc = equ_engine_ioproc

    // MARK: Meters

    public func readMeters() -> EquMeters {
        var m = EquMeters()
        equ_engine_read_meters(handle, &m)
        return m
    }

    // MARK: Analysis taps

    /// Latest `count` samples of the mono input and the stereo output (oldest first) for visualisation.
    public func readAnalysis(count: Int, input: inout [Float], left: inout [Float], right: inout [Float]) {
        if input.count != count { input = [Float](repeating: 0, count: count) }
        if left.count != count { left = [Float](repeating: 0, count: count) }
        if right.count != count { right = [Float](repeating: 0, count: count) }
        input.withUnsafeMutableBufferPointer { i in left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            _ = equ_engine_analysis_read(handle, i.baseAddress!, l.baseAddress!, r.baseAddress!, UInt32(count))
        } } }
    }

    // MARK: Recording ring

    public var isRecordingEnabled: Bool { equ_engine_recording_enabled(handle) }

    public func setRecordingEnabled(_ enabled: Bool) { equ_engine_recording_set_enabled(handle, enabled) }

    /// Reads up to `maxFrames` interleaved frames of `recordingChannels` channels
    /// (rawL, rawR, processedL, processedR). Returns frames read.
    public func readRecording(into buffer: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        Int(equ_engine_recording_read(handle, buffer, UInt32(maxFrames)))
    }

    public var recordingDroppedFrames: UInt64 { equ_engine_recording_dropped_frames(handle) }

    public static let recordingChannels = Int(EQU_RECORDING_CHANNELS)
}

public extension Float {
    /// Linear amplitude -> dBFS (floored at -120).
    var linearToDB: Float { self > 1e-6 ? 20 * log10(self) : -120 }
}
