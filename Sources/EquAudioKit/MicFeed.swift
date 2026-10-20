import AppKit
import AVFoundation
import CoreAudio
import EquCore
import Foundation

/// Where the virtual mic's audio comes from.
public struct FeedSource: Hashable, Identifiable, Sendable {
    /// App group key (see `MicFeed.groupKey`); nil = all system audio.
    public let key: String?
    public let name: String
    public var id: String { key ?? "*all" }
    public static let allSystemAudio = FeedSource(key: nil, name: "All system audio")
    public init(key: String?, name: String) { self.key = key; self.name = name }
}

/// Microphone permission (TCC "Microphone"), needed only when the user mixes their voice in.
public enum MicrophonePermission {
    public static func status() -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    public static var isAuthorized: Bool { status() == .authorized }
    public static func request(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { completion(granted) } }
    }
    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }
}

/// "Virtual mic": copies one app's audio (or all system audio) through its own EQ engine into a loopback
/// device such as BlackHole. Chat apps that select that device as their microphone then hear the processed
/// audio. macOS cannot create an input device without a driver, so a loopback driver must be installed.
///
/// Uses its own process tap (unmuted) and private aggregate, independent of the main enhancer route, so the
/// original keeps playing for you. Main-thread object; a 1 s poll follows the app's audio processes (they
/// appear and disappear as playback starts and stops) and the loopback device (unplugged / driver restart).
public final class MicFeed {
    public enum Status: Equatable {
        case off
        case running(String)
        case waiting(String)
        case failed(String)
    }

    public static let installCommand = "brew install --cask blackhole-2ch"

    public let engine = DSPEngine()
    public private(set) var status: Status = .off { didSet { if status != oldValue { onChange?() } } }
    public var onChange: (() -> Void)?

    private let log: LogStore
    private var router: ProcessTapRouter?
    private var timer: Timer?
    private var source = FeedSource.allSystemAudio
    private var deviceUID: String?
    private var signature: [UInt64] = []
    private var failureCooldown = 0
    private var voiceEnabled = false
    private var voiceUID: String?
    /// Why the voice is not being mixed although requested (permission, missing device); nil when fine.
    public private(set) var voiceIssue: String? { didSet { if voiceIssue != oldValue { onChange?() } } }
    public private(set) var voiceDeviceName: String?
    private static let category = "MicFeed"

    public init(log: LogStore = .shared) { self.log = log }

    // MARK: Devices and sources

    /// Loopback devices that can act as a microphone: alive, both inputs and outputs, known loopback name.
    public static func loopbackDevices() -> [AudioDeviceInfo] {
        let patterns = ["blackhole", "loopback", "soundflower", "vb-cable"]
        return AudioDeviceCatalog.allDevices()
            .filter { d in
                d.isAlive && d.outputChannels > 0 && d.inputChannels > 0 && !d.isEquAudioAggregate
                    && patterns.contains { d.name.lowercased().contains($0) }
            }
            .sorted { ($0.outputChannels, $0.name) < ($1.outputChannels, $1.name) }
    }

    /// Microphones that can feed the voice mix: alive input devices that are not loopback/aggregate/virtual-driver devices.
    public static func microphones() -> [AudioDeviceInfo] {
        let loopbackNames = ["blackhole", "loopback", "soundflower", "vb-cable"]
        return AudioDeviceCatalog.allDevices().filter { d in
            d.isAlive && d.inputChannels > 0 && !d.isAggregate && !d.isEquAudioAggregate
                && !d.manufacturer.localizedCaseInsensitiveContains("Global Delight")
                && !loopbackNames.contains { d.name.lowercased().contains($0) }
        }
    }

    static func defaultInputID() -> AudioObjectID? {
        try? HAL.get(HAL.systemObject, HAL.address(kAudioHardwarePropertyDefaultInputDevice), AudioObjectID.self)
    }

    /// Process objects of one app are grouped by bundle id without helper suffixes
    /// ("com.google.Chrome.helper.Renderer" -> "com.google.Chrome"; WebKit's audio processes -> Safari).
    public static func groupKey(bundleID: String?, name: String) -> String {
        guard var b = bundleID, !b.isEmpty else { return "name:" + name }
        if b.hasPrefix("com.apple.WebKit.") { return "com.apple.Safari" }
        if let r = b.range(of: ".helper", options: .caseInsensitive) { b = String(b[..<r.lowerBound]) }
        return b
    }

