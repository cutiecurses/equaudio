import AppKit
import EquAudioKit
import EquCore
import SwiftUI

/// Owns everything long-lived: engine/route, presets, settings, recorder. Main thread only.
final class LiveTick: ObservableObject {}

final class AppModel: ObservableObject {
    let controller = AudioController()
    let presets = PresetStore()
    let settingsStore: SettingsStore
    static let isSnapshot = CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--windowshot")
    lazy var recorder = Recorder(engine: controller.engine)
    @Published var settings: AppSettings
    var meters = EquMeters()   // live values below are NOT @Published: they change 30x a second and would re-measure the whole window
    @Published var recording = RecordingStatus()
    @Published var message: String?
    @Published var tab = 0
    let micFeed = MicFeed()
    @Published var feedEnabled = UserDefaults.standard.bool(forKey: "feedEnabled")
    @Published var feedSource = FeedSource(key: UserDefaults.standard.string(forKey: "feedSourceKey"),
                                           name: UserDefaults.standard.string(forKey: "feedSourceName") ?? FeedSource.allSystemAudio.name)
    @Published var feedGain: Double = UserDefaults.standard.object(forKey: "feedGain") as? Double ?? 0
    @Published var feedSources: [FeedSource] = [.allSystemAudio]
    @Published var feedDeviceName: String?
    var feedLevel: Float = 0
    @Published var feedVoiceOn = UserDefaults.standard.bool(forKey: "feedVoiceOn")
    @Published var feedVoiceUID: String? = UserDefaults.standard.string(forKey: "feedVoiceUID")
    @Published var feedVoiceGain: Double = UserDefaults.standard.object(forKey: "feedVoiceGain") as? Double ?? 0
    @Published var feedVoiceMuted = false
    @Published var feedDuck = UserDefaults.standard.bool(forKey: "feedDuck")
    @Published var localGain: Double = UserDefaults.standard.object(forKey: "localGain") as? Double ?? 0
    @Published var microphones: [AudioDeviceInfo] = []
    var voiceLevel: Float = 0
    @Published var rightTab = UserDefaults.standard.integer(forKey: "rightTab") { didSet { UserDefaults.standard.set(rightTab, forKey: "rightTab") } }
    @Published var themeIndex: Int = {
        if let i = CommandLine.arguments.firstIndex(of: "--theme"), i + 1 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[i + 1]) { return min(max(n, 0), Theme.all.count - 1) }
        let saved = UserDefaults.standard.string(forKey: "themeName")
        return Theme.all.firstIndex { $0.name == saved } ?? 0
    }()
    var inLevel: (Float, Float) = (0, 0)
    var outLevel: (Float, Float) = (0, 0)
    /// Output level history (0...1 over -60...0 dBFS), newest last: drives the scope line in the window and Touch Bar.
    var scopeHistory: [Float] = Array(repeating: 0.05, count: 150)
    private var scopeDB: [Float] = Array(repeating: -120, count: 150)
    /// Current short-term output loudness (dBFS RMS), for the readout next to the chart.
    var outputLoudnessDB: Float = -120
    var tickCount = 0
    /// Fires 30x a second; only the small views that show live meters observe it.
    let live = LiveTick()
    var touchBar: TouchBarController?
    let analyzer = Analyzer()
    /// 0 = controls, 1 = visualizer page.
    @Published var page = UserDefaults.standard.integer(forKey: "page") { didSet { UserDefaults.standard.set(page, forKey: "page") } }
    
    let nowPlayingMonitor = NowPlayingMonitor()
    @Published var nowPlaying: NowPlayingInfo?
    @Published var nowPlayingArt: NSImage?
    @Published var intensity: Double = UserDefaults.standard.object(forKey: "intensity") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(intensity, forKey: "intensity"); commit() }
    }
    @Published var devices: [AudioDeviceInfo] = []
    private var timer: Timer?
    private let startedAt = Date()
    private var selfTest: (started: Date, maxIn: Float, maxOut: Float, report: URL)?

    var engine: DSPEngine { controller.engine }

    init() {
        settingsStore = SettingsStore(fileURL: Self.isSnapshot ? FileManager.default.temporaryDirectory.appendingPathComponent("equaudio-snapshot-settings.json") : AppPaths.settingsFile)
        settings = settingsStore.load()
        settings.bypass = false   // A/B original is a per-session comparison tool: never start in bypass
        UI.theme = Theme.all[themeIndex]
        if Self.isSnapshot, let k = CommandLine.arguments.firstIndex(of: "--page"), k + 1 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[k + 1]) {
            page = n
            analyzer.fillDemo()
        }
        _ = presets.load()
        if Self.isSnapshot {
            if let p = presets.allPresets.first(where: { $0.name == "Heavenly Bass" }) { settings.dsp = p.settings; settings.selectedPresetID = p.id }
        } else if !UserDefaults.standard.bool(forKey: "didFirstRun") {
            UserDefaults.standard.set(true, forKey: "didFirstRun")
            if let p = presets.allPresets.first(where: { $0.name == "Heavenly Bass" }) { settings.dsp = p.settings; settings.selectedPresetID = p.id }
        }
        controller.onChange = { [weak self] in self?.objectWillChange.send() }
        micFeed.onChange = { [weak self] in self?.objectWillChange.send() }
        recorder.onStatusChange = { [weak self] s in self?.recording = s }
        controller.output = settings.output
        controller.bufferFrames = settings.bufferFrames
        settings.dsp.apply(to: engine)
        engine.bypass = settings.bypass
        if settings.processingEnabled && !Self.isSnapshot { controller.start() }
        refreshDevices()
        refreshFeed()
        commit()
        startFeedIfWanted()
        let args = CommandLine.arguments
        if Self.isSnapshot {
            nowPlaying = NowPlayingInfo(title: "Midnight City", artist: "M83", album: "", app: "Google Chrome", isPlaying: true, artwork: nil)
        } else if !args.contains("--feedtest") && !args.contains("--selftest") {
            nowPlayingMonitor.onChange = { [weak self] info in
                self?.nowPlaying = info
                LogStore.shared.info("NowPlaying", info.map { "\($0.title) — \($0.artist) [\($0.app)\($0.isPlaying ? "" : ", paused")]" } ?? "nothing playing")
                self?.nowPlayingArt = info?.artwork.flatMap { NSImage(data: $0) }
            }
            nowPlayingMonitor.start()
        }
        if !Self.isSnapshot && !args.contains("--feedtest") && !args.contains("--selftest") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.touchBar = TouchBarController(model: self)
                self.touchBar?.install()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, !Self.isSnapshot else { return }
            self.meters = self.engine.readMeters()
            self.tickCount += 1
            // Meter ballistics: instant attack, ~30 dB/s release.
            let m = self.meters, fall: Float = 0.9
            self.inLevel = (max(m.inputPeak.0, self.inLevel.0 * fall), max(m.inputPeak.1, self.inLevel.1 * fall))
            self.outLevel = (max(m.outputPeak.0, self.outLevel.0 * fall), max(m.outputPeak.1, self.outLevel.1 * fall))
            // Loudness line: ~40 ms RMS in dB, auto-zoomed to the recent range so it keeps moving even when loud,
            // limited music holds the peaks flat at the ceiling.
            let db = max(m.outputRMSFast.0, m.outputRMSFast.1).linearToDB
            self.scopeDB.append(db)
            self.scopeDB.removeFirst()
            self.scopeHistory = Self.autoScale(self.scopeDB)
            if self.tickCount % 6 == 0 { self.outputLoudnessDB = db }
            self.touchBar?.refresh()
            self.live.objectWillChange.send()
            if self.feedEnabled { let f = self.micFeed.readMeters(); self.feedLevel = max(f.outputPeak.0, f.outputPeak.1); self.voiceLevel = f.voicePeak }
            if self.tickCount % 30 == 0 { self.refreshFeed() }
            self.tickSelfTest()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--feedtest") {
            // Verifies the virtual-mic path without a loopback driver: feeds the named app into a silent physical
            // output while the main route is also running (and muting that app), then reports both engines' levels.
            let args = Array(CommandLine.arguments.dropFirst(i + 1))
            let report = URL(fileURLWithPath: args.first ?? "/tmp/equaudio-feedtest.txt"), needle = (args.dropFirst().first ?? "afplay").lowercased()
            let main = AudioDeviceCatalog.defaultOutputDevice()
            let other = AudioDeviceCatalog.outputDevices().first { OutputPolicy.isEligibleOutput($0) && $0.uid != main?.uid } ?? main
            let withVoice = args.contains("voice")
            micFeed.start(source: FeedSource(key: "name:" + needle, name: needle), outputOverride: other, silent: true)
            if withVoice { MicrophonePermission.request { [weak self] granted in self?.micFeed.setVoice(enabled: granted, deviceUID: nil) } }
            var inMain: Float = 0, inFeed: Float = 0, outFeed: Float = 0, voicePk: Float = 0
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
                guard let self else { return }
                inMain = max(inMain, self.meters.inputPeak.0)
                let f = self.micFeed.readMeters(); inFeed = max(inFeed, f.inputPeak.0); outFeed = max(outFeed, f.outputPeak.0); voicePk = max(voicePk, f.voicePeak)
                if Date().timeIntervalSince(self.startedAt) > (withVoice ? 40 : 14) {
                    t.invalidate()
                    let text = "feedStatus=\(self.micFeed.status) feedDevice=\(other?.name ?? "?") mainOut=\(self.controller.outputName)\nmainInputPeak=\(inMain) feedInputPeak=\(inFeed) feedOutputPeak=\(outFeed)\nvoice=\(withVoice) voiceDevice=\(self.micFeed.voiceDeviceName ?? "none") voiceIssue=\(self.micFeed.voiceIssue ?? "none") voicePeak=\(voicePk)\nPASS=\(inFeed > 0.001 && outFeed > 0.001 && inMain > 0.001 && (!withVoice || voicePk > 0))\n"
                    try? text.write(to: report, atomically: true, encoding: .utf8)
                    self.shutdown(); NSApp.terminate(nil)
                }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let path = CommandLine.arguments.dropFirst(i + 1).first { !$0.hasPrefix("--") } ?? "/tmp/equaudio-selftest.txt"
            selfTest = (Date(), 0, 0, URL(fileURLWithPath: path))
            // Boost 1 kHz by +9 dB so the output/input ratio proves processing is applied to live system audio.
            settings.dsp[.eqBand5] = 9; settings.dsp[.autoHeadroom] = 0; settings.dsp[.limiterEnabled] = 0; commit()
        }
    }

    /// `--selftest <report>`: while something plays (afplay of a 1 kHz tone), records the largest input/output
    /// peaks seen, writes a report and quits. Output/input should be ~+9 dB (3 dB per... see report).
    private func tickSelfTest() {
        guard var t = selfTest else { return }
        t.maxIn = max(t.maxIn, meters.inputPeak.0); t.maxOut = max(t.maxOut, meters.outputPeak.0)
        selfTest = t
        guard Date().timeIntervalSince(t.started) > 9 else { return }
        let gain = t.maxIn > 0 ? 20 * log10(Double(t.maxOut / t.maxIn)) : 0
        let text = "status=\(controller.status) output=\(controller.outputName) rate=\(Int(controller.sampleRate))\ninputPeak=\(t.maxIn) outputPeak=\(t.maxOut) gain_dB=\(String(format: "%.2f", gain))\nlatency_ms=\(controller.latency?.estimatedOutputMs ?? -1)\nPASS=\(t.maxIn > 0.001 && gain > 6)\n"
        try? text.write(to: t.report, atomically: true, encoding: .utf8)
        shutdown(); NSApp.terminate(nil)
    }

    func refreshDevices() { devices = AudioDeviceCatalog.outputDevices().filter(OutputPolicy.isEligibleOutput) }

    /// Master intensity scales every enhancement (EQ, bass, treble, clarity, loudness, width) around "off".
    func commit() {
        var d = settings.dsp
        let k = Float(intensity)
        for i in 0..<10 { d[.eqBand(i)] *= k }
        for p in [EquParam.bassBoostDB, .subBassDB, .bassHarmonics, .trebleDB, .clarity, .loudness, .reverbMix, .spatial, .deepBass] { d[p] *= k }
        d[.stereoWidth] = 1 + (d[.stereoWidth] - 1) * k
        d.apply(to: engine)
        engine[.outputGainDB] = d[.outputGainDB] + Float(localGain)
        applyFeed(d)
        settingsStore.scheduleSave(settings)
    }

    // MARK: Virtual mic

    /// Maps dB values to 0.06...0.94 so the recent maximum touches the top and the recent minimum the bottom,
    /// with at least a 10 dB span (a steady signal stays a calm line instead of exaggerating tiny wiggles).
    static func autoScale(_ db: [Float]) -> [Float] {
        let hi = db.max() ?? -120
        if hi < -70 { return db.map { _ in 0.06 } }
        let span = max(hi - (db.min() ?? hi), 10)
        return db.map { 0.06 + 0.88 * min(max(($0 - (hi - span)) / span, 0), 1) }
    }

    /// Called once per frame by the visualizer page (not at all while it is closed).
    func refreshAnalyzer() {
        if !Self.isSnapshot { analyzer.update(engine: engine) }
    }

    func refreshFeed() {
        let device = Self.isSnapshot ? "BlackHole 2ch" : MicFeed.loopbackDevices().first?.name
        if device != feedDeviceName { feedDeviceName = device }
        let sources = micFeed.availableSources(), mics = MicFeed.microphones()
        if sources != feedSources { feedSources = sources }
        if mics != microphones { microphones = mics }
    }

    private func applyFeed(_ d: DSPSettings) {
        micFeed.apply(d, musicGainDB: Float(feedGain), voiceGainDB: Float(feedVoiceGain), voiceMuted: feedVoiceMuted, duck: feedDuck ? 1 : 0)
    }

    func startFeedIfWanted() {
        guard feedEnabled, !Self.isSnapshot, !CommandLine.arguments.contains("--feedtest"), feedDeviceName != nil else { return }
        micFeed.setVoice(enabled: feedVoiceOn, deviceUID: feedVoiceUID)
        micFeed.start(source: feedSource)
    }

    func setFeed(_ on: Bool) {
        feedEnabled = on
        UserDefaults.standard.set(on, forKey: "feedEnabled")
        if on { micFeed.setVoice(enabled: feedVoiceOn, deviceUID: feedVoiceUID); micFeed.start(source: feedSource) } else { micFeed.stop() }
    }

    /// Voice on: asks for the Microphone permission first (the switch stays on so a denial is explained in the card).
    func setFeedVoice(_ on: Bool) {
        feedVoiceOn = on
        UserDefaults.standard.set(on, forKey: "feedVoiceOn")
        if on && feedDeviceName != nil && !feedEnabled { setFeed(true) }
        if on {
            MicrophonePermission.request { [weak self] _ in
                guard let self else { return }
                self.micFeed.setVoice(enabled: true, deviceUID: self.feedVoiceUID)
            }
        } else {
            micFeed.setVoice(enabled: false, deviceUID: feedVoiceUID)
        }
    }

    func setVoiceDevice(_ uid: String?) {
        feedVoiceUID = uid
        UserDefaults.standard.set(uid, forKey: "feedVoiceUID")
        micFeed.setVoice(enabled: feedVoiceOn, deviceUID: uid)
    }

    func setVoiceGain(_ g: Double) { feedVoiceGain = g; UserDefaults.standard.set(g, forKey: "feedVoiceGain"); commit() }
    func toggleVoiceMute() { feedVoiceMuted.toggle(); commit() }
    func setDuck(_ on: Bool) { feedDuck = on; UserDefaults.standard.set(on, forKey: "feedDuck"); commit() }
    func setTheme(_ i: Int) {
        themeIndex = i
        UI.theme = Theme.all[i]
        UserDefaults.standard.set(Theme.all[i].name, forKey: "themeName")
    }

    func setLocalGain(_ g: Double) { localGain = g; UserDefaults.standard.set(g, forKey: "localGain"); commit() }

    func setFeedSource(_ s: FeedSource) {
        feedSource = s
        UserDefaults.standard.set(s.key, forKey: "feedSourceKey")
        UserDefaults.standard.set(s.name, forKey: "feedSourceName")
        if feedEnabled { micFeed.start(source: s) }
    }

    func setFeedGain(_ g: Double) {
        feedGain = g
        UserDefaults.standard.set(g, forKey: "feedGain")
        commit()
    }

    func set(_ p: EquParam, _ v: Float) {
        settings.dsp[p] = v
        settings.selectedPresetID = nil
        commit()
    }

    func apply(_ preset: Preset) {
        settings.dsp = preset.settings
        settings.selectedPresetID = preset.id
        commit()
    }

    func setPower(_ on: Bool) {
        settings.processingEnabled = on
        if on { controller.start() } else { controller.stop() }
        settingsStore.scheduleSave(settings)
    }

    func setBypass(_ on: Bool) {
        settings.bypass = on
        engine.bypass = on
        settingsStore.scheduleSave(settings)
    }

    func setOutput(_ s: OutputSelection) {
        settings.output = s
        controller.output = s
        if settings.processingEnabled { controller.start() }
        settingsStore.scheduleSave(settings)
    }

    func toggleRecording() {
        if recorder.isRecording {
            recording = recorder.stop()
        } else {
            do {
                let name = presets.preset(id: settings.selectedPresetID ?? UUID())?.name ?? "Custom"
                _ = try recorder.start(settings: settings.recording, deviceSampleRate: controller.sampleRate, presetName: name)
                message = nil
            } catch { message = "Recording failed: \(error.localizedDescription)" }
        }
    }

    func shutdown() {
        if recorder.isRecording { _ = recorder.stop() }
        nowPlayingMonitor.stop()
        touchBar?.uninstall()
        micFeed.stop()
        controller.stop()
        settingsStore.flush()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

@main
struct EquAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("EquAudio", id: "main") {
            RootView().environmentObject(model).environmentObject(model.live)
                .onAppear {
                    delegate.model = model
                    if AppModel.isSnapshot { renderSnapshot(model) }
                }
                .frame(minWidth: 1080, minHeight: 724)
                .preferredColorScheme(Theme.all[model.themeIndex].isLight ? .light : .dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 724)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Audio") {
                Button("Controls") { model.page = 0 }.keyboardShortcut("1", modifiers: .command)
                Button("Visualizer") { model.page = 1 }.keyboardShortcut("2", modifiers: .command)
                Button("Toggle A/B Original") { model.setBypass(!model.settings.bypass) }.keyboardShortcut("b", modifiers: .command)
                Button("Power On/Off") { model.setPower(!model.settings.processingEnabled) }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Touch Bar Controls") { model.touchBar?.toggleModal() }.keyboardShortcut("t", modifiers: [.command, .option])
                Button("Restore Touch Bar Item") { model.touchBar?.reassert(full: true) }
            }
        }
        MenuBarExtra("EquAudio", systemImage: model.settings.processingEnabled ? "waveform.circle.fill" : "waveform.circle") {
            MenuPanel().environmentObject(model).preferredColorScheme(Theme.all[model.themeIndex].isLight ? .light : .dark)
        }.menuBarExtraStyle(.window)
    }
}


