import CoreAudio
import EquCore
import Foundation

// One processing route:
//
//   other processes' audio -> private process tap (muted while read) ┐
//   physical output device (clock) + optional mirror device ─────────┴> private aggregate -> IOProc
//
// The IOProc is EquCore's C++ equ_engine_ioproc with the engine as client data, so no Swift runs on
// the audio thread. Verified on this Mac by the Phase-1 PoC: inside the aggregate the tap arrives at
// the aggregate's sample rate (96 kHz) even when the tap format says 48 kHz, and input streams are
// ordered sub-device inputs first, tap streams last (e.g. [6, 2]).

/// What the process tap captures.
public enum TapTarget: Hashable, Sendable {
    /// Every process except these process objects. EngineController always adds EquAudio's own
    /// process object and refuses to start if it cannot resolve it (fail closed: feedback).
    case global(excluding: [AudioObjectID])
    /// A stereo mixdown of only these process objects (self-test).
    case processes([AudioObjectID])
}

// MARK: - Errors

/// A failed routing step with the HAL error behind it and what the user can do.
public struct RouteError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    public enum Step: String, Hashable, Sendable {
        case permission
        case resolveOutput
        case resolveOwnProcess
        case createTap
        case createAggregate
        case waitForAggregate
        case readFormat
        case resolveLayout
        case createIOProc
        case prepareEngine
        case startIO
        /// Detected while running: IO stopped abnormally or the buffer layout stopped matching.
        case routeHealth

        public var title: String {
            switch self {
            case .permission: return "Check System Audio Recording permission"
            case .resolveOutput: return "Choose an output device"
            case .resolveOwnProcess: return "Identify EquAudio's own audio process"
            case .createTap: return "Create the system audio tap"
            case .createAggregate: return "Create the private aggregate device"
            case .waitForAggregate: return "Wait for the aggregate device"
            case .readFormat: return "Read the aggregate device format"
            case .resolveLayout: return "Map the tap and output channels"
            case .createIOProc: return "Create the audio callback"
            case .prepareEngine: return "Prepare the DSP engine"
            case .startIO: return "Start audio IO"
            case .routeHealth: return "Keep audio IO running"
            }
        }

        public var hint: String {
            switch self {
            case .permission:
                return "Allow EquAudio in System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only, then turn processing on again."
            case .resolveOutput:
                return "Connect headphones or speakers, or choose another output device."
            case .resolveOwnProcess:
                return "EquAudio does not start unless it can exclude its own output from the capture (otherwise it would capture itself: feedback). Quit and reopen EquAudio; if that does not help, restart the Mac."
            case .createTap:
                return "System audio capture needs macOS 14.2 or later and the System Audio Recording permission."
            case .createAggregate, .waitForAggregate, .createIOProc:
                return "The audio system could not combine the output device with the system audio tap. Try again or choose another output device; quitting other audio routing apps can help."
            case .readFormat, .resolveLayout:
                return "The output device reported an unexpected channel layout or sample rate. Choose another output device."
            case .prepareEngine:
                return "The output device runs at an unsupported sample rate (8 to 384 kHz are supported). Change its format in Audio MIDI Setup."
            case .startIO:
                return "Another app may be using the device exclusively or tapping it at the same time. Quit audio routing utilities and try again."
            case .routeHealth:
                return "Audio IO stopped unexpectedly; EquAudio rebuilds the route automatically."
            }
        }
    }

    public let step: Step
    public let halError: HALError?
    public let detail: String?
    /// Retrying cannot help (permission denied, no output device); wait for the user or a device change.
    public let isPermanent: Bool

    public init(_ step: Step, halError: HALError? = nil, detail: String? = nil, isPermanent: Bool = false) {
        self.step = step
        self.halError = halError
        self.detail = detail
        self.isPermanent = isPermanent
    }

    /// "Create the private aggregate device failed ('nope' (1852797029)): <detail>"
    public var summary: String {
        var text = "\(step.title) failed"
        if let halError { text += " (\(halError.code))" }
        if let detail { text += ": \(detail)" }
        return text
    }

    public var hint: String {
        if let specific = halError?.hint { return "\(step.hint) (\(specific))" }
        return step.hint
    }

    public var description: String { "\(summary). \(hint)" }
    public var errorDescription: String? { description }
}

