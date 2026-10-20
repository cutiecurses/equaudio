import CoreAudio
import Foundation

// MARK: - Device model

/// One HAL audio device as seen when the catalogue was read.
public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    /// Persistent identifier (kAudioDevicePropertyDeviceUID); survives reconnects and reboots.
    public let uid: String
    public let name: String
    public let manufacturer: String
    /// kAudioDeviceTransportType* code, e.g. 'bltn', 'usb ', 'virt'.
    public let transportType: UInt32
    /// Aggregate device (user-created, automatic or private). Never used as the output.
    public let isAggregate: Bool
    public let inputChannels: Int
    public let outputChannels: Int
    public let nominalSampleRate: Double
    public let isAlive: Bool
    /// Hidden devices (kAudioDevicePropertyIsHidden) are neither offered nor chosen automatically.
    public let isHidden: Bool
    /// A readable output volume exists (main element or the preferred stereo channels).
    public let hasVolumeControl: Bool

    public init(id: AudioObjectID, uid: String, name: String, manufacturer: String = "", transportType: UInt32,
                isAggregate: Bool? = nil, inputChannels: Int = 0, outputChannels: Int, nominalSampleRate: Double = 48_000,
                isAlive: Bool = true, isHidden: Bool = false, hasVolumeControl: Bool = false) {
        self.id = id
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.transportType = transportType
        self.isAggregate = isAggregate ?? Self.isAggregateTransport(transportType)
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.nominalSampleRate = nominalSampleRate
        self.isAlive = isAlive
        self.isHidden = isHidden
        self.hasVolumeControl = hasVolumeControl
    }

    public var transportName: String { Self.transportName(for: transportType) }

    /// Virtual or unknown transport (BlackHole, BoomAudio, Loopback, ...): apps' audio goes to software,
    /// not to hardware. Never chosen as the output (feedback / double processing).
    public var isVirtual: Bool {
        transportType == kAudioDeviceTransportTypeVirtual || transportType == kAudioDeviceTransportTypeUnknown
    }

    /// A real, connected output device that processed audio may be played on.
    public var isPhysicalOutput: Bool { outputChannels > 0 && !isVirtual && !isAggregate && isAlive }

    /// The built-in headphone jack output. On Apple silicon it is a separate device that exists while
    /// headphones are plugged in, and it is preferred over the built-in speakers.
    public var isBuiltInHeadphones: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn && uid.range(of: "headphone", options: .caseInsensitive) != nil
    }

    /// One of EquAudio's own private aggregate devices (visible only inside this process).
    public var isEquAudioAggregate: Bool { uid.hasPrefix(ProcessTapRouter.aggregateUIDPrefix) }

    public static func isAggregateTransport(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate
    }

    /// Display name of a transport type ("Built-in", "USB", "Bluetooth", ...).
    public static func transportName(for transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "Continuity (wired)"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity (wireless)"
        case 0x6363_6170: return "Continuity" // 'ccap', deprecated kAudioDeviceTransportTypeContinuityCapture
        case kAudioDeviceTransportTypeUnknown: return "Unknown"
        default: return HAL.printableFourCC(transport) ?? "Unknown"
        }
    }
}

/// Which device EquAudio plays processed audio on. Persisted in the app settings: keep this shape.
public enum OutputSelection: Codable, Hashable, Sendable {
    /// Follow the system output (falls back to a physical device when that is virtual).
    case systemDefault
    /// A specific device by UID (falls back while it is disconnected or unusable).
    case device(uid: String)
}

// MARK: - Catalogue (HAL reads)

/// Read-only views of the HAL device list plus the one deliberate system change EquAudio offers
/// (switching the default output). Safe from any non-audio thread.
public enum AudioDeviceCatalog {
    /// Every device the HAL lists, in HAL order (includes inputs, virtual and aggregate devices).
    public static func allDevices() -> [AudioDeviceInfo] {
        let ids = (try? HAL.getArray(HAL.systemObject, HAL.address(kAudioHardwarePropertyDevices), AudioObjectID.self)) ?? []
        return ids.compactMap { device(id: $0) }
    }

    /// Devices with output channels that a user may pick (output or mirror): excludes hidden devices
    /// and EquAudio's own private aggregates.
    public static func outputDevices() -> [AudioDeviceInfo] {
        allDevices().filter { $0.outputChannels > 0 && !$0.isHidden && !$0.isEquAudioAggregate }
    }

    public static func device(uid: String) -> AudioDeviceInfo? {
        if let id = try? HAL.translate(uid, HAL.address(kAudioHardwarePropertyTranslateUIDToDevice)),
           let info = device(id: id), info.uid == uid {
            return info
        }
        return allDevices().first { $0.uid == uid }
    }

