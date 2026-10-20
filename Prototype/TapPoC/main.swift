// Phase-1 proof of concept: another app's audio -> Core Audio process tap -> DSP -> physical output,
// with the raw and processed signals recorded to WAV and compared.
//
// Flow:
//   1. Write a two-tone test file (250 Hz + 1 kHz) and play it with /usr/bin/afplay (a separate process).
//   2. Create a private process tap on afplay (muted while tapped) and a private aggregate device
//      containing the tap plus a physical output device.
//   3. In the aggregate's IOProc apply a +12 dB peaking filter at 1 kHz and write the result to the device.
//   4. Save raw (tap) and processed signals as WAV and verify with Goertzel analysis that the
//      1 kHz tone gained ~12 dB while the 250 Hz tone stayed ~unchanged.
//
// Build/run: Prototype/run_poc.sh [--seconds N] [--silent]

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// MARK: - Small HAL helpers

func fourCC(_ s: OSStatus) -> String {
    let n = UInt32(bitPattern: s)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
    return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) ? "'\(String(decoding: bytes, as: UTF8.self))' (\(s))" : "\(s)"
}

// Output goes to stdout and, when launched as an app bundle via `open`, to a log file.
var logHandle: FileHandle?
func log(_ s: String) {
    print(s)
    fflush(stdout)
    logHandle?.write((s + "\n").data(using: .utf8)!)
}

struct HALError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed: \(fourCC(status))" }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr {
        let error = HALError(what: what, status: status)
        log("ERROR: \(error)")
        throw error
    }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func getValue<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) throws -> T {
    var a = addr
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "get property \(addr.mSelector)")
    return value
}

func getArray<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ zero: T) throws -> [T] {
    var a = addr
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "get size \(addr.mSelector)")
    var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &values), "get array \(addr.mSelector)")
    return values
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var a = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, let v = value else { return "?" }
    return v.takeRetainedValue() as String
}

func outputChannelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
    var a = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return [] }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.map { Int($0.mNumberChannels) }
}

// MARK: - TCC preflight/request (private SPI, informational; the tap itself is the public API)

let tccHandle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

func audioCapturePermission() -> String {
    guard let tccHandle, let sym = dlsym(tccHandle, "TCCAccessPreflight") else { return "unknown (SPI unavailable)" }
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    let preflight = unsafeBitCast(sym, to: Preflight.self)
    switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
    case 0: return "authorized"
    case 1: return "denied"
    default: return "not determined"
    }
}

func requestAudioCapturePermission() {
    guard let tccHandle, let sym = dlsym(tccHandle, "TCCAccessRequest") else { return }
    typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    let request = unsafeBitCast(sym, to: Request.self)
    request("kTCCServiceAudioCapture" as CFString, nil) { granted in log("TCC request callback: granted=\(granted)") }
}

// MARK: - Test signal and WAV I/O

func writeWAVFloat32(_ url: URL, interleaved: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Int) throws {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = interleaved.count * 4
    data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16)
    u16(3) // IEEE float
    u16(UInt16(channels)); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * 4))
    u16(UInt16(channels * 4)); u16(32)
    data.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
    data.append(UnsafeBufferPointer(start: UnsafeRawPointer(interleaved.baseAddress!).assumingMemoryBound(to: UInt8.self), count: bytes))
    try data.write(to: url)
}

func makeTestSignal(_ url: URL, seconds: Double, sampleRate: Int = 48000) throws {
    let frames = Int(seconds * Double(sampleRate))
    var buf = [Float](repeating: 0, count: frames * 2)
    let amp = Float(pow(10.0, -30.0 / 20.0)) // each tone at -30 dBFS: quiet, and leaves room for the +12 dB boost
    for i in 0..<frames {
        let t = Double(i) / Double(sampleRate)
        var fade = 1.0
        let edge = 0.05 * Double(sampleRate)
        if Double(i) < edge { fade = Double(i) / edge } else if Double(frames - i) < edge { fade = Double(frames - i) / edge }
        let s = Float(fade) * amp * Float(sin(2 * .pi * 250 * t) + sin(2 * .pi * 1000 * t))
        buf[2 * i] = s; buf[2 * i + 1] = s
    }
    try buf.withUnsafeBufferPointer { try writeWAVFloat32(url, interleaved: $0, channels: 2, sampleRate: sampleRate) }
}