// MARK: - IO layout (pure)

/// Maps the aggregate's stream configuration to the EquIOLayout the engine's IOProc uses.
public enum IOLayoutResolver {
    /// - Parameters:
    ///   - inputStreamChannels: channels per input stream of the aggregate, IOProc order.
    ///   - outputStreamChannels: channels per output stream: the main device's streams, then the mirror's.
    ///   - tapStreamCount: number of tap streams; they are the LAST input streams. The first is used.
    ///   - tapChannels: channels of the tap stream (2 for a stereo mixdown, 1 for mono).
    ///   - outputStereo: 0-based device channels of the main device's stereo pair.
    ///   - mirror: index of the mirror device's first output stream and its 0-based stereo channels.
    /// - Returns: nil when the configuration is inconsistent (missing or mismatched tap stream,
    ///   channels outside their device's streams).
    public static func resolve(inputStreamChannels: [Int], outputStreamChannels: [Int], tapStreamCount: Int = 1,
                               tapChannels: Int, outputStereo: (left: Int, right: Int),
                               mirror: (firstOutputStream: Int, left: Int, right: Int)? = nil) -> EquIOLayout? {
        guard tapStreamCount >= 1, tapChannels >= 1, inputStreamChannels.count >= tapStreamCount,
              !inputStreamChannels.contains(where: { $0 < 0 }), !outputStreamChannels.contains(where: { $0 < 0 }) else { return nil }
        let tapIndex = inputStreamChannels.count - tapStreamCount
        guard inputStreamChannels[tapIndex...].allSatisfy({ $0 == tapChannels }) else { return nil }

        let mainStreams = 0..<(mirror?.firstOutputStream ?? outputStreamChannels.count)
        guard !mainStreams.isEmpty, mainStreams.upperBound <= outputStreamChannels.count,
              let left = locate(channel: outputStereo.left, in: outputStreamChannels, streams: mainStreams),
              let right = locate(channel: outputStereo.right, in: outputStreamChannels, streams: mainStreams) else { return nil }

        var layout = EquIOLayout()
        layout.inputBuffer = UInt32(tapIndex)
        layout.outputLeftBuffer = UInt32(left.buffer)
        layout.outputLeftChannel = UInt32(left.channel)
        layout.outputRightBuffer = UInt32(right.buffer)
        layout.outputRightChannel = UInt32(right.channel)
        layout.mirrorEnabled = false
        if let mirror {
            let mirrorStreams = mirror.firstOutputStream..<outputStreamChannels.count
            guard !mirrorStreams.isEmpty,
                  let mirrorLeft = locate(channel: mirror.left, in: outputStreamChannels, streams: mirrorStreams),
                  let mirrorRight = locate(channel: mirror.right, in: outputStreamChannels, streams: mirrorStreams) else { return nil }
            layout.mirrorEnabled = true
            layout.mirrorLeftBuffer = UInt32(mirrorLeft.buffer)
            layout.mirrorLeftChannel = UInt32(mirrorLeft.channel)
            layout.mirrorRightBuffer = UInt32(mirrorRight.buffer)
            layout.mirrorRightChannel = UInt32(mirrorRight.channel)
        }
        return layout
    }

    /// Converts a 0-based channel of the device owning `streams` into (buffer index, channel offset)
    /// by walking the streams' channel counts.
    public static func locate(channel: Int, in streamChannels: [Int], streams: Range<Int>) -> (buffer: Int, channel: Int)? {
        guard channel >= 0, streams.lowerBound >= 0, streams.upperBound <= streamChannels.count else { return nil }
        var remaining = channel
        for index in streams {
            if remaining < streamChannels[index] { return (index, remaining) }
            remaining -= streamChannels[index]
        }
        return nil
    }

