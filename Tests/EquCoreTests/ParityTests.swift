import EquCore
import Foundation
import Testing

/// The virtual mic runs a second engine at the loopback device's rate (48 kHz) while the output engine runs at the
/// output device's rate (96 kHz on this Mac). With identical settings both must produce the same spectrum.
@Suite("Sample-rate parity")
struct ParityTests {
    static let settings: [String: Float] = ["auto_headroom": 1, "bass_boost_db": 12, "bass_harmonics": 0.5, "bass_mono": 1, "clarity": 0.25, "crossfeed": 0, "crossfeed_db": 4.5, "crossfeed_hz": 700, "deep_bass": 1, "eq_125": 4, "eq_16k": 1.5, "eq_1k": 0, "eq_250": 1.5, "eq_2k": 0.5, "eq_31": 5, "eq_4k": 1, "eq_500": -0.5, "eq_62": 5.5, "eq_8k": 1.5, "eq_enabled": 1, "limiter": 1, "limiter_ceiling_db": -1, "limiter_release_ms": 150, "limiter_true_peak": 1, "loudness": 0.3, "output_db": 0, "preamp_db": 0, "reverb_damping": 0.5, "reverb_mix": 0.2809, "reverb_size": 0.5, "spatial": 0.5, "stereo_width": 1.1, "sub_bass_db": 6, "treble_db": 0, "voice_duck": 0, "voice_gain_db": 0, "voice_mute": 0]

    private func goertzelDB(_ x: ArraySlice<Float>, _ f: Double, _ fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs, c = 2 * cos(w); var s1 = 0.0, s2 = 0.0
        for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
        let p = s1 * s1 + s2 * s2 - c * s1 * s2
        return 20 * log10(max(2 * sqrt(max(p, 0)) / Double(x.count), 1e-12))
    }

    /// Output level in dB of each test tone for an engine running at `fs`.
    private func levels(fs: Double, tones: [Double], inputDB: Double, limiterOff: Bool = false) -> [Double] {
        let e = equ_engine_create()!; defer { equ_engine_destroy(e) }
        equ_engine_prepare(e, fs, 4096)
        for (id, value) in Self.settings {
            var p = EquParam.bypass
            if equ_param_from_identifier(id, &p), p != .bypass { equ_engine_set_param(e, p, value) }
        }
        equ_engine_set_param(e, .reverbMix, 0)   // a reverb rings differently per tone and rate; compared separately
        if limiterOff { equ_engine_set_param(e, .limiterEnabled, 0) }
        let n = Int(fs * 4), amp = Float(pow(10, inputDB / 20))
        var l = (0..<n).map { i in tones.reduce(Float(0)) { $0 + amp * Float(sin(2 * .pi * $1 * Double(i) / fs)) } }, r = l
        equ_engine_process(e, l, r, &l, &r, UInt32(n))
        let window = Int(fs * 1.0)..<Int(fs * 3.0)
        return tones.map { goertzelDB(l[window], $0, fs) }
    }

    @Test func sameSpectrumAt48And96kHz() {
        let tones: [Double] = [45, 60, 80, 110, 160, 250, 500, 1000, 4000, 10000]
        for inputDB in [-34.0, -24.0] {
            let hi = levels(fs: 96000, tones: tones, inputDB: inputDB), lo = levels(fs: 48000, tones: tones, inputDB: inputDB)
            print("input per tone \(inputDB) dBFS")
            for (i, f) in tones.enumerated() { print(String(format: "  %6.0f Hz   96k %7.2f dB   48k %7.2f dB   diff %+.2f", f, hi[i], lo[i], lo[i] - hi[i])) }
            for i in tones.indices { #expect(abs(lo[i] - hi[i]) < 1.0, "\(tones[i]) Hz differs by \(lo[i] - hi[i]) dB at input \(inputDB)") }
        }
    }
}

extension ParityTests {
    @Test func linearResponseMatchesWithoutLimiter() {
        let tones: [Double] = [45, 80, 250, 500, 1000, 2000, 3000, 4000, 8000, 10000, 15000]
        let hi = levels(fs: 96000, tones: tones, inputDB: -60, limiterOff: true), lo = levels(fs: 48000, tones: tones, inputDB: -60, limiterOff: true)
        print("linear (-60 dBFS, limiter off)")
        for (i, f) in tones.enumerated() { print(String(format: "  %6.0f Hz   96k %7.2f dB   48k %7.2f dB   diff %+.2f", f, hi[i], lo[i], lo[i] - hi[i])) }
    }
}

extension ParityTests {
    /// Each saved setting alone (others default): which one makes the 48 kHz and 96 kHz engines disagree?
    @Test func bisectWhichSettingDiffersByRate() {
        let tones: [Double] = [45, 80, 250, 500, 1000, 2000, 3000, 4000, 8000, 10000]
        func run(fs: Double, id: String, value: Float) -> [Double] {
            let e = equ_engine_create()!; defer { equ_engine_destroy(e) }
            equ_engine_prepare(e, fs, 4096)
            var p = EquParam.bypass
            if equ_param_from_identifier(id, &p) { equ_engine_set_param(e, p, value) }
            equ_engine_set_param(e, .limiterEnabled, 0); equ_engine_set_param(e, .autoHeadroom, 0)
            let n = Int(fs * 3), amp = Float(pow(10, -40.0 / 20))
            var l = (0..<n).map { i in tones.reduce(Float(0)) { $0 + amp * Float(sin(2 * .pi * $1 * Double(i) / fs)) } }, r = l
            equ_engine_process(e, l, r, &l, &r, UInt32(n))
            let w = Int(fs * 1.0)..<Int(fs * 2.5)
            return tones.map { goertzelDB(l[w], $0, fs) }
        }
        var rows: [(String, Double, Double)] = []
        for (id, value) in Self.settings {
            let a = run(fs: 96000, id: id, value: value), b = run(fs: 48000, id: id, value: value)
            let diffs = zip(a, b).map { $1 - $0 }
            let worst = diffs.enumerated().max { abs($0.element) < abs($1.element) }!
            rows.append((id, worst.element, tones[worst.offset]))
        }
        for r in rows.sorted(by: { abs($0.1) > abs($1.1) }).prefix(8) { print(String(format: "  %@ -> worst %+.2f dB at %.0f Hz", r.0, r.1, r.2)) }
    }
}
