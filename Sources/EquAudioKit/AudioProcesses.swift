import AppKit
import CoreAudio
import Darwin
import Foundation

/// A Core Audio client process as the HAL sees it (kAudioHardwarePropertyProcessObjectList).
public struct AudioProcessInfo: Identifiable, Hashable, Sendable {
    /// The HAL process object (what process taps include or exclude).
    public let id: AudioObjectID
    public let pid: pid_t
    /// nil for processes without a bundle (command-line tools, some daemons).
    public let bundleID: String?
    /// Localized application name, else the executable name.
    public let name: String
    /// The process currently runs audio output IO (it may still be sending silence).
    public let isRunningOutput: Bool
    public let isRunningInput: Bool

    public init(id: AudioObjectID, pid: pid_t, bundleID: String?, name: String, isRunningOutput: Bool, isRunningInput: Bool) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
    }
}

/// Read-only queries of the HAL process objects. Safe from any non-audio thread.
public enum AudioProcesses {
    /// All HAL process objects with their current state.
    public static func all() -> [AudioProcessInfo] {
        processObjectIDs().compactMap { object in
            guard let pid = try? HAL.get(object, HAL.address(kAudioProcessPropertyPID), pid_t.self), pid > 0 else { return nil }
            let bundle = (try? HAL.getString(object, HAL.address(kAudioProcessPropertyBundleID))).flatMap { $0.isEmpty ? nil : $0 }
            return AudioProcessInfo(id: object, pid: pid, bundleID: bundle, name: displayName(pid: pid),
                                    isRunningOutput: flag(object, kAudioProcessPropertyIsRunningOutput),
                                    isRunningInput: flag(object, kAudioProcessPropertyIsRunningInput))
        }
    }

    /// Processes other than EquAudio that currently run audio output.
    public static func playingProcesses() -> [AudioProcessInfo] {
        let own = getpid()
        return all().filter { $0.isRunningOutput && $0.pid != own }
    }

    /// EquAudio's own process object. A global tap must exclude it, otherwise our output would be
    /// captured again (feedback). Nil if the HAL cannot resolve it.
    public static func ownProcessObjectID() -> AudioObjectID? { processObjectID(pid: getpid()) }

    /// kAudioHardwarePropertyTranslatePIDToProcessObject; nil if the process is not an audio client.
    public static func processObjectID(pid: pid_t) -> AudioObjectID? {
        guard let object = try? HAL.get(HAL.systemObject, HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject),
                                        qualifier: pid, AudioObjectID.self),
              object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// Process objects whose bundle identifier starts with `prefix` (case-insensitive), e.g. other
    /// EquAudio instances that must also be excluded from the tap.
    public static func processObjectIDs(bundleIDPrefix prefix: String) -> [AudioObjectID] {
        let lowered = prefix.lowercased()
        return processObjectIDs().filter { object in
            guard let bundle = try? HAL.getString(object, HAL.address(kAudioProcessPropertyBundleID)) else { return false }
            return bundle.lowercased().hasPrefix(lowered)
        }
    }

    /// Does any process other than EquAudio run audio output right now? Cheap: one HAL read per process.
    public static func anyOtherProcessPlaying() -> Bool {
        let own = ownProcessObjectID()
        return processObjectIDs().contains { $0 != own && flag($0, kAudioProcessPropertyIsRunningOutput) }
    }

    public static func processObjectIDs() -> [AudioObjectID] {
        (try? HAL.getArray(HAL.systemObject, HAL.address(kAudioHardwarePropertyProcessObjectList), AudioObjectID.self)) ?? []
    }

    /// NSRunningApplication's localized name, else the BSD process name, else "pid N".
    public static func displayName(pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName, !name.isEmpty { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        return "pid \(pid)"
    }

    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        ((try? HAL.get(object, HAL.address(selector), UInt32.self)) ?? 0) != 0
    }
}
