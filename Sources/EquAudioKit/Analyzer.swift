import Accelerate
import Foundation

/// Turns the engine's analysis taps into what the visualiser draws: log-spaced spectrum bands (output and input),
/// peak holds, a bass-energy / kick signal, stereo scope samples, a scrolling spectrogram and the EQ's measured
/// effect (output minus input) in the bass, mid and high regions. Main-thread object; call `update` ~30 times a second.
public final class Analyzer {
    public static let bandCount = 72
    public static let fftSize = 8192
    public static let scopeCount = 1024
    public static let historyColumns = 96
    public static let historyBands = 48

    /// Band centre frequencies in Hz (log-spaced, 30 Hz ... 18 kHz).
    public private(set) var bandFrequencies = [Float](repeating: 0, count: Analyzer.bandCount)
    /// Smoothed output spectrum, 0...1 (about -78 ... -12 dB with a +3 dB/octave tilt so highs are visible).
    public private(set) var bands = [Float](repeating: 0, count: Analyzer.bandCount)
    public private(set) var peaks = [Float](repeating: 0, count: Analyzer.bandCount)
    /// Smoothed input spectrum (before processing), same scale.
    public private(set) var inputBands = [Float](repeating: 0, count: Analyzer.bandCount)
    /// `bands` / `inputBands` smoothed across frequency, for drawing continuous curves.
    public private(set) var outputCurve = [Float](repeating: 0, count: Analyzer.bandCount)
    public private(set) var inputCurve = [Float](repeating: 0, count: Analyzer.bandCount)
    public private(set) var left = [Float](repeating: 0, count: Analyzer.scopeCount)
    public private(set) var right = [Float](repeating: 0, count: Analyzer.scopeCount)
    /// 0...1 energy of the output below ~120 Hz, and a 0...1 flash that jumps on bass onsets and decays.
    public private(set) var bass: Float = 0
    public private(set) var kick: Float = 0
    /// Ring ages (0...1) of the expanding rings spawned on bass onsets.
    public private(set) var rings: [Float] = []
    /// Average output-minus-input level in dB over the bass (30-120 Hz), mid (250 Hz-2 kHz) and high (4-16 kHz) regions.
    public private(set) var delta: (bass: Float, mid: Float, high: Float) = (0, 0, 0)
    /// Spectrogram columns (oldest first), each `historyBands` values 0...1.
    public private(set) var history = [[Float]](repeating: [Float](repeating: 0, count: Analyzer.historyBands), count: Analyzer.historyColumns)
    public private(set) var sampleRate: Double = 48000

    /// One FFT size with its own window and scratch buffers.
    private final class Plan {
        let n: Int
        let log2n: vDSP_Length
        let setup: FFTSetup
        var window: [Float]
        var windowed: [Float], real: [Float], imag: [Float], mags: [Float]