/// `--snapshot <png>`: renders the main window offscreen with sample meter values so the layout can be reviewed
/// without screen-recording permission. Does not start audio and never touches the user's settings.
@MainActor func renderSnapshot(_ model: AppModel) {
    guard let i = CommandLine.arguments.firstIndex(of: "--snapshot"), let path = CommandLine.arguments.dropFirst(i + 1).first else { return }
    var meters = EquMeters()
    meters.inputPeak = (0.5, 0.42); meters.outputPeak = (0.7, 0.66); meters.inputRMS = (0.2, 0.2); meters.outputRMS = (0.3, 0.3)
    model.meters = meters
    model.inLevel = (0.5, 0.42); model.outLevel = (0.7, 0.66)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        var size = CGSize(width: 1120, height: 760)
        if let k = CommandLine.arguments.firstIndex(of: "--size"), k + 1 < CommandLine.arguments.count {
            let parts = CommandLine.arguments[k + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
        }
        let view = MainView().environmentObject(model).environmentObject(model.live).frame(width: size.width, height: size.height).environment(\.colorScheme, UI.theme.isLight ? .light : .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
        renderTouchBarPreview(to: path.replacingOccurrences(of: ".png", with: "-touchbar.png"))
        NSApp.terminate(nil)
    }
}

/// Offscreen picture of the Touch Bar widgets (black bar, 3x) for layout checks.
@MainActor func renderTouchBarPreview(to path: String) {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 40))
    host.wantsLayer = true
    host.layer?.backgroundColor = NSColor.black.cgColor
    var x: CGFloat = 8
    func place(_ v: NSView, _ w: CGFloat) { v.translatesAutoresizingMaskIntoConstraints = true; v.frame = NSRect(x: x, y: 5, width: w, height: 30); host.addSubview(v); x += w + 12 }
    // Explicit types: older compilers (Swift 6.1) give up on the one-line closures below.
    let demo: [Float] = (0..<120).map { (n: Int) -> Float in
        let slow = Float(sin(Double(n) / 6)), fast = Float(sin(Double(n) / 1.9))
        return 0.5 + 0.3 * slow + 0.1 * fast
    }
    let strip = MeterButton(width: 150); strip.withScopeLine(); strip.samples = demo; strip.levels = (0.55, 0.42); place(strip, 150)
    let bar = MeterButton(width: 250); bar.levels = (0.7, 0.62); place(bar, 250)
    let a = ScopeButton(width: 230)
    a.samples = (0..<120).map { (n: Int) -> Float in
        let slow = Float(sin(Double(n) / 5)), fast = Float(sin(Double(n) / 1.7))
        return 0.45 + 0.25 * slow + 0.12 * fast
    }
    place(a, 230)
    let b = TouchSlider(kind: "bass", title: "Bass", width: 140); b.value = 0.42; place(b, 140)
    let scale: CGFloat = 3
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(760 * scale), pixelsHigh: Int(40 * scale), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    ctx.cgContext.scaleBy(x: scale, y: scale)
    host.layer?.render(in: ctx.cgContext)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    host.subviews.forEach { v in
        ctx.cgContext.saveGState(); ctx.cgContext.translateBy(x: v.frame.minX, y: v.frame.minY)
        v.draw(NSRect(origin: .zero, size: v.frame.size)); ctx.cgContext.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
}