    /// 0-based stereo pair from the device's 1-based preferred pair: the preferred pair when valid,
    /// else channels 0/1; a mono device gets (0, 0). Nil when the device has no channels.
    public static func stereoPair(preferred: (left: Int, right: Int), channelCount: Int) -> (left: Int, right: Int)? {
        guard channelCount >= 1 else { return nil }
        if channelCount == 1 { return (0, 0) }
        let left = preferred.left - 1
        let right = preferred.right - 1
        let valid = 0..<channelCount
        if valid.contains(left), valid.contains(right), left != right { return (left, right) }
        return (0, 1)
    }

    /// "tap=in[1] L=out[0].0 R=out[0].1 mirror L=out[1].0 R=out[1].1" for logs and diagnostics.
    public static func describe(_ layout: EquIOLayout) -> String {
        var text = "tap=in[\(layout.inputBuffer)] L=out[\(layout.outputLeftBuffer)].\(layout.outputLeftChannel) R=out[\(layout.outputRightBuffer)].\(layout.outputRightChannel)"
        if layout.voiceEnabled { text += " voice=in[\(layout.voiceBuffer)].\(layout.voiceChannel)" }
        if layout.mirrorEnabled {
            text += " mirror L=out[\(layout.mirrorLeftBuffer)].\(layout.mirrorLeftChannel) R=out[\(layout.mirrorRightBuffer)].\(layout.mirrorRightChannel)"
        }
        return text
    }
}

// MARK: - Router

/// What to build.
public struct RouteRequest: Sendable {
    /// Physical output device; it is the aggregate's clock.
    public var output: AudioDeviceInfo
    /// Optional second sub-device that receives the same processed stereo signal (e.g. a loopback
    /// device a screen recorder captures).
    public var mirror: AudioDeviceInfo?
    public var bufferFrames: Int
    public var tapTarget: TapTarget
    /// `.mutedWhenTapped` for the main enhancer route (the original is replaced by the processed copy);
    /// `.unmuted` for the virtual-mic feed, which only copies audio and must not silence anything.
    public var tapMuteBehavior: CATapMuteBehavior
    /// Optional microphone (input device) added to the aggregate; the engine mixes its first channel into the
    /// output. Needs the Microphone permission (NSMicrophoneUsageDescription).
    public var voice: AudioDeviceInfo?

    public init(output: AudioDeviceInfo, mirror: AudioDeviceInfo? = nil, bufferFrames: Int, tapTarget: TapTarget,
                tapMuteBehavior: CATapMuteBehavior = .mutedWhenTapped, voice: AudioDeviceInfo? = nil) {
        self.voice = voice
        self.output = output
        self.mirror = mirror
        self.bufferFrames = bufferFrames
        self.tapTarget = tapTarget
        self.tapMuteBehavior = tapMuteBehavior
    }
}

/// A built route as the HAL actually configured it.
public struct BuiltRoute: Sendable {
    public let tapID: AudioObjectID
    public let tapUUID: UUID
    /// The tap's own format (informational: inside the aggregate it arrives at `sampleRate`).
    public let tapFormat: AudioStreamBasicDescription
    public let aggregateID: AudioObjectID
    public let aggregateUID: String
    /// The aggregate's nominal sample rate: the rate the IOProc runs at and the engine is prepared for.
    public let sampleRate: Double
    /// Actual IO buffer size after clamping to the aggregate's range.
    public let bufferFrames: Int
    public let inputStreams: [Int]
    public let outputStreams: [Int]
    public let layout: EquIOLayout
    /// HAL-reported latencies; `engineLatencyFrames` is filled in once the engine is prepared.
    public let latency: LatencyInfo
    /// Whether the non-tap input streams could be disabled for the IOProc (no microphone IO).
    public let inputStreamsDisabled: Bool
}

