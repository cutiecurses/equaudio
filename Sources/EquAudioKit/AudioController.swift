import CoreAudio
import EquCore
import Foundation

/// Estimated latencies of a route as reported by the HAL (frames at `sampleRate`).
public struct LatencyInfo: Equatable, Sendable {
    public var sampleRate: Double
    public var bufferFrames: Int
    public var outputDeviceLatency: Int
    public var outputSafetyOffset: Int
    public var outputStreamLatency: Int
    public var inputSafetyOffset: Int
    public var inputLatency: Int
    public var engineLatencyFrames: Int
    public var measuredIOLatencyFrames: Double?

    /// Estimate: input safety + buffer + output safety + device + stream latency + engine look-ahead.
    public var estimatedOutputMs: Double {
        guard sampleRate > 0 else { return 0 }
        let frames = inputSafetyOffset + bufferFrames + outputSafetyOffset + outputDeviceLatency + outputStreamLatency + engineLatencyFrames
        return Double(frames) / sampleRate * 1000
    }
}

/// Owns the engine and the live route (process tap -> private aggregate -> physical output).
/// Main-thread object: call from the main queue only. Rebuilds the route when devices change.
public final class AudioController {
    public enum Status: Equatable {
        case stopped, running, failed(String)
    }

    public let engine = DSPEngine()
    public let log: LogStore
    public private(set) var status: Status = .stopped { didSet { if status != oldValue { onChange?() } } }
    public private(set) var outputName = ""
    public private(set) var sampleRate: Double = 0
    public private(set) var latency: LatencyInfo?
    public private(set) var notice: String?
    public var onChange: (() -> Void)?
    public var output: OutputSelection = .systemDefault
    public var bufferFrames = 512

    private var router: ProcessTapRouter?
    private var listeners: [HALPropertyListener] = []
    private var debounce: DispatchWorkItem?
    private var wanted = false
    private var retries = 0

    public init(log: LogStore = .shared) { self.log = log }

    public func start() {
        wanted = true
        retries = 0
        installListeners()
        rebuild()
    }

    public func stop() {
        wanted = false
        debounce?.cancel()
        listeners.forEach { $0.invalidate() }
        listeners = []
        tearDown()
        status = .stopped
    }

    private func tearDown() {
        router?.teardown()
        router = nil
    }

    private func rebuild() {
        tearDown()
        guard wanted else { return }
        let devices = AudioDeviceCatalog.outputDevices()
        guard let resolved = OutputPolicy.resolve(selection: output, devices: devices,
                                                  defaultOutputID: AudioDeviceCatalog.defaultOutputDeviceID(),
                                                  systemOutputID: AudioDeviceCatalog.defaultSystemOutputDeviceID()) else {
            status = .failed("No physical output device found.")
            return
        }
        guard let own = AudioProcesses.ownProcessObjectID() else {
            status = .failed("Could not identify EquAudio's own audio process; refusing to start to avoid a feedback loop.")
            return
        }
        notice = resolved.reason
        let router = ProcessTapRouter(engine: engine, log: log)
        do {
            let request = RouteRequest(output: resolved.device, bufferFrames: bufferFrames, tapTarget: .global(excluding: [own]))
            let route = try router.build(request)
            engine.prepare(sampleRate: route.sampleRate, maxFrames: UInt32(max(4096, 2 * route.bufferFrames)))
            engine.setIOLayout(route.layout)
            engine.setHostVolume(dB: AudioDeviceCatalog.volumeDB(of: resolved.device))
            try router.start()
            self.router = router
            outputName = resolved.device.name
            sampleRate = route.sampleRate
            var l = route.latency
            l.engineLatencyFrames = Int(engine.latencyFrames)
            latency = l
            status = .running
            log.info("Controller", "Running on '\(resolved.device.name)' at \(Int(route.sampleRate)) Hz")
        } catch {
            router.teardown()
            log.error("Controller", "Start failed: \(error)")
            if retries < 2 {
                retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(retries)) { [weak self] in self?.rebuild() }
            } else {
                status = .failed("\(error)")
            }
        }
    }

    private func installListeners() {
        guard listeners.isEmpty else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            let address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            if let l = try? HALPropertyListener(object: system, address: address, queue: .main, handler: { [weak self] _ in self?.devicesChanged() }) {
                listeners.append(l)
            }
        }
    }

    /// Debounced; ignores our own aggregate appearing/disappearing by rebuilding only when the target differs.
    private func devicesChanged() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.wanted else { return }
            let devices = AudioDeviceCatalog.outputDevices()
            let resolved = OutputPolicy.resolve(selection: self.output, devices: devices,
                                                defaultOutputID: AudioDeviceCatalog.defaultOutputDeviceID(),
                                                systemOutputID: AudioDeviceCatalog.defaultSystemOutputDeviceID())
            let rate = resolved.flatMap { AudioDeviceCatalog.nominalSampleRate(of: $0.device.id) }
            if resolved?.device.name != self.outputName || rate != self.sampleRate || self.status != .running {
                self.log.info("Controller", "Devices changed; rebuilding route")
                self.retries = 0
                self.rebuild()
            }
        }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }
}