// MARK: - Design system: flat, solid colours, bold type (deep greys, one orange accent)

struct Theme {
    let name: String
    let isLight: Bool
    let bg, panel, raised, stroke, text, muted, accent, onAccent: Color

    init(_ name: String, light: Bool = false, bg: UInt32, panel: UInt32, raised: UInt32, stroke: UInt32, text: UInt32, muted: UInt32, accent: UInt32, onAccent: UInt32) {
        self.name = name
        self.isLight = light
        self.bg = Color(hex: bg); self.panel = Color(hex: panel); self.raised = Color(hex: raised); self.stroke = Color(hex: stroke)
        self.text = Color(hex: text); self.muted = Color(hex: muted); self.accent = Color(hex: accent); self.onAccent = Color(hex: onAccent)
    }

    /// Palettes from the "luxury colour palette" list. Base hexes are the listed ones; panel/raised/muted are tints between them.
    static let all: [Theme] = [
        Theme("Rose Gold Dusk", bg: 0x1F1C1E, panel: 0x2A2528, raised: 0x3A3236, stroke: 0x6B4E5E, text: 0xF6EFE8, muted: 0xB8A6AB, accent: 0xB76E79, onAccent: 0x1F1C1E),
        Theme("Ivory Marble", light: true, bg: 0xF8F6F1, panel: 0xEFEBE3, raised: 0xD8D2C8, stroke: 0xAFA79C, text: 0x121212, muted: 0x5B5A57, accent: 0x121212, onAccent: 0xF8F6F1),
        Theme("Midnight Orchid", bg: 0x120B1A, panel: 0x1C1229, raised: 0x2B1B3D, stroke: 0x45305F, text: 0xE7D9F2, muted: 0xA692C2, accent: 0xBFA36A, onAccent: 0x120B1A),
        Theme("Gilded Noir", bg: 0x0B0B0F, panel: 0x16161B, raised: 0x26252B, stroke: 0x3B3A40, text: 0xF5F0E6, muted: 0xA39D91, accent: 0xD4AF37, onAccent: 0x0B0B0F),
        Theme("Emerald Velvet", bg: 0x0A231B, panel: 0x0E3B2E, raised: 0x175040, stroke: 0x1F6F54, text: 0xF2E8D8, muted: 0xA3B8AA, accent: 0xC9A227, onAccent: 0x0A231B),
        Theme("Sapphire Lounge", bg: 0x08142B, panel: 0x0B1B3A, raised: 0x162B5C, stroke: 0x1E3A8A, text: 0xE7E2D9, muted: 0xA1B2D6, accent: 0xB48A5A, onAccent: 0x08142B),
    ]
}