/// Goertzel magnitude (as dBFS of a sine) of `x` at frequency `f`.
func toneLevel(_ x: ArraySlice<Float>, f: Double, sampleRate: Double) -> Double {
    let w = 2 * Double.pi * f / sampleRate
    let c = 2 * cos(w)
    var s1 = 0.0, s2 = 0.0
    var n = 0
    for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0; n += 1 }
    let power = s1 * s1 + s2 * s2 - c * s1 * s2
    let amplitude = 2 * sqrt(max(power, 0)) / Double(max(n, 1))
    return 20 * log10(max(amplitude, 1e-12))
}

// MARK: - Peaking biquad (RBJ cookbook), the "processing" under test

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0
    init(peakingAt f0: Double, q: Double, gainDB: Double, sampleRate: Double) {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * f0 / sampleRate, alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha / A
        b0 = (1 + alpha * A) / a0; b1 = -2 * cos(w0) / a0; b2 = (1 - alpha * A) / a0
        a1 = -2 * cos(w0) / a0; a2 = (1 - alpha / A) / a0
    }
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

// MARK: - Main

var seconds = 4.0
var silent = false
var waitForPermission = 0.0
var requestedOutputUID: String?
var outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("poc-output")
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--seconds": seconds = Double(args.popFirst() ?? "4") ?? 4
    case "--silent": silent = true
    case "--out": outDir = URL(fileURLWithPath: args.popFirst() ?? ".")
    case "--output-uid": requestedOutputUID = args.popFirst()
    case "--wait-permission": waitForPermission = Double(args.popFirst() ?? "600") ?? 600
    default: log("unknown argument \(a)"); exit(2)
    }
}
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: outDir.appendingPathComponent("poc.log").path, contents: nil)
logHandle = FileHandle(forWritingAtPath: outDir.appendingPathComponent("poc.log").path)

log("== EquAudio tap playthrough PoC ==")
log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), bundle=\(Bundle.main.bundleIdentifier ?? "none")")
log("System audio recording permission (TCC preflight): \(audioCapturePermission())")
if waitForPermission > 0 && audioCapturePermission() != "authorized" {
    log("Requesting permission and waiting up to \(Int(waitForPermission)) s for approval...")
    requestAudioCapturePermission()
    let deadline = Date().addingTimeInterval(waitForPermission)
    while audioCapturePermission() != "authorized" && Date() < deadline { Thread.sleep(forTimeInterval: 1) }
    log("Permission now: \(audioCapturePermission())")
}

// Pick a physical output device: default output unless it is virtual/aggregate, then the system output device.
let system = AudioObjectID(kAudioObjectSystemObject)
func transport(_ d: AudioObjectID) -> UInt32 { (try? getValue(d, address(kAudioDevicePropertyTransportType), UInt32(0))) ?? 0 }
func isPhysical(_ d: AudioObjectID) -> Bool {
    let t = transport(d)
    return t != kAudioDeviceTransportTypeVirtual && t != kAudioDeviceTransportTypeAggregate && t != kAudioDeviceTransportTypeUnknown
}
let defaultOut = try getValue(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0))
let systemOut = try getValue(system, address(kAudioHardwarePropertyDefaultSystemOutputDevice), AudioObjectID(0))
var outputDevice = defaultOut
if let requestedOutputUID {
    let all = try getArray(system, address(kAudioHardwarePropertyDevices), AudioObjectID(0))
    guard let d = all.first(where: { getString($0, kAudioDevicePropertyDeviceUID) == requestedOutputUID }) else {
        log("No device with UID \(requestedOutputUID)"); exit(1)
    }
    outputDevice = d
} else if !isPhysical(defaultOut) {
    log("Default output '\(getString(defaultOut, kAudioObjectPropertyName))' is virtual; using a physical device instead.")
    if isPhysical(systemOut) {
        outputDevice = systemOut
    } else {
        let all = try getArray(system, address(kAudioHardwarePropertyDevices), AudioObjectID(0))
        guard let d = all.first(where: { isPhysical($0) && !outputChannelCount($0, scope: kAudioObjectPropertyScopeOutput).isEmpty }) else {
            log("No physical output device found"); exit(1)
        }
        outputDevice = d
    }
}
let outputUID = getString(outputDevice, kAudioDevicePropertyDeviceUID)
let outputName = getString(outputDevice, kAudioObjectPropertyName)
log("Output device: \(outputName) [\(outputUID)] rate=\(try getValue(outputDevice, address(kAudioDevicePropertyNominalSampleRate), Float64(0)))")

