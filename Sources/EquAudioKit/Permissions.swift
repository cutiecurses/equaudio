import AppKit
import Foundation

/// System Audio Recording permission (TCC service kTCCServiceAudioCapture), needed to read process taps.
public enum AudioCapturePermission {
    case authorized, denied, notDetermined, unknown

    /// Uses the TCC preflight SPI (the same one other tap apps use); there is no public API for this service.
    /// After an ad-hoc rebuild the code signature changes, so this can say notDetermined until the user approves again.
    public static func status() -> AudioCapturePermission {
        guard let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(h, "TCCAccessPreflight") else { return .unknown }
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        switch unsafeBitCast(sym, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    public static func openSystemSettings() {
        for s in ["x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                  "x-apple.systempreferences:com.apple.preference.security?Privacy"] {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}