enum UI {
    nonisolated(unsafe) static var theme = Theme.all[0]
    static var bg: Color { theme.bg }
    static var panel: Color { theme.panel }
    static var raised: Color { theme.raised }
    static var stroke: Color { theme.stroke }
    static var text: Color { theme.text }
    static var muted: Color { theme.muted }
    static var accent: Color { theme.accent }
    static var onAccent: Color { theme.onAccent }
    static let green = Color(hex: 0x3DAA73), red = Color(hex: 0xE5484D)
    static func font(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight) }
}
extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}
var accent: Color { UI.accent }

struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    var fill = false
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(UI.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(UI.stroke.opacity(0.6), lineWidth: 1))
    }
}

struct Label2: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(UI.font(10.5)).tracking(1.6).foregroundStyle(UI.muted) }
}

struct FlatSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var body: some View {
        GeometryReader { g in
            let f = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(UI.raised).frame(height: 4)
                Capsule().fill(UI.accent).frame(width: max(4, g.size.width * f), height: 4)
                Circle().fill(UI.text).frame(width: 14, height: 14).offset(x: (g.size.width - 14) * f)
            }
            .frame(maxHeight: .infinity).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let t = Double(min(max(d.location.x / g.size.width, 0), 1))
                value = range.lowerBound + t * (range.upperBound - range.lowerBound)
            })
        }.frame(height: 18)
    }
}

struct FlatSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? UI.accent : UI.raised).frame(width: 36, height: 20)
                Circle().fill(isOn ? UI.onAccent : UI.muted).frame(width: 14, height: 14).padding(3)
            }
        }.buttonStyle(.plain)
    }
}

struct FlatButton: View {
    let title: String
    var on = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(UI.font(12)).padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? UI.accent : UI.raised))
                .foregroundStyle(on ? UI.onAccent : UI.text)
        }.buttonStyle(.plain)
    }
}

/// Flat rotary knob: 270° ring with a pointer dot. Drag up/right to increase; double-click resets to `reset`.
struct RotaryKnob: View {
    @Binding var value: Double
    var title: String
    var display: String
    var size: CGFloat
    var ring: CGFloat = 8
    var big = false
    var reset: Double = 0
    @State private var start: Double?
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(UI.raised.opacity(0.55))
                Circle().trim(from: 0, to: 0.75).stroke(UI.raised, style: StrokeStyle(lineWidth: ring)).rotationEffect(.degrees(135)).padding(ring / 2 + 6)
                Circle().trim(from: 0, to: 0.75 * value).stroke(UI.accent, style: StrokeStyle(lineWidth: ring)).rotationEffect(.degrees(135)).padding(ring / 2 + 6)
                Circle().fill(UI.text).frame(width: ring + 2, height: ring + 2)
                    .offset(x: (size / 2 - ring / 2 - 6) * CGFloat(cos((135 + 270 * value) * .pi / 180)),
                            y: (size / 2 - ring / 2 - 6) * CGFloat(sin((135 + 270 * value) * .pi / 180)))
                VStack(spacing: 0) {
                    Text(display).font(UI.font(big ? 56 : 20, .heavy).monospacedDigit())
                    if big { Label2(text: title) }
                }
            }
            .frame(width: size, height: size).contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                if start == nil { start = value }
                value = min(max(start! + Double(-d.translation.height + d.translation.width) / 200, 0), 1)
            }.onEnded { _ in start = nil })
            .onTapGesture(count: 2) { value = reset }
            if !big { Text(title.uppercased()).font(UI.font(11, .heavy)).tracking(1.5) }
        }
    }
}

/// The window lays itself out at its real size (the EQ and level displays grow with it), so text and controls
/// stay sharp in any window size and in full screen (⌃⌘F).
struct RootView: View {
    @EnvironmentObject var m: AppModel
    @State private var fullScreen = false
    var body: some View {
        // Windowed: the content runs under the (transparent) title bar. Full screen: macOS keeps an opaque 32 pt bar at
        // the top of the screen, so the content must start below it or the top bar is hidden.
        MainView()
            .background(UI.bg.ignoresSafeArea())
            .ignoresSafeArea(edges: fullScreen ? [] : .all)
            .background(WindowConfigurator(theme: Theme.all[m.themeIndex]))
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
    }
}

/// Makes the title bar part of the design: transparent, no title text, content underneath it, the traffic-light
/// buttons centred on our top bar (an empty unified toolbar gives the title bar its taller, 52 pt height), and the
/// window colour following the theme.
struct WindowConfigurator: NSViewRepresentable {
    let theme: Theme
    nonisolated(unsafe) private static var capturedWindowShot = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    nonisolated(unsafe) private static var observedWindows = Set<ObjectIdentifier>()

    /// In full screen macOS draws a toolbar window over the top 66 pt of the screen; with our (empty) toolbar that
    /// overlay hid the app's top bar. The toolbar only exists to centre the traffic lights, so it is removed for
    /// full screen and restored afterwards.
    private static func observeFullScreen(_ window: NSWindow) {
        guard observedWindows.insert(ObjectIdentifier(window)).inserted else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { _ in
            window.toolbar = nil
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
            window.toolbar = NSToolbar(identifier: "EquAudioMain")
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.title = "EquAudio"
        // An empty unified toolbar makes the (hidden) title bar 52 pt tall, which centres the traffic lights on our top bar.
        if window.toolbar == nil && !window.styleMask.contains(.fullScreen) { window.toolbar = NSToolbar(identifier: "EquAudioMain") }
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        Self.observeFullScreen(window)
        window.backgroundColor = NSColor(theme.bg)
        window.appearance = NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
        let live = CommandLine.arguments.firstIndex(of: "--livewindowshot")
        if let i = CommandLine.arguments.firstIndex(of: "--windowshot") ?? live, i + 1 < CommandLine.arguments.count, !Self.capturedWindowShot {
            Self.capturedWindowShot = true
            let path = CommandLine.arguments[i + 1]
            let fullScreen = CommandLine.arguments.contains("--fullscreen")
            // Layout/motion check without screen-recording permission: draws the real window frame (title bar included),
            // optionally in real full screen, and a second frame 1.2 s later to prove things move.
            func capture(to file: String) {
                if let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                }
            }
            if fullScreen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.activate(ignoringOtherApps: true); window.toggleFullScreen(nil) }
                // keep the pointer away from the top edge so the auto-hiding title bar is in its resting state
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { CGWarpMouseCursorPosition(CGPoint(x: 900, y: 700)) }
            }
            let delay = (live != nil ? 8.0 : 2.5) + (fullScreen ? 3.0 : 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                capture(to: path)
                let report = NSApp.windows.map { "\(type(of: $0)) frame=\($0.frame) visible=\($0.isVisible) level=\($0.level.rawValue) toolbar=\($0.toolbar != nil) fullscreen=\($0.styleMask.contains(.fullScreen))" }.joined(separator: "\n")
                var details = report
                for w in NSApp.windows where String(describing: type(of: w)).contains("NSToolbarFullScreenWindow") {
                    if let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        var opaque = 0, total = 0
                        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
                            total += 1; if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { opaque += 1 } } }
                        details += "\noverlay alpha>0.05 in \(opaque) of \(total) samples; subviews=\(v.subviews.count) alpha=\(w.alphaValue) opaque=\(w.isOpaque)"
                    }
                }
                try? details.write(toFile: path.replacingOccurrences(of: ".png", with: "-windows.txt"), atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    capture(to: path.replacingOccurrences(of: ".png", with: "-b.png"))
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

/// Empty parts of the top bar drag the window; double-click zooms it (the title bar is gone, so this replaces it).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Root

struct MainView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 14) {
            TopBar()
            if m.page == 1 { VisualizerPage() } else {
            HStack(alignment: .top, spacing: 14) {
                LeftColumn().frame(width: 300).frame(maxHeight: .infinity, alignment: .top)
                CenterColumn()
                RightColumn().frame(width: 310).frame(maxHeight: .infinity, alignment: .top)
            }
            }
            BottomBar()
        }
        .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UI.bg)
        .foregroundStyle(UI.text)
        .opacity(m.settings.processingEnabled ? 1 : 0.6)
        .id(m.themeIndex)
    }
}

