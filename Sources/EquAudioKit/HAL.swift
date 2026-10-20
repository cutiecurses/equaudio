import CoreAudio
import Foundation

// Typed access to Core Audio HAL object properties.
//
// Every call here is a synchronous request to coreaudiod. Use them from a control thread (the
// EngineController's queue, the UI for occasional reads), never from the audio thread.

// MARK: - Errors

/// A failed HAL call: what was attempted, the OSStatus and, for well-known codes, the usual cause.
public struct HALError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    public let status: OSStatus
    /// Human-readable operation, e.g. "AudioDeviceStart" or "Get 'nsrt' (global) of object 82".
    public let operation: String

    public init(_ status: OSStatus, _ operation: String) {
        self.status = status
        self.operation = operation
    }

    /// The status as "'nope' (1852797029)" when it is a printable four-character code, else "-50".
    public var code: String { Self.codeDescription(status) }

    /// Likely cause of a well-known HAL code; nil for other codes.
    public var hint: String? { Self.hint(for: status) }

    /// The object no longer exists (device unplugged, audio service restarted). Expected while tearing
    /// down a route after a device vanished.
    public var isObjectGone: Bool {
        status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError
            || status == kAudioHardwareBadStreamError
    }

    public var description: String {
        let base = "\(operation) failed: \(code)"
        guard let hint else { return base }
        return "\(base). \(hint)"
    }

    public var errorDescription: String? { description }

    /// Four-character-code-or-number rendering of an OSStatus.
    public static func codeDescription(_ status: OSStatus) -> String {
        if let fourCC = HAL.printableFourCC(UInt32(bitPattern: status)) { return "'\(fourCC)' (\(status))" }
        return "\(status)"
    }

    public static func hint(for status: OSStatus) -> String? {
        switch status {
        case kAudioHardwareIllegalOperationError:
            return "The audio system refused the operation in the current state (device busy or in exclusive use, or missing permission)."
        case kAudioHardwareBadObjectError:
            return "The audio object no longer exists (device disconnected or the audio service restarted)."
        case kAudioHardwareBadDeviceError:
            return "The audio device is not available (disconnected or being reset)."
        case kAudioHardwareUnknownPropertyError:
            return "The device does not support this property."
        case kAudioHardwareBadPropertySizeError:
            return "The property data has an unexpected size (driver bug or API misuse)."
        case kAudioHardwareNotRunningError:
            return "The audio hardware or device is not running."
        case kAudioHardwareUnspecifiedError:
            return "Unspecified audio system error; the audio service may be restarting."
        case kAudioHardwareUnsupportedOperationError:
            return "The device does not support this operation."
        case kAudioHardwareBadStreamError:
            return "The audio stream no longer exists."
        case kAudioHardwareNotReadyError:
            return "The audio system is not ready yet; try again shortly."
        case kAudioDeviceUnsupportedFormatError:
            return "The device does not support the requested format."
        case kAudioDevicePermissionsError:
            return "Another application has exclusive (hog mode) access to the device."
        case OSStatus(paramErr):
            return "Invalid parameter."
        default:
            return nil
        }
    }
}

// MARK: - Property access

public enum HAL {
    /// The HAL system object (device lists, defaults, process objects).
    public static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    public static func address(_ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Throws `HALError` for any status other than noErr.
    public static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        if status != noErr { throw HALError(status, operation()) }
    }