// 1. Start the source application.
let testFile = outDir.appendingPathComponent("test-signal.wav")
try makeTestSignal(testFile, seconds: seconds + 2.5)
let player = Process()
player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
player.arguments = [testFile.path]
try player.run()
log("Started afplay pid=\(player.processIdentifier)")

var processObject = AudioObjectID(kAudioObjectUnknown)
for _ in 0..<60 {
    var pid = player.processIdentifier
    var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject)
    if processObject != kAudioObjectUnknown { break }
    usleep(50_000)
}
guard processObject != kAudioObjectUnknown else { log("afplay never registered with the audio server"); player.terminate(); exit(1) }
log("afplay audio process object: \(processObject)")

// 2. Tap + aggregate.
let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObject])
tapDescription.uuid = UUID()
tapDescription.name = "EquAudio PoC tap"
tapDescription.isPrivate = true
tapDescription.muteBehavior = .mutedWhenTapped
var tapID = AudioObjectID(kAudioObjectUnknown)
try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")
let tapFormat = try getValue(tapID, address(kAudioTapPropertyFormat), AudioStreamBasicDescription())
log("Tap \(tapID) format: \(tapFormat.mSampleRate) Hz, \(tapFormat.mChannelsPerFrame) ch, flags=\(tapFormat.mFormatFlags), bits=\(tapFormat.mBitsPerChannel)")

let aggregateUID = "com.equaudio.poc.aggregate.\(UUID().uuidString)"
let composition: [String: Any] = [
    kAudioAggregateDeviceNameKey: "EquAudio PoC",
    kAudioAggregateDeviceUIDKey: aggregateUID,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: false,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDescription.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
]
var aggregateID = AudioObjectID(kAudioObjectUnknown)
try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "AudioHardwareCreateAggregateDevice")

let rate = try getValue(aggregateID, address(kAudioDevicePropertyNominalSampleRate), Float64(0))
let bufferFrames = try getValue(aggregateID, address(kAudioDevicePropertyBufferFrameSize), UInt32(0))
let inputLayout = outputChannelCount(aggregateID, scope: kAudioObjectPropertyScopeInput)
let outputLayout = outputChannelCount(aggregateID, scope: kAudioObjectPropertyScopeOutput)
log("Aggregate \(aggregateID): rate=\(rate) buffer=\(bufferFrames) input streams(ch)=\(inputLayout) output streams(ch)=\(outputLayout)")

// 3. IOProc with processing; raw + processed captured into preallocated storage.
let capacityFrames = Int((seconds + 1) * rate)
let rawStore = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * 2)
let procStore = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * 2)
rawStore.initialize(repeating: 0, count: capacityFrames * 2)
procStore.initialize(repeating: 0, count: capacityFrames * 2)
let framesWritten = UnsafeMutablePointer<Int>.allocate(capacity: 1); framesWritten.initialize(to: 0)
let cycles = UnsafeMutablePointer<Int>.allocate(capacity: 1); cycles.initialize(to: 0)
let maxOut = UnsafeMutablePointer<Float>.allocate(capacity: 1); maxOut.initialize(to: 0)
var filters = [Biquad(peakingAt: 1000, q: 2, gainDB: 12, sampleRate: rate), Biquad(peakingAt: 1000, q: 2, gainDB: 12, sampleRate: rate)]
let filterStore = UnsafeMutablePointer<Biquad>.allocate(capacity: 2)
filterStore.initialize(from: &filters, count: 2)
let silentOutput = silent