struct TopBar: View {
    @EnvironmentObject var m: AppModel
    @State private var fullScreen = false
    func pageTab(_ title: String, _ i: Int) -> some View {
        Button { m.page = i } label: {
            Text(title).font(UI.font(11, .heavy)).tracking(1.3).padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(m.page == i ? UI.raised : Color.clear))
                .foregroundStyle(m.page == i ? UI.text : UI.muted)
        }.buttonStyle(.plain)
    }
    var body: some View {
        HStack(spacing: 12) {
            Text("EquAudio").font(UI.font(22, .heavy))
            Rectangle().fill(UI.stroke).frame(width: 1, height: 24)
            HStack(spacing: 2) { pageTab("CONTROLS", 0); pageTab("VISUALIZER", 1) }
                .padding(3).background(RoundedRectangle(cornerRadius: 8).fill(UI.panel))
            Spacer()
            PresetBar()
            Spacer()
            Menu {
                ForEach(Array(Theme.all.enumerated()), id: \.offset) { i, t in Button(t.name) { m.setTheme(i) } }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(UI.accent).frame(width: 9, height: 9)
                    Text("THEME").font(UI.font(12))
                }.padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(UI.raised)).foregroundStyle(UI.text)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            FlatButton(title: "A/B  ORIGINAL", on: m.settings.bypass) { m.setBypass(!m.settings.bypass) }
            Button { m.setPower(!m.settings.processingEnabled) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power").font(UI.font(13))
                    Text(m.settings.processingEnabled ? "ON" : "OFF").font(UI.font(12))
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(m.settings.processingEnabled ? UI.accent : UI.raised))
                .foregroundStyle(m.settings.processingEnabled ? UI.onAccent : UI.muted)
            }.buttonStyle(.plain)
        }
        .padding(.leading, fullScreen ? 0 : 74)   // room for the traffic-light buttons
        .background(WindowDragArea().padding(.top, -9).padding(.horizontal, -18))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
    }
}

struct PresetBar: View {
    @EnvironmentObject var m: AppModel
    var current: Preset? { m.settings.selectedPresetID.flatMap { m.presets.preset(id: $0) } }
    func step(_ d: Int) {
        let all = m.presets.allPresets
        guard !all.isEmpty else { return }
        let i = current.flatMap { c in all.firstIndex(where: { $0.id == c.id }) } ?? 0
        m.apply(all[(i + d + all.count) % all.count])
    }
    var body: some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: { Image(systemName: "chevron.left").font(UI.font(13)).frame(width: 36, height: 34) }.buttonStyle(.plain)
            Menu {
                ForEach(m.presets.allPresets) { p in Button(p.name) { m.apply(p) } }
                Divider()
                Button("Save current sound…") { savePreset() }
                if let c = current, !c.isFactory { Button("Delete “\(c.name)”") { try? m.presets.delete(id: c.id); m.settings.selectedPresetID = nil; m.objectWillChange.send() } }
            } label: {
                HStack(spacing: 8) {
                    Text(current?.name ?? "Custom").font(UI.font(14)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(UI.font(10)).foregroundStyle(UI.muted)
                }.frame(width: 230, height: 34)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 230)
            Button { step(1) } label: { Image(systemName: "chevron.right").font(UI.font(13)).frame(width: 36, height: 34) }.buttonStyle(.plain)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UI.stroke.opacity(0.6)))
    }
    func savePreset() {
        let alert = NSAlert(); alert.messageText = "Save current sound as preset"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); field.placeholderString = "Preset name"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let p = try? m.presets.save(name: field.stringValue, settings: m.settings.dsp) { m.settings.selectedPresetID = p.id; m.objectWillChange.send() }
    }
}

// MARK: - Left: intensity, meters, output

/// IN/OUT LED meters: the one place in the left column that refreshes 30 times a second.
struct MeterCard: View {
    @EnvironmentObject var m: AppModel
    @EnvironmentObject var live: LiveTick
    var body: some View {
        Panel {
            VStack(spacing: 12) {
                HLED(title: "IN", peaks: [m.inLevel.0, m.inLevel.1])
                HLED(title: "OUT", peaks: [m.outLevel.0, m.outLevel.1])
                HStack {
                    ForEach(["-48", "-36", "-24", "-12", "-6", "0"], id: \.self) { t in
                        Text(t).font(UI.font(9).monospacedDigit()).foregroundStyle(UI.muted).frame(maxWidth: .infinity)
                    }
                }.padding(.leading, 42)
            }
        }
    }
}

struct LeftColumn: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Panel {
                VStack(spacing: 6) {
                    RotaryKnob(value: $m.intensity, title: "Intensity", display: "\(Int((m.intensity * 100).rounded()))", size: 220, ring: 12, big: true, reset: 1)
                        .frame(maxWidth: .infinity)
                }
            }
            MeterCard()
            OutputCard()
        }
    }
}

/// Horizontal segmented LED meter, stereo, -60...0 dBFS.
struct HLED: View {
    let title: String, peaks: [Float]
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(UI.font(11, .heavy)).tracking(1).frame(width: 34, alignment: .leading)
            Canvas { ctx, size in
                let count = 40, gap: CGFloat = 2, w = (size.width - gap * CGFloat(count - 1)) / CGFloat(count), h = (size.height - 3) / 2
                for c in 0..<2 {
                    let lit = Int((min(max((peaks[c].linearToDB + 60) / 60, 0), 1) * Float(count)).rounded())
                    for i in 0..<count {
                        let color = i < lit ? (i >= count - 3 ? UI.red : i >= count - 10 ? UI.accent : UI.muted) : UI.raised
                        ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * (w + gap), y: CGFloat(c) * (h + 3), width: w, height: h), cornerRadius: 1), with: .color(color))
                    }
                }
            }.frame(height: 17)
        }
    }
}