    static func appName(key: String, fallback: String) -> String {
        if key.hasPrefix("name:") { return String(key.dropFirst(5)) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return fallback.replacingOccurrences(of: " Helper", with: "")
    }

    /// "All system audio" plus every app that is currently playing audio (and the selected one).
    public func availableSources() -> [FeedSource] {
        var found = [String: FeedSource]()
        for p in AudioProcesses.playingProcesses() {
            let key = Self.groupKey(bundleID: p.bundleID, name: p.name)
            found[key] = FeedSource(key: key, name: Self.appName(key: key, fallback: p.name))
        }
        if let k = source.key, found[k] == nil { found[k] = source }
        return [.allSystemAudio] + found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func processIDs(for source: FeedSource) -> [AudioObjectID] {
        guard let key = source.key else { return [] }
        let own = getpid()
        return AudioProcesses.all()
            .filter { $0.pid != own && Self.groupKey(bundleID: $0.bundleID, name: $0.name) == key }
            .map(\.id).sorted()
    }

    // MARK: Control

    /// Applies the enhancer's DSP settings (same sound you hear) plus a separate level for the mic.
    public func apply(_ dsp: DSPSettings, musicGainDB: Float, voiceGainDB: Float, voiceMuted: Bool, duck: Float) {
        dsp.apply(to: engine)
        engine.bypass = false
        engine[.outputGainDB] = dsp[.outputGainDB] + musicGainDB
        engine[.voiceGainDB] = voiceGainDB
        engine[.voiceMute] = voiceMuted ? 1 : 0
        engine[.voiceDuck] = duck
    }

    /// Turns the voice mix on or off and picks the microphone (nil = system default input). Rebuilds the route.
    public func setVoice(enabled: Bool, deviceUID: String?) {
        voiceEnabled = enabled
        voiceUID = deviceUID
        if timer != nil { signature = []; tick() }
    }

    /// Starts feeding. `deviceUID` nil = first loopback device found. `outputOverride`/`silent` are for tests.
    public func start(source: FeedSource, deviceUID: String? = nil, outputOverride: AudioDeviceInfo? = nil, silent: Bool = false) {
        stop()
        self.source = source
        self.deviceUID = deviceUID
        self.outputOverride = outputOverride
        engine.setOutputMuted(silent)
        status = .waiting("Starting…")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        teardown()
        status = .off
    }

    public func readMeters() -> EquMeters { engine.readMeters() }

    private var outputOverride: AudioDeviceInfo?

    private func teardown() {
        router?.teardown()
        router = nil
        signature = []
    }

    private func tick() {
        let devices = outputOverride.map { [$0] } ?? Self.loopbackDevices()
        guard let device = devices.first(where: { deviceUID == nil || $0.uid == deviceUID }) ?? devices.first else {
            teardown()
            status = .waiting("No loopback device found. Install BlackHole 2ch.")
            return
        }
        let target: TapTarget
        var sig: [UInt64] = [UInt64(device.id), UInt64(AudioDeviceCatalog.nominalSampleRate(of: device.id) ?? 0)]
        if source.key != nil {
            let ids = processIDs(for: source)
            guard !ids.isEmpty else {
                teardown()
                status = .waiting("\(source.name) isn't playing audio yet")
                return
            }
            target = .processes(ids)
            sig += ids.map { UInt64($0) }
        } else {
            guard let own = AudioProcesses.ownProcessObjectID() else {
                status = .failed("Could not identify EquAudio's own audio process (feedback protection).")
                return
            }
            target = .global(excluding: [own])
        }
        // Voice: microphone sub-device (needs the Microphone permission; without it the music still flows).
        var voiceDevice: AudioDeviceInfo?
        voiceIssue = nil
        if voiceEnabled {
            let mics = Self.microphones()
            let chosen = mics.first { $0.uid == voiceUID } ?? mics.first { $0.id == Self.defaultInputID() } ?? mics.first
            if !MicrophonePermission.isAuthorized {
                voiceIssue = "Microphone access is off. Allow EquAudio in System Settings > Privacy & Security > Microphone."
            } else if let chosen {
                voiceDevice = chosen
                sig.append(UInt64(chosen.id))
            } else {
                voiceIssue = "No microphone found."
            }
        }
        voiceDeviceName = voiceDevice?.name
        if router != nil, sig == signature { return }
        if failureCooldown > 0 { failureCooldown -= 1; return }
        teardown()
        let router = ProcessTapRouter(engine: engine, log: log)
        do {
            let route = try router.build(RouteRequest(output: device, bufferFrames: 512, tapTarget: target, tapMuteBehavior: .unmuted, voice: voiceDevice))
            engine.prepare(sampleRate: route.sampleRate, maxFrames: 4096)
            engine.setIOLayout(route.layout)
            try router.start()
            self.router = router
            signature = sig
            status = .running("\(source.name)\(voiceDevice.map { " + \($0.name)" } ?? "") → \(device.name)")
            log.info(Self.category, "Feeding '\(source.name)' into '\(device.name)' at \(Int(route.sampleRate)) Hz")
        } catch {
            router.teardown()
            failureCooldown = 3
            status = .failed("\(error)")
            log.error(Self.category, "Start failed: \(error)")
        }
    }
}