var procID: AudioDeviceIOProcID?
try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInput, _, outOutput, _ in
    cycles.pointee += 1
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
    let outputs = UnsafeMutableAudioBufferListPointer(outOutput)
    // Zero all outputs first.
    for buf in outputs { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
    // The tap's stream is appended after any input streams of the sub-device: use the last input buffer.
    guard let tapBuffer = inputs.last, let src = tapBuffer.mData?.assumingMemoryBound(to: Float.self) else { return }
    let ch = Int(tapBuffer.mNumberChannels)
    let frames = Int(tapBuffer.mDataByteSize) / (4 * max(ch, 1))
    let out = outputs.first
    let outCh = Int(out?.mNumberChannels ?? 0)
    let dst = out?.mData?.assumingMemoryBound(to: Float.self)
    for i in 0..<frames {
        let l = src[i * ch], r = ch > 1 ? src[i * ch + 1] : l
        let pl = Float(filterStore[0].process(Double(l)))
        let pr = Float(filterStore[1].process(Double(r)))
        if let dst, !silentOutput, outCh >= 2 { dst[i * outCh] = pl; dst[i * outCh + 1] = pr }
        maxOut.pointee = max(maxOut.pointee, abs(pl), abs(pr))
        let w = framesWritten.pointee
        if w < capacityFrames {
            rawStore[2 * w] = l; rawStore[2 * w + 1] = r
            procStore[2 * w] = pl; procStore[2 * w + 1] = pr
            framesWritten.pointee = w + 1
        }
    }
}, "AudioDeviceCreateIOProcIDWithBlock")

try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
log("Running for \(seconds) s (output \(silent ? "silenced" : "audible at -30 dBFS per tone + EQ"))...")
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(aggregateID, procID)
AudioDeviceDestroyIOProcID(aggregateID, procID!)
AudioHardwareDestroyAggregateDevice(aggregateID)
AudioHardwareDestroyProcessTap(tapID)
player.terminate()

// 4. Save and verify.
let n = framesWritten.pointee
log("IO cycles=\(cycles.pointee) frames captured=\(n) peak out=\(String(format: "%.3f", maxOut.pointee))")
try writeWAVFloat32(outDir.appendingPathComponent("raw-tap.wav"), interleaved: UnsafeBufferPointer(start: rawStore, count: n * 2), channels: 2, sampleRate: Int(rate))
try writeWAVFloat32(outDir.appendingPathComponent("processed.wav"), interleaved: UnsafeBufferPointer(start: procStore, count: n * 2), channels: 2, sampleRate: Int(rate))

var rawL = [Float](), procL = [Float]()
for i in 0..<n { rawL.append(rawStore[2 * i]); procL.append(procStore[2 * i]) }
let firstSignal = rawL.firstIndex(where: { abs($0) > 1e-4 }) ?? n
let start = min(firstSignal + Int(0.3 * rate), n)
let end = max(start, n - Int(0.1 * rate))
let raw250 = toneLevel(rawL[start..<end], f: 250, sampleRate: rate), raw1k = toneLevel(rawL[start..<end], f: 1000, sampleRate: rate)
let pro250 = toneLevel(procL[start..<end], f: 250, sampleRate: rate), pro1k = toneLevel(procL[start..<end], f: 1000, sampleRate: rate)
log(String(format: "Raw tap:   250 Hz %.2f dBFS, 1 kHz %.2f dBFS (analysis window %.2f s)", raw250, raw1k, Double(end - start) / rate))
log(String(format: "Processed: 250 Hz %.2f dBFS, 1 kHz %.2f dBFS", pro250, pro1k))
let d250 = pro250 - raw250, d1k = pro1k - raw1k
log(String(format: "Change:    250 Hz %+.2f dB, 1 kHz %+.2f dB (expected ~+0.4 and +12.0)", d250, d1k))
let receivedAudio = end - start > Int(0.5 * rate) && raw1k > -40
let processedOK = abs(d1k - 12) < 1.0 && abs(d250) < 1.5
log("RESULT: received=\(receivedAudio) processedAsExpected=\(processedOK)")
if !receivedAudio {
    log("No audio from the tap. If permission is 'not determined'/'denied', allow System Audio Recording for the app that launched this tool (System Settings > Privacy & Security > Screen & System Audio Recording).")
}
exit(receivedAudio && processedOK ? 0 : 1)