struct OutputCard: View {
    @EnvironmentObject var m: AppModel
    @EnvironmentObject var live: LiveTick
    var body: some View {
        Panel(fill: true) {
            VStack(alignment: .leading, spacing: 10) {
                Label2(text: "Output")
                Menu {
                    Button("System default") { m.setOutput(.systemDefault) }
                    ForEach(m.devices) { d in Button(d.name) { m.setOutput(.device(uid: d.uid)) } }
                } label: {
                    HStack { Text(m.controller.outputName.isEmpty ? "Not routing" : m.controller.outputName).font(UI.font(14)).lineLimit(1); Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(UI.font(10)).foregroundStyle(UI.muted) }
                        .padding(.horizontal, 10).frame(height: 32).background(RoundedRectangle(cornerRadius: 6).fill(UI.raised))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).onAppear { m.refreshDevices() }
                HStack(spacing: 8) {
                    Text("MY VOLUME").font(UI.font(10.5, .heavy)).tracking(1.2).foregroundStyle(UI.muted).frame(width: 84, alignment: .leading)
                    FlatSlider(value: Binding(get: { m.localGain }, set: m.setLocalGain), range: -24...6)
                    Text(String(format: "%+.0f", m.localGain)).font(UI.font(11).monospacedDigit()).frame(width: 26, alignment: .trailing)
                }
                HStack(spacing: 18) {
                    stat("RATE", m.controller.sampleRate > 0 ? "\(Int(m.controller.sampleRate / 1000)) kHz" : "—")
                    stat("LATENCY", m.controller.latency.map { String(format: "%.0f ms", $0.estimatedOutputMs) } ?? "—")
                    stat("LIMITER", String(format: "-%.1f dB", m.meters.gainReductionDB))
                }
                HStack {
                    Label2(text: "Output loudness")
                    Spacer()
                    Text(m.outputLoudnessDB > -100 ? String(format: "%.0f dB", m.outputLoudnessDB) : "—").font(UI.font(11).monospacedDigit()).foregroundStyle(UI.muted)
                }
                ScopeLine().frame(maxHeight: .infinity).frame(minHeight: 60)
            }
        }
    }
    func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Label2(text: t); Text(v).font(UI.font(14).monospacedDigit()) }
    }
}

/// Rolling output-level line in the theme colours (same data as the Touch Bar scope).
struct ScopeLine: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { ctx, size in
                // Reading the timeline date makes the closure differ every frame; SwiftUI skips redrawing a Canvas whose
                // closure captures identical values (the history is a class property, so nothing else would change).
                _ = timeline.date
                let h = m.scopeHistory, n = h.count
                guard n > 1 else { return }
                func pt(_ i: Int) -> CGPoint { CGPoint(x: size.width * CGFloat(i) / CGFloat(n - 1), y: size.height - 4 - (size.height - 8) * CGFloat(h[i])) }
                for frac in [0.25, 0.5, 0.75] {
                    var g = Path(); g.move(to: CGPoint(x: 0, y: size.height * frac)); g.addLine(to: CGPoint(x: size.width, y: size.height * frac))
                    ctx.stroke(g, with: .color(UI.raised.opacity(0.8)), lineWidth: 1)
                }
                var line = Path(); line.addSmoothCurve(through: (0..<n).map(pt))
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
                ctx.fill(fill, with: .color(UI.accent.opacity(0.18)))
                ctx.stroke(line, with: .color(UI.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                let tip = pt(n - 1)
                ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 4, y: tip.y - 4, width: 8, height: 8)), with: .color(UI.text))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.bg.opacity(0.6)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Center: response curve + faders

struct EQCurve: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        let dsp = m.settings.dsp   // dependency: redraw when settings change
        GeometryReader { geo in
        Canvas { ctx, size in
            let rangeDB: CGFloat = 15
            func y(_ db: CGFloat) -> CGFloat { size.height / 2 - db / rangeDB * size.height / 2 }
            func x(_ f: Double) -> CGFloat { CGFloat((log2(f / 31.25) + 0.5) / 10) * size.width }
            for db in stride(from: -12, through: 12, by: 6) {
                var line = Path(); line.move(to: CGPoint(x: 0, y: y(CGFloat(db)))); line.addLine(to: CGPoint(x: size.width, y: y(CGFloat(db))))
                ctx.stroke(line, with: .color(db == 0 ? UI.stroke : UI.raised.opacity(0.7)), lineWidth: db == 0 ? 1.5 : 1)
                ctx.draw(Text(db > 0 ? "+\(db)" : "\(db)").font(UI.font(9)).foregroundColor(UI.muted), at: CGPoint(x: 6, y: y(CGFloat(db)) - 7), anchor: .leading)
            }
            for f in eqBandFrequencies {
                var line = Path(); line.move(to: CGPoint(x: x(f), y: 0)); line.addLine(to: CGPoint(x: x(f), y: size.height))
                ctx.stroke(line, with: .color(UI.raised.opacity(0.7)), lineWidth: 1)
            }
            let n = 200
            let freqs: [Float] = (0..<n).map { Float(22.1 * pow(22627.0 / 22.1, Double($0) / Double(n - 1))) }
            let resp = m.engine.response(frequencies: freqs, stages: [.eq, .tone])
            var curve = Path()
            for i in 0..<n {
                let pt = CGPoint(x: x(Double(freqs[i])), y: y(min(max(CGFloat(resp[i]), -rangeDB), rangeDB)))
                i == 0 ? curve.move(to: pt) : curve.addLine(to: pt)
            }
            var fill = curve
            fill.addLine(to: CGPoint(x: size.width, y: y(0))); fill.addLine(to: CGPoint(x: 0, y: y(0))); fill.closeSubpath()
            ctx.fill(fill, with: .color(UI.accent.opacity(0.16)))
            ctx.stroke(curve, with: .color(UI.accent), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            let bandResp = m.engine.response(frequencies: eqBandFrequencies.map { Float($0) }, stages: [.eq, .tone])
            for (i, f) in eqBandFrequencies.enumerated() {
                let c = CGPoint(x: x(f), y: y(min(max(CGFloat(bandResp[i]), -rangeDB), rangeDB)))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(UI.text))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(UI.accent), lineWidth: 2)
            }
        }
        .id(dsp)
        // Drag anywhere on the curve: the nearest band follows the pointer (±12 dB, 0.5 dB steps).
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let t = min(max(v.location.x / geo.size.width, 0), 1)
            let band = min(max(Int((t * 10 - 0.5).rounded()), 0), 9)
            let db = (0.5 - v.location.y / geo.size.height) * 2 * 15
            m.set(.eqBand(band), Float((min(max(db, -12), 12) * 2).rounded() / 2))
        })
        }
    }
}

struct CenterColumn: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Panel(fill: true) {
            VStack(spacing: 10) {
                HStack {
                    Label2(text: "Equalizer")
                    Spacer()
                    FlatSwitch(isOn: Binding(get: { m.settings.dsp[.eqEnabled] > 0.5 }, set: { m.set(.eqEnabled, $0 ? 1 : 0) }))
                    FlatButton(title: "Reset") { for i in 0..<10 { m.settings.dsp[.eqBand(i)] = 0 }; m.settings.selectedPresetID = nil; m.commit() }
                }
                EQCurve().frame(minHeight: 150, maxHeight: .infinity).background(RoundedRectangle(cornerRadius: 8).fill(UI.bg.opacity(0.6)))
                HStack(spacing: 0) {
                    ForEach(0..<10, id: \.self) { i in
                        VStack(spacing: 8) {
                            Text(String(format: "%+.1f", m.settings.dsp[.eqBand(i)])).font(UI.font(11).monospacedDigit()).foregroundStyle(m.settings.dsp[.eqBand(i)] == 0 ? UI.muted : UI.text)
                            Fader(value: Binding(get: { m.settings.dsp[.eqBand(i)] }, set: { m.set(.eqBand(i), $0) }), range: -12...12).frame(minHeight: 150, maxHeight: .infinity)
                            Text(label(i)).font(UI.font(11, .heavy)).foregroundStyle(UI.muted)
                        }.frame(maxWidth: .infinity)
                    }
                }.frame(maxHeight: .infinity)
            }
        }
    }
    func label(_ i: Int) -> String { let f = eqBandFrequencies[i]; return f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f.rounded()))" }
}