/// Builds and tears down one route. Not thread-safe: EngineController confines it to its control
/// queue. One instance builds at most one route; teardown is idempotent and also runs on deinit.
public final class ProcessTapRouter {
    public static let aggregateUIDPrefix = "com.equaudio.aggregate."
    public static let aggregateName = "EquAudio"
    public static let tapName = "EquAudio Tap"

    public enum State: Sendable { case idle, built, running, tornDown }

    public private(set) var state: State = .idle
    public private(set) var route: BuiltRoute?
    public private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)

    private let engine: DSPEngine
    private let log: LogStore
    private var procID: AudioDeviceIOProcID?
    private static let category = "Routing"

    /// The router keeps the engine alive until the IOProc that uses it is destroyed.
    public init(engine: DSPEngine, log: LogStore = .shared) {
        self.engine = engine
        self.log = log
    }

    deinit { teardown() }

    /// Creates the tap, the private aggregate and the IOProc, without starting IO. Prepare the engine
    /// for `sampleRate` and set `layout` before `start()`. On failure everything created is destroyed.
    public func build(_ request: RouteRequest) throws -> BuiltRoute {
        guard state == .idle else { throw RouteError(.createTap, detail: "This router was already used") }
        do {
            let built = try performBuild(request)
            route = built
            state = .built
            return built
        } catch {
            teardown()
            throw error
        }
    }

    /// Starts IO (AudioDeviceStart). On failure the route is torn down.
    public func start() throws {
        guard state == .built, let procID else { throw RouteError(.startIO, detail: "The route is not built") }
        let status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            teardown()
            throw RouteError(.startIO, halError: HALError(status, "AudioDeviceStart"))
        }
        state = .running
    }

    /// Strictly reverse order: stop IO, destroy the IOProc, the aggregate, then the tap. Idempotent and
    /// tolerant of objects that already vanished (unplugged device, restarted audio service).
    public func teardown() {
        if aggregateID != kAudioObjectUnknown, let procID {
            if state == .running { report(AudioDeviceStop(aggregateID, procID), "AudioDeviceStop") }
            report(AudioDeviceDestroyIOProcID(aggregateID, procID), "AudioDeviceDestroyIOProcID")
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            report(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            report(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
            tapID = kAudioObjectUnknown
        }
        if state != .idle || route != nil { state = .tornDown }
    }

    // MARK: Build steps

    private func performBuild(_ request: RouteRequest) throws -> BuiltRoute {
        let output = request.output
        let mirror = request.mirror
        let voice = request.voice

        // Sub-device stream layouts, read before the aggregate exists.
        let mainInputs = AudioDeviceCatalog.inputStreamChannelCounts(of: output.id)
        let mainOutputs = AudioDeviceCatalog.outputStreamChannelCounts(of: output.id)
        guard mainOutputs.reduce(0, +) > 0 else {
            throw RouteError(.resolveLayout, detail: "'\(output.name)' reports no output channels")
        }
        let mirrorInputs = mirror.map { AudioDeviceCatalog.inputStreamChannelCounts(of: $0.id) } ?? []
        let mirrorOutputs = mirror.map { AudioDeviceCatalog.outputStreamChannelCounts(of: $0.id) } ?? []
        let voiceInputs = voice.map { AudioDeviceCatalog.inputStreamChannelCounts(of: $0.id) } ?? []
        if let voice, voiceInputs.reduce(0, +) == 0 {
            throw RouteError(.resolveLayout, detail: "Microphone '\(voice.name)' reports no input channels")
        }
        if let mirror, mirrorOutputs.reduce(0, +) == 0 {
            throw RouteError(.resolveLayout, detail: "Mirror device '\(mirror.name)' reports no output channels")
        }

        // 1. Private process tap, muted only while EquAudio reads it.
        let description: CATapDescription
        switch request.tapTarget {
        case .global(let excluded):
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        case .processes(let included):
            guard !included.isEmpty else { throw RouteError(.createTap, detail: "No processes to tap") }
            description = CATapDescription(stereoMixdownOfProcesses: included)
        }
        let tapUUID = UUID()
        description.uuid = tapUUID
        description.name = Self.tapName
        description.isPrivate = true
        description.muteBehavior = request.tapMuteBehavior
        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
            throw RouteError(.createTap, halError: HALError(tapStatus, "AudioHardwareCreateProcessTap"))
        }
        tapID = newTap

        var tapFormat = AudioStreamBasicDescription()
        do {
            tapFormat = try HAL.streamFormat(newTap, HAL.address(kAudioTapPropertyFormat))
        } catch {
            log.warning(Self.category, "Could not read the tap format (\(error)); assuming stereo")
        }
        let tapChannels = tapFormat.mChannelsPerFrame > 0 ? Int(tapFormat.mChannelsPerFrame) : 2

        // 2. Private aggregate. The output device is the clock (no drift compensation); the mirror and
        //    the tap are drift-compensated against it.
        let aggregateUID = Self.aggregateUIDPrefix + tapUUID.uuidString
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceDriftCompensationKey: 0]]
        if let mirror {
            subDevices.append([kAudioSubDeviceUIDKey: mirror.uid, kAudioSubDeviceDriftCompensationKey: 1])
        }
        if let voice {
            subDevices.append([kAudioSubDeviceUIDKey: voice.uid, kAudioSubDeviceDriftCompensationKey: 1])
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: 1]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregate)
        guard aggregateStatus == noErr, newAggregate != kAudioObjectUnknown else {
            throw RouteError(.createAggregate, halError: HALError(aggregateStatus, "AudioHardwareCreateAggregateDevice"))
        }
        aggregateID = newAggregate

        // 3. Wait until the aggregate is alive and publishes the sub-device streams plus the tap.
        let streams = try waitForStreams(of: newAggregate, expectedInputs: mainInputs + mirrorInputs + voiceInputs + [tapChannels],
                                         expectedOutputs: mainOutputs + mirrorOutputs, mainOutputs: mainOutputs,
                                         tapChannels: tapChannels)

        // 4. IO buffer size, clamped to what the aggregate allows; the actual value is read back.
        let requested = max(1, request.bufferFrames)
        var target = requested
        if let range = AudioDeviceCatalog.bufferFrameSizeRange(of: newAggregate) {
            target = min(max(requested, range.lowerBound), range.upperBound)
        }
        do {
            try HAL.set(newAggregate, HAL.address(kAudioDevicePropertyBufferFrameSize), UInt32(target))
        } catch {
            log.warning(Self.category, "Could not set the IO buffer to \(target) frames: \(error)")
        }
        let actualBuffer = (try? HAL.get(newAggregate, HAL.address(kAudioDevicePropertyBufferFrameSize), UInt32.self))
            .map { Int($0) } ?? target

        // 5. Sample rate: the aggregate's actual rate (follows the output device, its clock).
        guard let sampleRate = AudioDeviceCatalog.nominalSampleRate(of: newAggregate), (8_000...384_000).contains(sampleRate) else {
            throw RouteError(.readFormat, detail: "The aggregate reports an invalid sample rate")
        }
        if output.nominalSampleRate > 0, abs(output.nominalSampleRate - sampleRate) > 0.5 {
            log.warning(Self.category, "Aggregate runs at \(Int(sampleRate)) Hz while '\(output.name)' reported \(Int(output.nominalSampleRate)) Hz")
        }

        // 6. Buffer layout: tap = last input stream; output pair = the device's preferred stereo channels.
        guard let outputPair = IOLayoutResolver.stereoPair(preferred: AudioDeviceCatalog.preferredStereoChannels(of: output.id),
                                                           channelCount: mainOutputs.reduce(0, +)) else {
            throw RouteError(.resolveLayout, detail: "'\(output.name)' has no output channels")
        }
        var mirrorSpec: (firstOutputStream: Int, left: Int, right: Int)?
        if let mirror {
            guard let pair = IOLayoutResolver.stereoPair(preferred: AudioDeviceCatalog.preferredStereoChannels(of: mirror.id),
                                                         channelCount: mirrorOutputs.reduce(0, +)) else {
                throw RouteError(.resolveLayout, detail: "Mirror device '\(mirror.name)' has no output channels")
            }
            mirrorSpec = (mainOutputs.count, pair.left, pair.right)
        }
        guard var layout = IOLayoutResolver.resolve(inputStreamChannels: streams.inputs, outputStreamChannels: streams.outputs,
                                                    tapStreamCount: 1, tapChannels: tapChannels,
                                                    outputStereo: outputPair, mirror: mirrorSpec) else {
            throw RouteError(.resolveLayout, detail: "input streams \(streams.inputs), output streams \(streams.outputs), tap \(tapChannels) ch, stereo pair \(outputPair)")
        }

        // Voice: the microphone's first input stream follows the output device's and the mirror's input streams.
        var keepInputs: Set<Int> = [Int(layout.inputBuffer)]
        if voice != nil {
            let first = mainInputs.count + mirrorInputs.count
            guard first < streams.inputs.count - 1 else {
                throw RouteError(.resolveLayout, detail: "microphone stream missing: input streams \(streams.inputs)")
            }
            layout.voiceEnabled = true
            layout.voiceBuffer = UInt32(first)
            layout.voiceChannel = 0
            keepInputs.insert(first)
        }

        // 7. IOProc: EquCore's C callback with the engine as client data.
        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcID(newAggregate, DSPEngine.ioProc, UnsafeMutableRawPointer(engine.handle), &newProc)
        guard procStatus == noErr, let newProc else {
            throw RouteError(.createIOProc, halError: HALError(procStatus, "AudioDeviceCreateIOProcID"))
        }
        procID = newProc

        // 8. Only the tap stream is read: disabling the sub-devices' input streams keeps the HAL from
        //    running (and asking permission for) any microphone. Best effort.
        let inputsDisabled = disableNonTapInputStreams(aggregate: newAggregate, procID: newProc,
                                                       streamCount: streams.inputs.count, keep: keepInputs)

        let latency = LatencyInfo(
            sampleRate: sampleRate, bufferFrames: actualBuffer,
            outputDeviceLatency: frames(output.id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
            outputSafetyOffset: frames(output.id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput),
            outputStreamLatency: outputStreamLatency(of: output.id, streamIndex: Int(layout.outputLeftBuffer)),
            inputSafetyOffset: frames(newAggregate, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput),
            inputLatency: frames(newAggregate, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput),
            engineLatencyFrames: 0, measuredIOLatencyFrames: nil)

        let formatText = tapFormat.mSampleRate > 0 ? "\(Int(tapFormat.mSampleRate)) Hz \(tapChannels) ch" : "\(tapChannels) ch"
        log.info(Self.category, "Route built: tap \(newTap) (\(formatText)) + '\(output.name)'\(mirror.map { " + mirror '\($0.name)'" } ?? "") -> aggregate \(newAggregate) at \(Int(sampleRate)) Hz, buffer \(actualBuffer) (requested \(requested)), in \(streams.inputs) out \(streams.outputs), \(IOLayoutResolver.describe(layout))")

        return BuiltRoute(tapID: newTap, tapUUID: tapUUID, tapFormat: tapFormat, aggregateID: newAggregate,
                          aggregateUID: aggregateUID, sampleRate: sampleRate, bufferFrames: actualBuffer,
                          inputStreams: streams.inputs, outputStreams: streams.outputs, layout: layout,
                          latency: latency, inputStreamsDisabled: inputsDisabled)
    }

    /// Polls (10 ms, up to 2 s) until the new aggregate is alive with exactly the expected streams.
    /// A configuration that differs but still ends with the tap and starts with the main device's
    /// outputs is accepted with a warning; anything else fails.
    private func waitForStreams(of aggregate: AudioObjectID, expectedInputs: [Int], expectedOutputs: [Int],
                                mainOutputs: [Int], tapChannels: Int) throws -> (inputs: [Int], outputs: [Int]) {
        let deadline = DispatchTime.now() + .seconds(2)
        var alive = false
        var inputs: [Int] = []
        var outputs: [Int] = []
        while true {
            alive = AudioDeviceCatalog.isAlive(aggregate)
            inputs = (try? HAL.streamChannelCounts(aggregate, scope: kAudioObjectPropertyScopeInput)) ?? []
            outputs = (try? HAL.streamChannelCounts(aggregate, scope: kAudioObjectPropertyScopeOutput)) ?? []
            if alive, inputs == expectedInputs, outputs == expectedOutputs { return (inputs, outputs) }
            if DispatchTime.now() >= deadline { break }
            usleep(10_000)
        }
        if alive, inputs.last == tapChannels, outputs.count >= expectedOutputs.count,
           Array(outputs.prefix(mainOutputs.count)) == mainOutputs {
            log.warning(Self.category, "Aggregate streams differ from the sub-devices: in \(inputs) (expected \(expectedInputs)), out \(outputs) (expected \(expectedOutputs)); using them")
            return (inputs, outputs)
        }
        throw RouteError(.waitForAggregate,
                         detail: "alive=\(alive), input streams \(inputs) (expected \(expectedInputs)), output streams \(outputs) (expected \(expectedOutputs))")
    }

    /// Sets kAudioDevicePropertyIOProcStreamUsage so that only the tap's input stream is enabled.
    private func disableNonTapInputStreams(aggregate: AudioObjectID, procID: AudioDeviceIOProcID,
                                           streamCount: Int, keep: Set<Int>) -> Bool {
        guard streamCount > 1, keep.allSatisfy({ (0..<streamCount).contains($0) }) else { return true }
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn) ?? 12
        let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mNumberStreams) ?? 8
        let procOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mIOProc) ?? 0
        let byteCount = max(flagsOffset + streamCount * MemoryLayout<UInt32>.stride, MemoryLayout<AudioHardwareIOProcStreamUsage>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        // With AudioDeviceCreateIOProcID the IOProcID identifies the IOProc in this structure.
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), toByteOffset: procOffset, as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(streamCount), toByteOffset: countOffset, as: UInt32.self)
        for index in 0..<streamCount {
            raw.storeBytes(of: keep.contains(index) ? 1 : 0, toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
        var addr = HAL.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregate, &addr, 0, nil, UInt32(byteCount), raw)
        if status != noErr {
            log.warning(Self.category, "Could not disable the \(streamCount - 1) non-tap input stream(s): \(HALError(status, "Set IOProc stream usage"))")
            return false
        }
        return true
    }

    private func frames(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> Int {
        (try? HAL.get(object, HAL.address(selector, scope: scope), UInt32.self)).map { Int($0) } ?? 0
    }

    /// kAudioStreamPropertyLatency of the device's output stream that carries the left channel.
    private func outputStreamLatency(of device: AudioObjectID, streamIndex: Int) -> Int {
        guard let streams = try? HAL.getArray(device, HAL.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
                                              AudioStreamID.self),
              streams.indices.contains(streamIndex) else { return 0 }
        return (try? HAL.get(streams[streamIndex], HAL.address(kAudioStreamPropertyLatency), UInt32.self)).map { Int($0) } ?? 0
    }

    private func report(_ status: OSStatus, _ operation: String) {
        guard status != noErr else { return }
        let error = HALError(status, operation)
        if error.isObjectGone {
            log.debug(Self.category, "\(operation): object already gone")
        } else {
            log.warning(Self.category, "Teardown: \(error)")
        }
    }
}
