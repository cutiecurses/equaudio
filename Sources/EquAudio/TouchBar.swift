import AppKit
import EquAudioKit
import SwiftUI

extension NSTouchBarItem.Identifier {
    static let eqScope = NSTouchBarItem.Identifier("com.equaudio.touchbar.scope")
    static let eqOutput = NSTouchBarItem.Identifier("com.equaudio.touchbar.output")
    static let eqBass = NSTouchBarItem.Identifier("com.equaudio.touchbar.bass")
    static let eqPreset = NSTouchBarItem.Identifier("com.equaudio.touchbar.preset")
    static let eqBypass = NSTouchBarItem.Identifier("com.equaudio.touchbar.bypass")
    static let eqPower = NSTouchBarItem.Identifier("com.equaudio.touchbar.power")
    static let eqClose = NSTouchBarItem.Identifier("com.equaudio.touchbar.close")
    static let eqStrip = NSTouchBarItem.Identifier("com.equaudio.touchbar.strip")
}

/// Rolling output-level line (same data and look as the window's "Output level" chart).
final class ScopeButton: NSButton {
    /// Output level history, 0...1, oldest first.
    var samples: [Float] = [] { didSet { needsDisplay = true } }
    private let fixedWidth: CGFloat

    init(width: CGFloat) {
        fixedWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        title = ""
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: fixedWidth, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        let theme = UI.theme
        let box = bounds.insetBy(dx: 0, dy: 1)
        NSColor(theme.panel).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        let slice = Array(samples.suffix(max(2, Int(box.width / 1.5))))
        guard slice.count > 1 else { return }
        let top = box.maxY - 4, bottom = box.minY + 4
        func point(_ i: Int) -> NSPoint {
            NSPoint(x: box.minX + 4 + (box.width - 8) * CGFloat(i) / CGFloat(slice.count - 1),
                    y: bottom + (top - bottom) * CGFloat(min(max(slice[i], 0), 1)))
        }
        let line = NSBezierPath()
        line.appendSmoothCurve(through: (0..<slice.count).map(point))
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: point(slice.count - 1).x, y: bottom))
        fill.line(to: NSPoint(x: point(0).x, y: bottom))
        fill.close()
        NSColor(theme.accent).withAlphaComponent(0.22).setFill()
        fill.fill()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        NSColor(theme.accent).setStroke()
        line.stroke()
        let tip = point(slice.count - 1)
        NSColor(slice.last! > 0.97 ? UI.red : theme.text).setFill()
        NSBezierPath(ovalIn: NSRect(x: tip.x - 3, y: tip.y - 3, width: 6, height: 6)).fill()
    }
}

/// Segmented stereo LED meter (-60...0 dBFS) in the theme colours, same look as the window's IN/OUT meters.
/// It is a button so the Control Strip copy can be tapped to open the full Touch Bar controls.
final class MeterButton: NSButton {
    /// Smoothed left/right level, linear.
    var levels: (Float, Float) = (0, 0) { didSet { needsDisplay = true } }
    /// When set, the right part of the button draws this loudness line (0...1, oldest first) next to the LEDs.
    var samples: [Float]? { didSet { needsDisplay = true } }
    private let fixedWidth: CGFloat