/// Studio fader: thin track, centre mark, rectangular cap. Double-click resets to 0.
struct Fader: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var body: some View {
        GeometryReader { g in
            let h = g.size.height, capH: CGFloat = 14
            let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let y = (h - capH) * (1 - frac) + capH / 2
            ZStack {
                Capsule().fill(UI.raised).frame(width: 4)
                Rectangle().fill(UI.stroke).frame(width: 16, height: 1).position(x: g.size.width / 2, y: h / 2)
                Capsule().fill(UI.accent).frame(width: 4, height: abs(y - h / 2)).position(x: g.size.width / 2, y: (y + h / 2) / 2)
                RoundedRectangle(cornerRadius: 3).fill(UI.text).frame(width: 26, height: capH).position(x: g.size.width / 2, y: y)
                Rectangle().fill(UI.bg).frame(width: 12, height: 2).position(x: g.size.width / 2, y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let f = 1 - min(max((d.location.y - capH / 2) / (h - capH), 0), 1)
                value = ((range.lowerBound + Float(f) * (range.upperBound - range.lowerBound)) * 2).rounded() / 2
            })
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}

// MARK: - Right: bass knobs + effects

struct Effect: Identifiable {
    let id: String, name: String
    /// Reads the 0...1 amount from the DSP settings; writes it back (also off = 0).
    let get: (DSPSettings) -> Double
    let set: (inout DSPSettings, Double) -> Void
}

let effects: [Effect] = [
    Effect(id: "bass", name: "Bass",
           get: { Double($0[.bassBoostDB]) / 12 }, set: { $0[.bassBoostDB] = Float($1 * 12); $0[.subBassDB] = Float($1 * 6) }),
    Effect(id: "fidelity", name: "Fidelity",
           get: { Double($0[.clarity]) }, set: { $0[.clarity] = Float($1); $0[.trebleDB] = Float($1 * 3) }),
    Effect(id: "ambience", name: "Ambience",
           get: { Double(($0[.stereoWidth] - 1) / 0.8) }, set: { $0[.stereoWidth] = 1 + Float($1) * 0.8; $0[.bassMono] = $1 > 0 ? 1 : 0 }),
    Effect(id: "space", name: "Headphone Space",
           get: { $0[.crossfeedEnabled] > 0.5 ? Double(($0[.crossfeedFeedDB] - 1) / 14) * -1 + 1 : 0 },
           set: { $0[.crossfeedEnabled] = $1 > 0 ? 1 : 0; $0[.crossfeedFeedDB] = Float(15 - $1 * 14) }),
    Effect(id: "boost", name: "Dynamic Boost",
           get: { Double($0[.loudness]) }, set: { $0[.loudness] = Float($1); $0[.outputGainDB] = Float($1 * 4) }),
    Effect(id: "reverb", name: "Reverb",
           get: { Double($0[.reverbMix]) / 0.6 }, set: { $0[.reverbMix] = Float($1 * 0.6) }),
    Effect(id: "spatial", name: "3D Spatial",
           get: { Double($0[.spatial]) }, set: { $0[.spatial] = Float($1) }),
    Effect(id: "warmth", name: "Bass Harmonics",
           get: { Double($0[.bassHarmonics]) }, set: { $0[.bassHarmonics] = Float($1) }),
]

struct RightColumn: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 14) {
            let bass = effects[0]
            Panel {
                HStack(spacing: 0) {
                    RotaryKnob(value: Binding(get: { bass.get(m.settings.dsp) }, set: {
                        bass.set(&m.settings.dsp, $0); m.settings.dsp[.bassHarmonics] = Float($0 * 0.5); m.settings.selectedPresetID = nil; m.commit()
                    }), title: "Bass", display: "+\(Int((bass.get(m.settings.dsp) * 12).rounded()))", size: 104, ring: 8).frame(maxWidth: .infinity)
                    RotaryKnob(value: Binding(get: { Double(m.settings.dsp[.deepBass]) }, set: { m.set(.deepBass, Float($0)) }),
                               title: "Deep", display: "\(Int((m.settings.dsp[.deepBass] * 100).rounded()))", size: 104, ring: 8).frame(maxWidth: .infinity)
                }
            }
            Panel(padding: 14, fill: true) {
                VStack(spacing: 12) {
                    HStack(spacing: 4) { tab("EFFECTS", 0); tab("VIRTUAL MIC", 1) }
                    if m.rightTab == 0 { EffectsList() } else { MixerPanel() }
                }
            }
        }
    }
    func tab(_ title: String, _ i: Int) -> some View {
        Button { m.rightTab = i } label: {
            HStack(spacing: 6) {
                Text(title).font(UI.font(11, .heavy)).tracking(1.2)
                if i == 1 { FeedDot() }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(m.rightTab == i ? UI.raised : Color.clear))
            .foregroundStyle(m.rightTab == i ? UI.text : UI.muted)
        }.buttonStyle(.plain)
    }
}

/// Status dot on the VIRTUAL MIC tab (refreshes with the meters).
struct FeedDot: View {
    @EnvironmentObject var m: AppModel
    @EnvironmentObject var live: LiveTick
    var body: some View { Circle().fill(m.feedEnabled ? (m.feedLevel > 0.001 ? UI.green : UI.accent) : UI.stroke).frame(width: 6, height: 6) }
}

struct EffectsList: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 12) {
            ForEach(effects.dropFirst()) { fx in row(fx) }
            HStack(spacing: 8) {
                Text("Room size").font(UI.font(12)).foregroundStyle(UI.muted).frame(width: 118, alignment: .leading)
                FlatSlider(value: Binding(get: { Double(m.settings.dsp[.reverbSize]) }, set: { m.set(.reverbSize, Float($0)) }))
            }
            HStack(spacing: 8) {
                Text("Damping").font(UI.font(12)).foregroundStyle(UI.muted).frame(width: 118, alignment: .leading)
                FlatSlider(value: Binding(get: { Double(m.settings.dsp[.reverbDamping]) }, set: { m.set(.reverbDamping, Float($0)) }))
            }
            Spacer(minLength: 0)
        }
    }
    func row(_ fx: Effect) -> some View {
        let amount = fx.get(m.settings.dsp), on = amount > 0.01
        return HStack(spacing: 8) {
            Text(fx.name).font(UI.font(12.5)).foregroundStyle(on ? UI.text : UI.muted).frame(width: 118, alignment: .leading).lineLimit(1)
            FlatSlider(value: Binding(get: { amount }, set: { update(fx, $0) }))
            FlatSwitch(isOn: Binding(get: { on }, set: { update(fx, $0 ? 0.5 : 0) }))
        }
    }
    func update(_ fx: Effect, _ v: Double) { fx.set(&m.settings.dsp, v); m.settings.selectedPresetID = nil; m.commit() }
}

struct DBRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(UI.font(12.5)).foregroundStyle(UI.muted).frame(width: 60, alignment: .leading)
            FlatSlider(value: $value, range: range)
            Text(String(format: "%+.0f", value)).font(UI.font(11).monospacedDigit()).frame(width: 26, alignment: .trailing)
        }
    }
}

struct MiniBar: View {
    let title: String
    let level: Float
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(UI.font(10, .heavy)).tracking(1).foregroundStyle(UI.muted).frame(width: 60, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(UI.raised)
                    Capsule().fill(level > 0.9 ? UI.red : UI.muted).frame(width: max(0, g.size.width * CGFloat(min(max((level.linearToDB + 60) / 60, 0), 1))))
                }
            }.frame(height: 6)
        }
    }
}

struct MenuField: View {
    let text: String
    var body: some View {
        HStack { Text(text).font(UI.font(13)).lineLimit(1); Spacer()
            Image(systemName: "chevron.up.chevron.down").font(UI.font(10)).foregroundStyle(UI.muted) }
            .padding(.horizontal, 10).frame(height: 28).background(RoundedRectangle(cornerRadius: 6).fill(UI.raised))
    }
}