        init(n: Int) {
            self.n = n
            log2n = vDSP_Length(log2(Double(n)).rounded())
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            window = [Float](repeating: 0, count: n)
            vDSP_hann_window(&window, vDSP_Length(n), Int32(0))
            windowed = [Float](repeating: 0, count: n)
            real = [Float](repeating: 0, count: n / 2)
            imag = [Float](repeating: 0, count: n / 2)
            mags = [Float](repeating: 0, count: n / 2)
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        /// dBFS spectrum of the last `n` samples of `x`. A full-scale sine on a bin centre reads about 0 dB.
        func dB(_ x: [Float]) -> [Float] {
            let half = n / 2
            precondition(x.count >= n)
            let start = x.count - n
            x.withUnsafeBufferPointer { xp in vDSP_vmul(xp.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n)) }
            windowed.withUnsafeBufferPointer { wp in
                wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                    real.withUnsafeMutableBufferPointer { rp in
                        imag.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                            vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                        }
                    }
                }
            }
            // zrip scales by 2 and the Hann window has a coherent gain of 0.5, so amplitude = magnitude * 2 / n.
            var scale = 2 / Float(n), eps: Float = 1e-9, one: Float = 1
            vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(half))
            vDSP_vsadd(mags, 1, &eps, &mags, 1, vDSP_Length(half))
            var db = [Float](repeating: 0, count: half)
            vDSP_vdbcon(mags, 1, &one, &db, 1, vDSP_Length(half), 1)
            db[0] = db[1]
            return db
        }
    }

    /// Multi-resolution: long windows for the bass (fine frequency detail), short ones for mids and highs so the
    /// display reacts in time with the music (about 20 ms at 48 kHz instead of 170 ms).
    private let plans = [Plan(n: 8192), Plan(n: 2048), Plan(n: 1024)]
    private func plan(for frequency: Float) -> Int { frequency < 140 ? 0 : (frequency < 1400 ? 1 : 2) }
    private var inBuf: [Float] = [], lBuf: [Float] = [], rBuf: [Float] = []
    private var mono = [Float](repeating: 0, count: Analyzer.fftSize)
    private var previousBass: Float = 0
    private var deltaSmooth: (Float, Float, Float) = (0, 0, 0)
    private var lastUpdate = ProcessInfo.processInfo.systemUptime
    private var lastKick = 0.0
    private var historyAccumulator: Float = 0

    public init() {}

    // MARK: Spectrum

    /// Magnitude spectrum in dBFS of the last 8192 samples of `x` (bin k is k * sampleRate / 8192).
    public func spectrumDB(_ x: [Float]) -> [Float] { plans[0].dB(x) }

    /// dB per log band: interpolated between bins where bands are narrower than a bin, else the loudest bin inside.
    /// Each band reads the FFT size that suits its frequency (see `plans`).
    private func bandDB(_ spectra: [[Float]]) -> [Float] {
        let top = min(18_000, Float(sampleRate) * 0.46)
        let ratio = powf(top / 30, 1 / Float(Analyzer.bandCount))
        var out = [Float](repeating: -120, count: Analyzer.bandCount)
        for i in 0..<Analyzer.bandCount {
            let lo = 30 * powf(ratio, Float(i)), hi = lo * ratio, centre = sqrtf(lo * hi)
            bandFrequencies[i] = centre
            let k = plan(for: centre), db = spectra[k]
            let binHz = Float(sampleRate) / Float(plans[k].n)
            let a = Int(lo / binHz), b = Int(hi / binHz)
            if b - a <= 1 {
                let pos = centre / binHz, i0 = min(Int(pos), db.count - 2), frac = pos - Float(i0)
                out[i] = db[i0] * (1 - frac) + db[i0 + 1] * frac
            } else {
                out[i] = db[a..<min(b, db.count)].max() ?? -120
            }
        }
        return out
    }

    private func normalised(_ dbBands: [Float]) -> [Float] {
        dbBands.enumerated().map { i, db in
            let tilt = 3 * log2f(max(bandFrequencies[i], 1) / 1000)
            return min(max((db + tilt + 78) / 66, 0), 1)
        }
    }

    // MARK: Update

    /// `dt` (seconds since the previous call) is measured unless given; every decay below is per second, so the
    /// display behaves the same at 30, 60 or 120 updates a second.
    public func update(engine: DSPEngine, dt explicitDT: Float? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = explicitDT ?? Float(min(max(now - lastUpdate, 0.004), 0.1))
        lastUpdate = now
        sampleRate = engine.sampleRate
        engine.readAnalysis(count: Analyzer.fftSize, input: &inBuf, left: &lBuf, right: &rBuf)
        vDSP_vadd(lBuf, 1, rBuf, 1, &mono, 1, vDSP_Length(Analyzer.fftSize))
        var half: Float = 0.5
        vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(Analyzer.fftSize))
        let outDB = bandDB(plans.map { $0.dB(mono) }), inDB = bandDB(plans.map { $0.dB(inBuf) })
        let outN = normalised(outDB), inN = normalised(inDB)
        let fall = 1.7 * dt, peakFall = 0.36 * dt                 // units per second: ~110 dB/s and ~24 dB/s
        for i in 0..<Analyzer.bandCount {
            bands[i] = max(outN[i], bands[i] - fall)
            inputBands[i] = max(inN[i], inputBands[i] - fall)
            peaks[i] = max(bands[i], peaks[i] - peakFall)
        }
        outputCurve = smoothed(bands)
        inputCurve = smoothed(inputBands)
        left = Array(lBuf.suffix(Analyzer.scopeCount))
        right = Array(rBuf.suffix(Analyzer.scopeCount))
        updateBass(dt: dt, now: now)
        updateDelta(outDB: outDB, inDB: inDB, dt: dt)
        historyAccumulator += dt
        if historyAccumulator >= 1.0 / 30 { historyAccumulator = 0; pushHistory() }
    }

    /// 3-tap smoothing across frequency, so the Impact curves read as curves and not as noise.
    private func smoothed(_ v: [Float]) -> [Float] {
        // Spelled out with explicit types: older compilers (Swift 6.1) give up on the one-line form.
        let last = v.count - 1
        return (0..<v.count).map { (i: Int) -> Float in
            let before: Float = v[max(i - 1, 0)]
            let here: Float = v[i]
            let after: Float = v[min(i + 1, last)]
            return 0.25 * before + 0.5 * here + 0.25 * after
        }
    }

    private func updateBass(dt: Float, now: Double) {
        let idx = bandFrequencies.indices.filter { bandFrequencies[$0] <= 120 }
        bass = idx.isEmpty ? 0 : idx.map { bands[$0] }.reduce(0, +) / Float(idx.count)
        let rise = (bass - previousBass) / max(dt * 30, 0.2)       // rise per 33 ms
        if rise > 0.07 && bass > 0.45 && now - lastKick > 0.12 {
            kick = 1; rings.append(0); lastKick = now
        } else {
            kick *= powf(0.86, dt * 30)
        }
        previousBass = bass
        rings = rings.map { $0 + 0.9 * dt }.filter { $0 < 1 }
    }

    private func updateDelta(outDB: [Float], inDB: [Float], dt: Float) {
        func avg(_ lo: Float, _ hi: Float) -> Float {
            let idx = bandFrequencies.indices.filter { bandFrequencies[$0] >= lo && bandFrequencies[$0] <= hi && inDB[$0] > -75 }
            return idx.isEmpty ? 0 : idx.map { outDB[$0] - inDB[$0] }.reduce(0, +) / Float(idx.count)
        }
        let target = (avg(30, 120), avg(250, 2000), avg(4000, 16000))
        let k = min(1, 3.6 * dt)
        deltaSmooth = (deltaSmooth.0 + (target.0 - deltaSmooth.0) * k, deltaSmooth.1 + (target.1 - deltaSmooth.1) * k, deltaSmooth.2 + (target.2 - deltaSmooth.2) * k)
        delta = (deltaSmooth.0, deltaSmooth.1, deltaSmooth.2)
    }

    private func pushHistory() {
        let ratio = Analyzer.bandCount / Analyzer.historyBands
        var column = [Float](repeating: 0, count: Analyzer.historyBands)
        for i in 0..<Analyzer.historyBands { column[i] = (bands[i * ratio] + bands[min(i * ratio + 1, Analyzer.bandCount - 1)]) / 2 }
        history.append(column)
        history.removeFirst()
    }

    // MARK: Demo data (layout previews)

    public func fillDemo() {
        sampleRate = 48000
        let top: Float = 18_000, ratio = powf(top / 30, 1 / Float(Analyzer.bandCount))
        for i in 0..<Analyzer.bandCount {
            let f = 30 * powf(ratio, Float(i) + 0.5), x = Float(i) / Float(Analyzer.bandCount)
            bandFrequencies[i] = f
            let shape = 0.82 - 0.55 * x + 0.12 * sinf(x * 23) + 0.18 * expf(-powf((f - 60) / 40, 2))
            bands[i] = min(max(shape, 0.05), 0.98)
            peaks[i] = min(bands[i] + 0.06 + 0.04 * sinf(x * 40), 1)
            inputBands[i] = min(max(bands[i] - 0.22 * expf(-x * 4) - 0.04 + 0.05 * sinf(x * 11), 0.03), 0.95)
        }
        left = (0..<Analyzer.scopeCount).map { (n: Int) -> Float in
            let t = Float(n)
            return 0.5 * sinf(t * 0.09) + 0.25 * sinf(t * 0.41 + 1) + 0.12 * sinf(t * 1.3)
        }
        right = (0..<Analyzer.scopeCount).map { (n: Int) -> Float in
            let t = Float(n)
            return 0.5 * sinf(t * 0.09 + 0.25) + 0.22 * sinf(t * 0.37) + 0.12 * sinf(t * 1.1 + 2)
        }
        outputCurve = bands; inputCurve = inputBands
        bass = 0.74; kick = 0.6; rings = [0.12, 0.45, 0.78]
        delta = (9.2, 0.8, 2.4)
        history = (0..<Analyzer.historyColumns).map { c in
            (0..<Analyzer.historyBands).map { b in
                let x = Float(b) / Float(Analyzer.historyBands)
                return min(max(0.75 - 0.6 * x + 0.25 * sinf(Float(c) * 0.25 + x * 9) * (1 - x) + (c % 24 < 3 ? 0.25 * (1 - x) : 0), 0), 1)
            }
        }
    }
}