    public static func hasProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(object, &addr)
    }

    public static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> Bool {
        var addr = address
        var settable: DarwinBoolean = false
        try check(AudioObjectIsPropertySettable(object, &addr, &settable), "IsSettable \(describe(address)) of object \(object)")
        return settable.boolValue
    }

    /// Size in bytes of the property's current value.
    public static func dataSize(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> Int {
        var addr = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "GetSize \(describe(address)) of object \(object)")
        return Int(size)
    }

    /// Reads a fixed-size value (UInt32, Float32, Float64, pid_t, AudioObjectID, AudioStreamBasicDescription,
    /// AudioValueRange, ...). Storage is zero-initialised, so a short reply leaves trailing fields zero.
    public static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                                               _ type: T.Type = T.self) throws -> T {
        try withUnsafeTemporaryAllocation(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            var addr = address
            var size = UInt32(MemoryLayout<T>.size)
            try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw.baseAddress!),
                      "Get \(describe(address)) of object \(object)")
            return raw.load(as: T.self)
        }
    }

    /// Reads a fixed-size value using a qualifier (e.g. a pid_t for kAudioHardwarePropertyTranslatePIDToProcessObject).
    public static func get<T: BitwiseCopyable, Q: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                                                                    qualifier: Q, _ type: T.Type = T.self) throws -> T {
        var q = qualifier
        return try withUnsafeTemporaryAllocation(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            var addr = address
            var size = UInt32(MemoryLayout<T>.size)
            let status = withUnsafeMutableBytes(of: &q) { qualifierBytes in
                AudioObjectGetPropertyData(object, &addr, UInt32(qualifierBytes.count), qualifierBytes.baseAddress,
                                           &size, raw.baseAddress!)
            }
            try check(status, "Get \(describe(address)) of object \(object)")
            return raw.load(as: T.self)
        }
    }

    /// Reads a variable-length array property (device lists, process lists, value ranges, channel pairs).
    public static func getArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                                                    _ type: T.Type = T.self) throws -> [T] {
        let stride = MemoryLayout<T>.stride
        let count = try dataSize(object, address) / stride
        if count == 0 { return [] }
        var addr = address
        var size = UInt32(count * stride)
        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = 0
            try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer.baseAddress!),
                      "Get \(describe(address)) of object \(object)")
            // Only elements the HAL fully wrote count; the list may have shrunk since the size query.
            initialized = min(count, Int(size) / stride)
        }
    }

    /// Reads a CFString property. The HAL returns these retained (+1); ownership is taken here.
    public static func getString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var addr = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        try check(status, "Get \(describe(address)) of object \(object)")
        return value?.takeRetainedValue() as String? ?? ""
    }

    /// Translates a CFString qualifier into an object ID (e.g. kAudioHardwarePropertyTranslateUIDToDevice).
    /// Returns nil when the HAL answers kAudioObjectUnknown.
    public static func translate(_ string: String, _ address: AudioObjectPropertyAddress,
                                 on object: AudioObjectID = HAL.systemObject) throws -> AudioObjectID? {
        var addr = address
        var qualifier = string as CFString
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { q in
            AudioObjectGetPropertyData(object, &addr, UInt32(MemoryLayout<CFString>.size), q, &size, &result)
        }
        try check(status, "Translate \(describe(address))")
        return result == kAudioObjectUnknown ? nil : result
    }

    public static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var addr = address
        var v = value
        let status = withUnsafeMutableBytes(of: &v) { bytes in
            AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(bytes.count), bytes.baseAddress!)
        }
        try check(status, "Set \(describe(address)) of object \(object)")
    }

    // MARK: Composite reads

    public static func streamFormat(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> AudioStreamBasicDescription {
        try get(object, address, AudioStreamBasicDescription.self)
    }

    /// AudioValueRange lists, e.g. kAudioDevicePropertyAvailableNominalSampleRates.
    public static func valueRanges(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [AudioValueRange] {
        try getArray(object, address, AudioValueRange.self)
    }

    /// Channels per stream from kAudioDevicePropertyStreamConfiguration, in the order an IOProc sees
    /// the buffers (e.g. [6, 2] for a 6-channel device input followed by a stereo tap).
    public static func streamChannelCounts(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
        let addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        let byteCount = try dataSize(device, addr)
        let headerSize = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 8
        if byteCount < headerSize { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        var a = addr
        var size = UInt32(byteCount)
        try check(AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw), "Get \(describe(addr)) of object \(device)")
        // Never trust mNumberBuffers beyond what was actually returned.
        let available = (Int(size) - headerSize) / MemoryLayout<AudioBuffer>.stride
        let declared = Int(raw.load(as: UInt32.self))
        let count = max(0, min(declared, available))
        return (0..<count).map { index in
            let buffer = raw.load(fromByteOffset: headerSize + index * MemoryLayout<AudioBuffer>.stride, as: AudioBuffer.self)
            return Int(buffer.mNumberChannels)
        }
    }

    // MARK: Process-wide setup

    private static let notificationThreadOnce: Void = {
        // Since macOS 10.6 the HAL attaches its notification handling to the main run loop unless told
        // otherwise. A NULL run loop makes it use its own thread, so device-change notifications keep
        // flowing while the main thread is busy or blocked (e.g. waiting for a synchronous shutdown).
        var addr = address(kAudioHardwarePropertyRunLoop)
        var runLoop: CFRunLoop? = nil
        _ = AudioObjectSetPropertyData(systemObject, &addr, 0, nil, UInt32(MemoryLayout<CFRunLoop?>.size), &runLoop)
    }()

    /// Makes the HAL deliver its internal notifications on its own thread (idempotent, process-wide).
    public static func useDedicatedNotificationThread() { _ = notificationThreadOnce }

    // MARK: Formatting

    /// The four printable ASCII characters of a code, or nil.
    public static func printableFourCC(_ value: UInt32) -> String? {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> UInt32($0)) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "'nsrt'" for printable codes, else the number.
    public static func fourCC(_ value: UInt32) -> String {
        printableFourCC(value).map { "'\($0)'" } ?? "\(value)"
    }

    /// "'nsrt' (outp, element 0)": compact address description for logs and errors.
    public static func describe(_ address: AudioObjectPropertyAddress) -> String {
        let scope = printableFourCC(address.mScope) ?? "\(address.mScope)"
        if address.mElement == kAudioObjectPropertyElementMain {
            return "\(fourCC(address.mSelector)) (\(scope))"
        }
        return "\(fourCC(address.mSelector)) (\(scope), element \(address.mElement))"
    }
}

// MARK: - Property listener

/// Observes one property address of one HAL object. The handler runs on `queue` with the changed
/// addresses. The listener is removed by `invalidate()` or when the object is deallocated; removal
/// after the object vanished is harmless.
public final class HALPropertyListener: @unchecked Sendable {
    public let object: AudioObjectID
    public let address: AudioObjectPropertyAddress

    private let queue: DispatchQueue
    // Kept as a block value so that exactly the same block is passed to Add and Remove.
    private let block: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var registered = false

    public init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
                handler: @escaping ([AudioObjectPropertyAddress]) -> Void) throws {
        self.object = object
        self.address = address
        self.queue = queue
        block = { count, addresses in
            handler(Array(UnsafeBufferPointer(start: addresses, count: Int(count))))
        }
        var addr = address
        try HAL.check(AudioObjectAddPropertyListenerBlock(object, &addr, queue, block),
                      "Add listener \(HAL.describe(address)) to object \(object)")
        registered = true
    }

    public var isRegistered: Bool { lock.withLock { registered } }

    /// Removes the listener (idempotent). Blocks already queued may still run afterwards, so handlers
    /// must tolerate stale notifications.
    public func invalidate() {
        let wasRegistered = lock.withLock { () -> Bool in
            defer { registered = false }
            return registered
        }
        guard wasRegistered else { return }
        var addr = address
        _ = AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
    }

    deinit { invalidate() }
}