/// Virtual mic mixer: music from an app (or all system audio) plus optionally your own voice, both through the
/// enhancer's EQ/limiter, sent to the loopback device that chat apps use as their microphone.
struct MixerPanel: View {
    @EnvironmentObject var m: AppModel
    @EnvironmentObject var live: LiveTick
    var statusText: String {
        switch m.micFeed.status {
        case .off: return "Off. Pick “\(m.feedDeviceName ?? "BlackHole 2ch")” as the mic in Discord, Zoom or OBS."
        case .running: return "Discord: mic = \(m.feedDeviceName ?? "BlackHole 2ch"), turn off Noise Suppression. Use headphones so friends don’t hear echo."
        case .waiting(let s), .failed(let s): return s
        }
    }
    var dot: Color {
        switch m.micFeed.status {
        case .running: return m.feedLevel > 0.001 ? UI.green : UI.muted
        case .failed: return UI.red
        case .waiting: return UI.accent
        case .off: return UI.raised
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label2(text: "Send to virtual mic")
                Circle().fill(dot).frame(width: 7, height: 7)
                Spacer()
                FlatSwitch(isOn: Binding(get: { m.feedEnabled }, set: m.setFeed)).opacity(m.feedDeviceName == nil ? 0.4 : 1).disabled(m.feedDeviceName == nil)
            }
            if m.feedDeviceName != nil {
                Menu {
                    ForEach(m.feedSources) { src in Button(src.name) { m.setFeedSource(src) } }
                } label: { MenuField(text: m.feedSource.name) }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                DBRow(title: "Music", value: Binding(get: { m.feedGain }, set: m.setFeedGain), range: -30...6)
                Rectangle().fill(UI.stroke.opacity(0.6)).frame(height: 1)
                HStack(spacing: 8) {
                    Label2(text: "My voice")
                    Spacer()
                    FlatButton(title: m.feedVoiceMuted ? "MUTED" : "MUTE", on: m.feedVoiceMuted) { m.toggleVoiceMute() }
                    FlatSwitch(isOn: Binding(get: { m.feedVoiceOn }, set: m.setFeedVoice))
                }
                Menu {
                    Button("Default microphone") { m.setVoiceDevice(nil) }
                    ForEach(m.microphones) { d in Button(d.name) { m.setVoiceDevice(d.uid) } }
                } label: { MenuField(text: m.microphones.first { $0.uid == m.feedVoiceUID }?.name ?? "Default microphone") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                DBRow(title: "Voice", value: Binding(get: { m.feedVoiceGain }, set: m.setVoiceGain), range: -30...12)
                HStack {
                    Text("Duck music while I talk").font(UI.font(12.5))
                    Spacer()
                    FlatSwitch(isOn: Binding(get: { m.feedDuck }, set: m.setDuck))
                }
                MiniBar(title: "SEND", level: m.feedLevel)
                MiniBar(title: "MIC", level: m.voiceLevel)
                if let issue = m.micFeed.voiceIssue {
                    HStack(alignment: .top, spacing: 8) {
                        Text(issue).font(UI.font(11)).foregroundStyle(UI.red).fixedSize(horizontal: false, vertical: true)
                        if issue.hasPrefix("Microphone access") { FlatButton(title: "Open") { MicrophonePermission.openSystemSettings() } }
                    }
                } else {
                    Text(statusText).font(UI.font(11)).foregroundStyle(UI.muted).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Needs a virtual audio device so chat apps can use it as a mic.").font(UI.font(11.5)).foregroundStyle(UI.muted).fixedSize(horizontal: false, vertical: true)
                FlatButton(title: "Copy install command") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MicFeed.installCommand, forType: .string)
                }
                Text("Paste it in Terminal (asks for your password), then reopen EquAudio.").font(UI.font(11.5)).foregroundStyle(UI.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Bottom: recording + status

struct BottomBar: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Panel(padding: 12) {
            HStack(spacing: 14) {
                Button { m.toggleRecording() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(m.recording.isRecording ? UI.text : UI.red).frame(width: 10, height: 10)
                        Text(m.recording.isRecording ? "STOP" : "REC").font(UI.font(13, .heavy)).tracking(1)
                    }.padding(.horizontal, 16).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 6).fill(m.recording.isRecording ? UI.red : UI.raised))
                }.buttonStyle(.plain)
                Text(String(format: "%02d:%02d", Int(m.recording.duration) / 60, Int(m.recording.duration) % 60)).font(UI.font(18).monospacedDigit())
                Text(String(format: "%.1f MB", Double(m.recording.bytesOnDisk) / 1_048_576)).font(UI.font(12).monospacedDigit()).foregroundStyle(UI.muted)
                Menu {
                    ForEach(RecordingFormat.allCases) { f in Button(f.displayName) { m.settings.recording.format = f; m.commit() } }
                } label: {
                    HStack(spacing: 6) { Text(m.settings.recording.format.displayName).font(UI.font(12)); Image(systemName: "chevron.up.chevron.down").font(UI.font(9)).foregroundStyle(UI.muted) }
                        .padding(.horizontal, 10).frame(height: 30).background(RoundedRectangle(cornerRadius: 6).fill(UI.raised))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button { chooseFolder() } label: {
                    HStack(spacing: 6) { Image(systemName: "folder").font(UI.font(11)); Text(m.settings.recording.directoryPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(UI.font(12)).lineLimit(1).truncationMode(.middle) }
                        .padding(.horizontal, 10).frame(height: 30).frame(maxWidth: 190).background(RoundedRectangle(cornerRadius: 6).fill(UI.raised))
                }.buttonStyle(.plain)
                if let e = m.message ?? m.recording.lastError { Text(e).font(UI.font(12)).foregroundStyle(UI.red).lineLimit(1) }
                Spacer(minLength: 8)
                NowPlayingChip()
                Spacer(minLength: 8)
                StatusBar()
            }
        }
    }
    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let url = p.url { m.settings.recording.directoryPath = url.path; m.commit() }
    }
}

/// What is playing right now (any app), with cover art when the app provides it.
struct NowPlayingChip: View {
    @EnvironmentObject var m: AppModel
    var subtitle: String {
        guard let n = m.nowPlaying else { return "Play something to see it here" }
        let parts = [n.isPlaying ? nil : "Paused", n.artist.isEmpty ? nil : n.artist, n.app.isEmpty ? nil : n.app].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let art = m.nowPlayingArt {
                    Image(nsImage: art).resizable().scaledToFill()
                } else {
                    ZStack { UI.raised; Image(systemName: "music.note").font(UI.font(14)).foregroundStyle(UI.muted) }
                }
            }
            .frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(m.nowPlaying?.title ?? "Nothing playing").font(UI.font(13)).lineLimit(1)
                Text(subtitle).font(UI.font(11)).foregroundStyle(UI.muted).lineLimit(1)
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .opacity(m.nowPlaying?.isPlaying == false ? 0.6 : 1)
    }
}

struct StatusBar: View {
    @EnvironmentObject var m: AppModel
    @EnvironmentObject var live: LiveTick
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(UI.font(12)).foregroundStyle(UI.muted).lineLimit(1)
            if case .running = m.controller.status, m.meters.inputSilenceSeconds > 3 {
                FlatButton(title: "Permission…") { AudioCapturePermission.openSystemSettings() }
            }
        }
    }
    var color: Color { switch m.controller.status { case .running: return UI.green; case .stopped: return UI.muted; case .failed: return UI.red } }
    var text: String {
        switch m.controller.status {
        case .stopped: return AppModel.isSnapshot ? "Layout preview" : "Off — system audio plays unprocessed"
        case .failed(let e): return "Error: \(e)"
        case .running:
            if let n = m.controller.notice { return n }
            return m.meters.inputSilenceSeconds > 3 ? "No audio — nothing playing, or permission missing" : "Processing all system audio"
        }
    }
}

/// Menu bar popover: power, intensity, presets.
struct MenuPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("EquAudio").font(UI.font(15, .heavy)); Spacer()
                FlatSwitch(isOn: Binding(get: { m.settings.processingEnabled }, set: m.setPower))
            }
            HStack(spacing: 10) { Text("Intensity").font(UI.font(13)); FlatSlider(value: $m.intensity); Text("\(Int(m.intensity * 100))").font(UI.font(13).monospacedDigit()).frame(width: 30) }
            Picker("Preset", selection: Binding(get: { m.settings.selectedPresetID }, set: { id in if let id, let p = m.presets.preset(id: id) { m.apply(p) } })) {
                Text("Custom").tag(UUID?.none)
                ForEach(m.presets.allPresets) { Text($0.name).tag(UUID?.some($0.id)) }
            }.font(UI.font(13))
            HStack { Text("A/B original").font(UI.font(13)); Spacer(); FlatSwitch(isOn: Binding(get: { m.settings.bypass }, set: m.setBypass)) }
            Divider()
            HStack {
                FlatButton(title: "Open") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
                Spacer()
                FlatButton(title: "Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14).frame(width: 300).background(UI.bg).foregroundStyle(UI.text)
    }
}