    init(width: CGFloat) {
        fixedWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        title = ""
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func withScopeLine() { samples = [] }

    override var intrinsicContentSize: NSSize { NSSize(width: fixedWidth, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        let theme = UI.theme
        NSColor(theme.panel).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 7, yRadius: 7).fill()
        let scopeWidth: CGFloat = samples == nil ? 0 : bounds.width * 0.52
        let inner = NSRect(x: bounds.minX + 7, y: bounds.minY + 5.5, width: bounds.width - 14 - scopeWidth, height: bounds.height - 11)
        let gap: CGFloat = 2
        let count = max(6, Int(inner.width / 6))
        let segW = (inner.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let rowH = (inner.height - 3) / 2
        for (row, level) in [levels.0, levels.1].enumerated() {
            let y = inner.maxY - rowH - CGFloat(row) * (rowH + 3)
            let lit = Int((min(max((level.linearToDB + 60) / 60, 0), 1) * Float(count)).rounded())
            for i in 0..<count {
                let color: NSColor = i < lit ? (i >= count - 3 ? NSColor(UI.red) : i >= count - 10 ? NSColor(theme.accent) : NSColor(theme.muted)) : NSColor(theme.raised)
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: inner.minX + CGFloat(i) * (segW + gap), y: y, width: segW, height: rowH), xRadius: 1, yRadius: 1).fill()
            }
        }
        guard let samples, samples.count > 1 else { return }
        let box = NSRect(x: inner.maxX + 8, y: bounds.minY + 4, width: scopeWidth - 8 - 4, height: bounds.height - 8)
        let slice = Array(samples.suffix(max(2, Int(box.width / 1.5))))
        func point(_ i: Int) -> NSPoint {
            NSPoint(x: box.minX + box.width * CGFloat(i) / CGFloat(slice.count - 1), y: box.minY + box.height * CGFloat(min(max(slice[i], 0), 1)))
        }
        let line = NSBezierPath()
        line.appendSmoothCurve(through: (0..<slice.count).map(point))
        line.lineWidth = 1.8
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        NSColor(theme.accent).setStroke()
        line.stroke()
        let tip = point(slice.count - 1)
        NSColor(theme.text).setFill()
        NSBezierPath(ovalIn: NSRect(x: tip.x - 2.5, y: tip.y - 2.5, width: 5, height: 5)).fill()
    }
}

/// Touch Bar slider drawn as a filled pill with its name and value inside (macOS's own Touch Bar slider has a
/// fixed white knob that apps cannot restyle). Touch or drag anywhere on it to set the value.
final class TouchSlider: NSView {
    let kind: String
    private let title: String
    private let fixedWidth: CGFloat
    var value: Double = 0 { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    var format: ((Double) -> String)?

    init(kind: String, title: String, width: CGFloat) {
        self.kind = kind
        self.title = title
        fixedWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        allowedTouchTypes = .direct
        wantsRestingTouches = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: fixedWidth, height: 30) }

    private func handle(_ event: NSEvent) {
        guard let touch = event.touches(matching: .touching, in: self).first else { return }
        value = min(max(Double(touch.location(in: self).x / bounds.width), 0), 1)
        onChange?(value)
    }

    override func touchesBegan(with event: NSEvent) { handle(event) }
    override func touchesMoved(with event: NSEvent) { handle(event) }

    override func draw(_ dirtyRect: NSRect) {
        let theme = UI.theme
        let box = bounds.insetBy(dx: 0, dy: 1)
        let pill = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        NSColor(theme.raised).setFill()
        pill.fill()
        let filled = NSRect(x: box.minX, y: box.minY, width: max(box.height, box.width * CGFloat(value)), height: box.height)
        NSGraphicsContext.saveGraphicsState()
        pill.addClip()
        NSColor(theme.accent).setFill()
        NSBezierPath(rect: filled).fill()
        NSGraphicsContext.restoreGraphicsState()
        let font = NSFont.systemFont(ofSize: 12, weight: .heavy)
        let label = NSString(string: title.uppercased()), number = NSString(string: format?(value) ?? "\(Int((value * 100).rounded()))")
        func draw(_ color: NSColor) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: 0.8]
            let h = label.size(withAttributes: attrs).height
            label.draw(at: NSPoint(x: box.minX + 11, y: box.midY - h / 2), withAttributes: attrs)
            let w = number.size(withAttributes: attrs).width
            number.draw(at: NSPoint(x: box.maxX - 11 - w, y: box.midY - h / 2), withAttributes: attrs)
        }
        draw(NSColor(theme.text))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: filled).addClip()
        draw(NSColor(theme.onAccent))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Touch Bar support.
/// * A Control Strip button (system tray item) shows the live scope line in every app; tapping it opens the full
///   controls as a system-modal Touch Bar (✕ closes it).
/// * While EquAudio is frontmost its window shows the same controls in the app's Touch Bar.
/// The system-modal and Control Strip calls are private AppKit/DFRFoundation entry points (the same ones MTMR and
/// Pock use); each is looked up at run time and skipped with a log line if missing, so the app never depends on them.
final class TouchBarController: NSObject, NSTouchBarDelegate {
    private unowned let model: AppModel
    private let meters = NSHashTable<MeterButton>.weakObjects()
    private let scopes = NSHashTable<ScopeButton>.weakObjects()
    private let sliders = NSHashTable<TouchSlider>.weakObjects()
    private let toggleButtons = NSHashTable<NSButton>.weakObjects()
    private let pickers = NSHashTable<NSPickerTouchBarItem>.weakObjects()
    private var stripItem: NSCustomTouchBarItem?
    private var appBar: NSTouchBar?
    private var observers: [NSObjectProtocol] = []
    private var assertTimer: Timer?
    private var modalBar: NSTouchBar?
    private var lastSliderTouch = Date.distantPast
    private static let log = LogStore.shared
    private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