    /// Reads one device; nil if the object is gone or is not a device.
    public static func device(id: AudioObjectID) -> AudioDeviceInfo? {
        guard id != kAudioObjectUnknown,
              let uid = try? HAL.getString(id, HAL.address(kAudioDevicePropertyDeviceUID)), !uid.isEmpty else { return nil }
        let name = (try? HAL.getString(id, HAL.address(kAudioObjectPropertyName))).flatMap { $0.isEmpty ? nil : $0 } ?? uid
        let manufacturer = (try? HAL.getString(id, HAL.address(kAudioObjectPropertyManufacturer))) ?? ""
        let transport = (try? HAL.get(id, HAL.address(kAudioDevicePropertyTransportType), UInt32.self)) ?? kAudioDeviceTransportTypeUnknown
        let classID = (try? HAL.get(id, HAL.address(kAudioObjectPropertyClass), AudioClassID.self)) ?? 0
        let inputs = inputStreamChannelCounts(of: id).reduce(0, +)
        let outputs = outputStreamChannelCounts(of: id).reduce(0, +)
        let rate = nominalSampleRate(of: id) ?? 0
        let hidden = ((try? HAL.get(id, HAL.address(kAudioDevicePropertyIsHidden), UInt32.self)) ?? 0) != 0
        return AudioDeviceInfo(
            id: id, uid: uid, name: name, manufacturer: manufacturer, transportType: transport,
            isAggregate: AudioDeviceInfo.isAggregateTransport(transport) || classID == kAudioAggregateDeviceClassID,
            inputChannels: inputs, outputChannels: outputs, nominalSampleRate: rate, isAlive: isAlive(id),
            isHidden: hidden, hasVolumeControl: outputs > 0 && !volumeElements(of: id).isEmpty)
    }