    init(model: AppModel) { self.model = model }

    // MARK: Install

    func install() {
        let bar = makeBar(modal: false)
        appBar = bar
        NSApp.touchBar = bar
        let item = NSCustomTouchBarItem(identifier: .eqStrip)
        let meter = MeterButton(width: 150)
        meter.withScopeLine()
        meter.target = self
        meter.action = #selector(toggleModal)
        meters.add(meter)
        item.view = meter
        item.customizationLabel = "EquAudio Level"
        if class_getClassMethod(NSTouchBarItem.self, NSSelectorFromString("addSystemTrayItem:")) != nil {
            (NSTouchBarItem.self as AnyObject).perform(NSSelectorFromString("addSystemTrayItem:"), with: item)
            Self.setStripPresence(true)
            stripItem = item
            Self.log.info("TouchBar", "Control Strip item installed")
            startKeepAlive()
        } else {
            Self.log.warning("TouchBar", "Control Strip API unavailable; Touch Bar shows only while EquAudio is frontmost")
        }
    }

    // MARK: Keeping the item alive
    // The system can drop a tray item or a system-modal bar when apps switch (a browser taking over the Touch Bar,
    // sleep/wake, a Touch Bar server restart). The presence call is cheap and idempotent, so it is repeated; the
    // full re-add (item + the app's own bar) runs when EquAudio becomes active again and after wake.

    private func startKeepAlive() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reassert(full: false)
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Self.log.info("TouchBar", "Re-adding Control Strip item after system event")
                self?.reassert(full: true)
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reassert(full: true)
        })
        assertTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.reassert(full: false) }
    }

    func reassert(full: Bool) {
        guard stripItem != nil else { return }
        Self.setStripPresence(true)
        guard full else { return }
        if let item = stripItem { (NSTouchBarItem.self as AnyObject).perform(NSSelectorFromString("addSystemTrayItem:"), with: item) }
        if let bar = appBar {
            NSApp.touchBar = bar
            NSApp.mainWindow?.touchBar = bar
        }
    }

    func uninstall() {
        assertTimer?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        dismissModal()
        if stripItem != nil { Self.setStripPresence(false) }
    }

    private static func setStripPresence(_ on: Bool) {
        guard let handle = dfr, let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        typealias Fn = @convention(c) (NSString, Bool) -> Void
        unsafeBitCast(sym, to: Fn.self)(NSTouchBarItem.Identifier.eqStrip.rawValue as NSString, on)
    }

    // MARK: System-modal bar

    /// Tapping the strip button always opens a fresh pop-up bar: the system may have closed the previous one on its
    /// own (app switch), so our own "is it open" flag cannot be trusted.
    @objc func toggleModal() {
        dismissModal()
        presentModal()
    }

    @objc func closeModal() { dismissModal() }

    func presentModal() {
        let sel = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        guard let method = class_getClassMethod(NSTouchBar.self, sel) else {
            Self.log.warning("TouchBar", "System-modal Touch Bar API unavailable"); return
        }
        let bar = makeBar(modal: true)
        typealias Fn = @convention(c) (AnyObject, Selector, NSTouchBar, Int, NSString?) -> Void
        unsafeBitCast(method_getImplementation(method), to: Fn.self)(NSTouchBar.self, sel, bar, 1, nil)
        modalBar = bar
    }

    func dismissModal() {
        guard let bar = modalBar else { return }
        (NSTouchBar.self as AnyObject).perform(NSSelectorFromString("dismissSystemModalTouchBar:"), with: bar)
        modalBar = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.reassert(full: true) }
    }

    // MARK: Bars and items

    private func makeBar(modal: Bool) -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = (modal ? [.eqClose] : []) + [.eqScope, .eqOutput, .eqBass, .eqPreset, .eqBypass, .eqPower]
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch id {
        case .eqScope:
            let item = NSCustomTouchBarItem(identifier: id)
            let meter = MeterButton(width: 250)
            meters.add(meter)
            item.view = meter
            return item
        case .eqOutput:
            let item = NSCustomTouchBarItem(identifier: id)
            let scope = ScopeButton(width: 230)
            scopes.add(scope)
            item.view = scope
            return item
        case .eqBass:
            return slider(id, kind: "bass", title: "Bass", value: effects[0].get(model.settings.dsp), format: { "+\(Int(($0 * 12).rounded())) dB" }) { [weak self] v in
                guard let self else { return }
                self.lastSliderTouch = Date()
                effects[0].set(&self.model.settings.dsp, v)
                self.model.settings.dsp[.bassHarmonics] = Float(v * 0.5)
                self.model.settings.selectedPresetID = nil
                self.model.commit()
            }
        case .eqPreset:
            let names = model.presets.allPresets.map(\.name)
            let item = NSPickerTouchBarItem(identifier: id, labels: names, selectionMode: .selectOne, target: self, action: #selector(presetPicked(_:)))
            item.controlRepresentation = .collapsed
            pickers.add(item)
            syncPicker(item)
            return item
        case .eqBypass:
            return button(id, title: "A/B", action: #selector(toggleBypass))
        case .eqPower:
            return button(id, title: "", image: NSImage(systemSymbolName: "power", accessibilityDescription: "Power"), action: #selector(togglePower))
        case .eqClose:
            return button(id, title: "", image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close"), action: #selector(closeModal))
        default:
            return nil
        }
    }

    private func slider(_ id: NSTouchBarItem.Identifier, kind: String, title: String, value: Double, format: @escaping (Double) -> String, onChange: @escaping (Double) -> Void) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: id)
        let slider = TouchSlider(kind: kind, title: title, width: 200)
        slider.format = format
        slider.value = value
        slider.onChange = onChange
        sliders.add(slider)
        item.view = slider
        return item
    }

    private func button(_ id: NSTouchBarItem.Identifier, title: String, image: NSImage? = nil, action: Selector) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: id)
        let b = NSButton(title: title, target: self, action: action)
        if let image { b.image = image; b.imagePosition = .imageOnly }
        b.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        toggleButtons.add(b)
        item.view = b
        return item
    }

    // MARK: Actions

    @objc private func presetPicked(_ item: NSPickerTouchBarItem) {
        let all = model.presets.allPresets
        if all.indices.contains(item.selectedIndex) { model.apply(all[item.selectedIndex]) }
    }

    @objc private func toggleBypass() { model.setBypass(!model.settings.bypass) }
    @objc private func togglePower() { model.setPower(!model.settings.processingEnabled) }

    // MARK: Refresh (from the model's 30 Hz timer)

    private func syncPicker(_ item: NSPickerTouchBarItem) {
        let all = model.presets.allPresets
        let index = model.settings.selectedPresetID.flatMap { id in all.firstIndex { $0.id == id } } ?? -1
        if index >= 0 { item.selectedIndex = index }
        item.collapsedRepresentationLabel = index >= 0 ? all[index].name : "Custom"
    }

    func refresh() {
        for meter in meters.allObjects { meter.levels = model.outLevel; if meter.samples != nil { meter.samples = model.scopeHistory } }
        for scope in scopes.allObjects { scope.samples = model.scopeHistory }
        guard model.tickCount % 8 == 0 else { return }
        if Date().timeIntervalSince(lastSliderTouch) > 0.7 {
            for slider in sliders.allObjects {
                slider.value = effects[0].get(model.settings.dsp)
            }
        }
        for picker in pickers.allObjects { syncPicker(picker) }
        for b in toggleButtons.allObjects {
            switch b.identifier?.rawValue {
            case NSTouchBarItem.Identifier.eqBypass.rawValue: b.bezelColor = model.settings.bypass ? NSColor(UI.theme.accent) : nil
            case NSTouchBarItem.Identifier.eqPower.rawValue: b.bezelColor = model.settings.processingEnabled ? NSColor(UI.theme.accent) : nil
            default: break
            }
        }
    }
}