    /// Where apps play by default (kAudioHardwarePropertyDefaultOutputDevice).
    public static func defaultOutputDeviceID() -> AudioObjectID? {
        systemDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Where alerts and sound effects play (kAudioHardwarePropertyDefaultSystemOutputDevice).
    public static func defaultSystemOutputDeviceID() -> AudioObjectID? {
        systemDeviceID(kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    public static func defaultOutputDevice() -> AudioDeviceInfo? { defaultOutputDeviceID().flatMap { device(id: $0) } }

    public static func defaultSystemOutputDevice() -> AudioDeviceInfo? { defaultSystemOutputDeviceID().flatMap { device(id: $0) } }

    /// Makes `id` the system's default output. If alerts/sound effects played on the old default,
    /// they are moved too, so the user does not end up with alerts on a device that apps no longer use.
    /// Changes a system setting: call only on an explicit user action.
    public static func setDefaultOutputDevice(id: AudioObjectID) throws {
        let previous = defaultOutputDeviceID()
        let soundEffects = defaultSystemOutputDeviceID()
        try HAL.set(HAL.systemObject, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), id)
        if let previous, previous != id, soundEffects == previous {
            try HAL.set(HAL.systemObject, HAL.address(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
        }
    }

    public static func setDefaultOutputDevice(_ device: AudioDeviceInfo) throws { try setDefaultOutputDevice(id: device.id) }

    /// The device's preferred stereo pair, 1-based (kAudioDevicePropertyPreferredChannelsForStereo);
    /// (1, 2) when the device does not say.
    public static func preferredStereoChannels(of device: AudioObjectID) -> (left: Int, right: Int) {
        let addr = HAL.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput)
        if let pair = try? HAL.getArray(device, addr, UInt32.self), pair.count >= 2, pair[0] >= 1, pair[1] >= 1 {
            return (Int(pair[0]), Int(pair[1]))
        }
        return (1, 2)
    }

    public static func preferredStereoChannels(of device: AudioDeviceInfo) -> (left: Int, right: Int) {
        preferredStereoChannels(of: device.id)
    }

    /// Channels per output stream, in IOProc buffer order ([] if none or unreadable).
    public static func outputStreamChannelCounts(of device: AudioObjectID) -> [Int] {
        (try? HAL.streamChannelCounts(device, scope: kAudioObjectPropertyScopeOutput)) ?? []
    }

    public static func outputStreamChannelCounts(of device: AudioDeviceInfo) -> [Int] { outputStreamChannelCounts(of: device.id) }

    /// Channels per input stream, in IOProc buffer order ([] if none or unreadable).
    public static func inputStreamChannelCounts(of device: AudioObjectID) -> [Int] {
        (try? HAL.streamChannelCounts(device, scope: kAudioObjectPropertyScopeInput)) ?? []
    }

    /// Output elements that carry the volume: [main] when the device has a main volume control,
    /// otherwise those of the preferred stereo channels that have one; [] when there is none.
    public static func volumeElements(of device: AudioObjectID) -> [AudioObjectPropertyElement] {
        let main = HAL.address(kAudioDevicePropertyVolumeDecibels, scope: kAudioObjectPropertyScopeOutput)
        if HAL.hasProperty(device, main) { return [kAudioObjectPropertyElementMain] }
        let pair = preferredStereoChannels(of: device)
        return Set([pair.left, pair.right]).sorted().map { AudioObjectPropertyElement($0) }.filter {
            HAL.hasProperty(device, HAL.address(kAudioDevicePropertyVolumeDecibels, scope: kAudioObjectPropertyScopeOutput, element: $0))
        }
    }

    /// Output volume in dB (kAudioDevicePropertyVolumeDecibels): the main element when present,
    /// otherwise the mean of the preferred stereo channels; nil when the device has no volume control.
    public static func volumeDB(of device: AudioObjectID) -> Float? {
        let values = volumeElements(of: device).compactMap { element in
            try? HAL.get(device, HAL.address(kAudioDevicePropertyVolumeDecibels, scope: kAudioObjectPropertyScopeOutput, element: element), Float32.self)
        }.filter(\.isFinite)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    public static func volumeDB(of device: AudioDeviceInfo) -> Float? { volumeDB(of: device.id) }

    /// Allowed IO buffer sizes in frames (kAudioDevicePropertyBufferFrameSizeRange).
    public static func bufferFrameSizeRange(of device: AudioObjectID) -> ClosedRange<Int>? {
        guard let range = try? HAL.get(device, HAL.address(kAudioDevicePropertyBufferFrameSizeRange), AudioValueRange.self),
              range.mMinimum.isFinite, range.mMaximum.isFinite, range.mMinimum >= 1, range.mMaximum >= range.mMinimum else { return nil }
        return Int(range.mMinimum.rounded(.up))...Int(range.mMaximum.rounded(.down))
    }

    public static func bufferFrameSizeRange(of device: AudioDeviceInfo) -> ClosedRange<Int>? { bufferFrameSizeRange(of: device.id) }

    public static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        guard let rate = try? HAL.get(device, HAL.address(kAudioDevicePropertyNominalSampleRate), Float64.self),
              rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    /// kAudioDevicePropertyDeviceIsAlive; false when the device is gone, true if it does not say.
    public static func isAlive(_ device: AudioObjectID) -> Bool {
        let addr = HAL.address(kAudioDevicePropertyDeviceIsAlive)
        do {
            return try HAL.get(device, addr, UInt32.self) != 0
        } catch let error as HALError where error.isObjectGone {
            return false
        } catch {
            return true
        }
    }

    private static func systemDeviceID(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        guard let id = try? HAL.get(HAL.systemObject, HAL.address(selector), AudioObjectID.self),
              id != kAudioObjectUnknown else { return nil }
        return id
    }
}

// MARK: - Output policy (pure)

/// The device EquAudio will play on for a selection, and why when it differs from the selection.
public struct ResolvedOutput: Equatable, Sendable {
    public let device: AudioDeviceInfo
    /// True when the device is not what the selection literally points at.
    public let usingFallback: Bool
    /// User-facing explanation of the fallback, e.g. "System output is 'BoomAudio' (virtual); playing
    /// processed audio on 'External Headphones'".
    public let reason: String?

    public init(device: AudioDeviceInfo, usingFallback: Bool, reason: String?) {
        self.device = device
        self.usingFallback = usingFallback
        self.reason = reason
    }
}

/// Outcome of validating the optional mirror device.
public enum MirrorResolution: Equatable, Sendable {
    /// No mirror requested.
    case none
    case use(AudioDeviceInfo)
    /// Requested but not usable; `reason` is user-facing.
    case unavailable(uid: String, reason: String)

    public var device: AudioDeviceInfo? {
        if case .use(let device) = self { return device }
        return nil
    }
}

/// Chooses the output device. Pure: works only on the device list it is given.
///
/// Safety rule: the output is never a virtual or aggregate device. Apps (or another enhancer) play into
/// those; playing our processed copy there could be captured again (feedback) or processed twice.
/// Loopback devices are allowed only as the mirror.
public enum OutputPolicy {
    /// May EquAudio play processed audio on this device?
    public static func isEligibleOutput(_ device: AudioDeviceInfo) -> Bool { device.isPhysicalOutput && !device.isHidden }

    /// Resolves a selection. `.systemDefault`: the default output if physical, else the default
    /// system-sound output if physical, else the built-in output (headphones before speakers), else the
    /// first physical output. `.device(uid)`: that device if eligible, else the `.systemDefault` rule
    /// with a reason. `knownNames` maps UIDs of devices seen earlier to names, for messages about
    /// disconnected devices. Nil when no physical output exists at all.
    public static func resolve(selection: OutputSelection, devices: [AudioDeviceInfo], defaultOutputID: AudioObjectID?,
                               systemOutputID: AudioObjectID?, knownNames: [String: String] = [:]) -> ResolvedOutput? {
        switch selection {
        case .systemDefault:
            return resolveSystemDefault(devices: devices, defaultOutputID: defaultOutputID, systemOutputID: systemOutputID)
        case .device(let uid):
            let selected = devices.first { $0.uid == uid }
            if let selected, isEligibleOutput(selected) {
                return ResolvedOutput(device: selected, usingFallback: false, reason: nil)
            }
            guard let fallback = resolveSystemDefault(devices: devices, defaultOutputID: defaultOutputID,
                                                      systemOutputID: systemOutputID) else { return nil }
            let problem: String
            if let selected {
                problem = "Selected device '\(selected.name)' \(ineligibility(of: selected))"
            } else {
                problem = "Selected device '\(knownNames[uid] ?? uid)' is disconnected"
            }
            return ResolvedOutput(device: fallback.device, usingFallback: true, reason: "\(problem); using '\(fallback.device.name)'")
        }
    }

    /// Validates the mirror: it must exist, be alive, have outputs, not be an aggregate, not be the
    /// output itself, and not be the system or sound-effects output (a loopback device apps play into
    /// is usually read and played back by another router, so mirroring into it would feed EquAudio's
    /// output back into its own tap).
    public static func resolveMirror(uid: String?, devices: [AudioDeviceInfo], output: AudioDeviceInfo,
                                     defaultOutputID: AudioObjectID?, systemOutputID: AudioObjectID?,
                                     knownNames: [String: String] = [:]) -> MirrorResolution {
        guard let uid, !uid.isEmpty else { return .none }
        guard let mirror = devices.first(where: { $0.uid == uid }) else {
            return .unavailable(uid: uid, reason: "Mirror device '\(knownNames[uid] ?? uid)' is not connected")
        }
        let name = mirror.name
        let reason: String?
        if !mirror.isAlive {
            reason = "Mirror device '\(name)' is not available"
        } else if mirror.outputChannels == 0 {
            reason = "Mirror device '\(name)' has no output channels"
        } else if mirror.isAggregate {
            reason = "Mirror device '\(name)' is an aggregate device"
        } else if mirror.uid == output.uid {
            reason = "Mirror device '\(name)' is already the output device"
        } else if mirror.id == defaultOutputID || mirror.id == systemOutputID {
            reason = "Mirror device '\(name)' is the system output; mirroring into it would feed EquAudio's output back into its own input"
        } else {
            reason = nil
        }
        if let reason { return .unavailable(uid: uid, reason: reason) }
        return .use(mirror)
    }

    private static func resolveSystemDefault(devices: [AudioDeviceInfo], defaultOutputID: AudioObjectID?,
                                             systemOutputID: AudioObjectID?) -> ResolvedOutput? {
        let defaultDevice = defaultOutputID.flatMap { id in devices.first { $0.id == id } }
        if let defaultDevice, isEligibleOutput(defaultDevice) {
            return ResolvedOutput(device: defaultDevice, usingFallback: false, reason: nil)
        }
        let soundEffectsDevice = systemOutputID.flatMap { id in devices.first { $0.id == id } }
        let builtIn = devices.filter { isEligibleOutput($0) && $0.transportType == kAudioDeviceTransportTypeBuiltIn }
        let chosen = soundEffectsDevice.flatMap { isEligibleOutput($0) ? $0 : nil }
            ?? builtIn.first(where: \.isBuiltInHeadphones) ?? builtIn.first
            ?? devices.first(where: isEligibleOutput)
        guard let chosen else { return nil }
        let why = defaultDevice.map { "System output is '\($0.name)' (\(shortIneligibility(of: $0)))" }
            ?? "No system output device is set"
        return ResolvedOutput(device: chosen, usingFallback: true, reason: "\(why); playing processed audio on '\(chosen.name)'")
    }

    private static func ineligibility(of device: AudioDeviceInfo) -> String {
        if device.isAggregate { return "is an aggregate device and cannot be the output (its audio would be processed twice)" }
        if device.isVirtual { return "is a virtual device and cannot be the output (feedback and double-processing risk)" }
        if !device.isAlive { return "is not available" }
        if device.outputChannels == 0 { return "has no output channels" }
        return "is hidden"
    }

    private static func shortIneligibility(of device: AudioDeviceInfo) -> String {
        if device.isAggregate { return "aggregate" }
        if device.isVirtual { return "virtual" }
        if !device.isAlive { return "unavailable" }
        if device.outputChannels == 0 { return "no outputs" }
        return "hidden"
    }
}
