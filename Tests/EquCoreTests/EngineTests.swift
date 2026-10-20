import EquCore
import Foundation
import Testing

private func run(_ configure: (OpaquePointer) -> Void, freq: Double, levelDB: Double, seconds: Double = 1.0, fs: Double = 48000) -> (out: [Float], inp: [Float]) {
    let e = equ_engine_create()!
    defer { equ_engine_destroy(e) }
    equ_engine_prepare(e, fs, 4096)
    configure(e)
    let n = Int(seconds * fs), a = Float(pow(10, levelDB / 20))
    var l = (0..<n).map { a * Float(sin(2 * .pi * freq * Double($0) / fs)) }, r = l
    let inp = l
    // Warm up so smoothing settles, then measure on a second pass of the same length.
    for _ in 0..<2 { equ_engine_process(e, l, r, &l, &r, UInt32(n)); if true { l = inp; r = inp } }
    equ_engine_process(e, l, r, &l, &r, UInt32(n))
    return (l, inp)
}

private func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)) }

@Suite("Engine DSP")
struct EngineTests {
    @Test func bandBoostMatchesResponseAndRealProcessing() {
        let r = run({ e in
            equ_engine_set_param(e, .autoHeadroom, 0); equ_engine_set_param(e, .limiterEnabled, 0)
            equ_engine_set_param(e, .eqBand5, 12)
        }, freq: 1000, levelDB: -30)
        let gain = 20 * log10(rms(r.out[20000..<40000]) / rms(r.inp[20000..<40000]))
        #expect(abs(gain - 12) < 1.5, "measured \(gain) dB")
    }

    @Test func otherBandsStayNearUnity() {
        let r = run({ e in equ_engine_set_param(e, .autoHeadroom, 0); equ_engine_set_param(e, .limiterEnabled, 0); equ_engine_set_param(e, .eqBand5, 12) },
                    freq: 60, levelDB: -30)
        let gain = 20 * log10(rms(r.out[20000..<40000]) / rms(r.inp[20000..<40000]))
        #expect(abs(gain) < 1.0, "60 Hz moved by \(gain) dB")
    }

    @Test func limiterNeverExceedsCeiling() {
        let r = run({ e in equ_engine_set_param(e, .preampDB, 12); equ_engine_set_param(e, .autoHeadroom, 0) }, freq: 500, levelDB: -1)
        let peak = r.out[2000...].map { abs($0) }.max()!
        #expect(peak <= Float(pow(10, -1.0 / 20)) + 0.001, "peak \(peak)")
    }

    @Test func autoHeadroomKeepsLevelWhenBoosting() {
        let r = run({ e in equ_engine_set_param(e, .limiterEnabled, 0); for b in 0..<10 { equ_engine_set_param(e, EquParam(rawValue: EquParam.eqBand0.rawValue + UInt32(b))!, 6) } },
                    freq: 1000, levelDB: -20)
        let gain = 20 * log10(rms(r.out[20000..<40000]) / rms(r.inp[20000..<40000]))
        #expect(gain < 3.5 && gain > -1, "level changed by \(gain) dB (would be ~+10 without headroom)")
    }

    @Test func bypassIsExactlyTheDelayedInput() {
        let r = run({ e in equ_engine_set_param(e, .bypass, 1); equ_engine_set_param(e, .eqBand5, 12) }, freq: 1000, levelDB: -12, seconds: 2)
        let lat = Int(95)
        var maxErr: Float = 0
        for i in 60000..<90000 { maxErr = max(maxErr, abs(r.out[i] - r.inp[i - lat])) }
        #expect(maxErr < 1e-4, "bypass error \(maxErr)")
    }

    @Test func nonFiniteInputGivesFiniteOutput() {
        let e = equ_engine_create()!; defer { equ_engine_destroy(e) }
        equ_engine_prepare(e, 48000, 512)
        var l = [Float](repeating: .nan, count: 512), r = [Float](repeating: .infinity, count: 512)
        equ_engine_process(e, l, r, &l, &r, 512)
        #expect(l.allSatisfy { $0.isFinite && abs($0) <= 1 } && r.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test func allParametersRandomisedStayBounded() {
        let e = equ_engine_create()!; defer { equ_engine_destroy(e) }
        equ_engine_prepare(e, 48000, 256)
        var rng = SystemRandomNumberGenerator()
        var l = [Float](repeating: 0, count: 256), r = l
        for block in 0..<400 {
            for p in 1..<EquParam.count.rawValue { equ_engine_set_param(e, EquParam(rawValue: p)!, Float.random(in: -30...30, using: &rng)) }
            for i in 0..<256 { l[i] = Float.random(in: -1...1, using: &rng); r[i] = Float.random(in: -1...1, using: &rng) }
            equ_engine_process(e, l, r, &l, &r, 256)
            #expect(l.allSatisfy { $0.isFinite && abs($0) <= 1 }, "block \(block)")
        }
    }
}

@Suite("Headroom")
struct HeadroomTests {
    @Test func bassBoostDoesNotMakeEverythingQuieter() {
        // A mid-range tone must stay within 1.5 dB of its original level when bass is boosted.
        let r = run({ e in equ_engine_set_param(e, .limiterEnabled, 0); equ_engine_set_param(e, .bassBoostDB, 12); equ_engine_set_param(e, .subBassDB, 4) },
                    freq: 1000, levelDB: -20)
        let gain = 20 * log10(rms(r.out[20000..<40000]) / rms(r.inp[20000..<40000]))
        #expect(gain > -5 && gain < 0.5, "1 kHz moved by \(gain) dB when boosting bass")
    }
}

@Suite("Reverb and spatial")
struct ReverbTests {
    private func noise(_ n: Int) -> [Float] { var g = SystemRandomNumberGenerator(); return (0..<n).map { _ in Float.random(in: -0.3...0.3, using: &g) } }

    @Test func reverbAddsATailAndMixZeroAddsNone() {
        func tailEnergy(mix: Float) -> Double {
            let e = equ_engine_create()!; defer { equ_engine_destroy(e) }
            equ_engine_prepare(e, 48000, 4096)
            equ_engine_set_param(e, .autoHeadroom, 0); equ_engine_set_param(e, .limiterEnabled, 0)
            equ_engine_set_param(e, .reverbMix, mix)
            var l = noise(24000) + [Float](repeating: 0, count: 48000), r = l
            for i in 0..<l.count { l[i] = i < 24000 ? l[i] : 0; r[i] = l[i] }
            let n = UInt32(l.count)
            equ_engine_process(e, l, r, &l, &r, n)
            return rms(l[40000..<70000])
        }
        #expect(tailEnergy(mix: 0) < 1e-9)
        #expect(tailEnergy(mix: 0.5) > 1e-4)
    }

    @Test func reverbLevelIsReasonable() {
        // Full reverb on noise should be audible but not dominate: wet+dry within 0..+8 dB of dry.
        func level(mix: Float) -> Double {
            let e = equ_engine_create()!; defer { equ_engine_destroy(e) }
            equ_engine_prepare(e, 48000, 4096)
            equ_engine_set_param(e, .autoHeadroom, 0); equ_engine_set_param(e, .limiterEnabled, 0); equ_engine_set_param(e, .reverbMix, mix)
            var l = noise(96000), r = noise(96000)
            equ_engine_process(e, l, r, &l, &r, 96000)
            return rms(l[48000...])
        }
        let delta = 20 * log10(level(mix: 1) / level(mix: 0))
        print("reverb mix=1 level change: \(delta) dB")
        #expect(delta > 0.5 && delta < 8, "delta \(delta)")
    }

    @Test func spatialAndReverbStayStableAndBounded() {
        let e = equ_engine_create()!; defer { equ_engine_destroy(e) }
        equ_engine_prepare(e, 96000, 512)
        for p in [EquParam.reverbMix, .reverbSize, .reverbDamping, .spatial] { equ_engine_set_param(e, p, 1) }
        var g = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var l = (0..<512).map { _ in Float.random(in: -1...1, using: &g) }, r = l.map { _ in Float.random(in: -1...1, using: &g) }
            equ_engine_process(e, l, r, &l, &r, 512)
            #expect(l.allSatisfy { $0.isFinite && abs($0) <= 1 } && r.allSatisfy { $0.isFinite && abs($0) <= 1 })
        }
    }

    @Test func spatialKeepsMonoSumOfBassIntact() {
        // 80 Hz mono-ish tone is below the side lift region; level must stay within 1 dB.
        let r = run({ e in equ_engine_set_param(e, .autoHeadroom, 0); equ_engine_set_param(e, .limiterEnabled, 0); equ_engine_set_param(e, .spatial, 1) }, freq: 80, levelDB: -20)
        let gain = 20 * log10(rms(r.out[20000..<40000]) / rms(r.inp[20000..<40000]))
        #expect(abs(gain) < 1.0, "80 Hz changed \(gain) dB")
    }
}

@Suite("Deep bass")
struct DeepBassTests {
    private func goertzelDB(_ x: ArraySlice<Float>, _ f: Double, _ fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs, c = 2 * cos(w); var s1 = 0.0, s2 = 0.0
        for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
        let p = s1 * s1 + s2 * s2 - c * s1 * s2
        return 20 * log10(max(2 * sqrt(max(p, 0)) / Double(x.count), 1e-12))
    }

    @Test func octaveDownAppearsOnlyWhenEnabled() {
        func levels(_ deep: Float) -> (sub: Double, fundamental: Double) {
            let r = run({ e in equ_engine_set_param(e, .autoHeadroom, 0); equ_engine_set_param(e, .limiterEnabled, 0); equ_engine_set_param(e, .deepBass, deep) }, freq: 80, levelDB: -18)
            return (goertzelDB(r.out[20000..<44000], 40, 48000), goertzelDB(r.out[20000..<44000], 80, 48000))
        }
        let off = levels(0), on = levels(1)
        print("deep off: 40 Hz \(off.sub) dB, on: 40 Hz \(on.sub) dB, 80 Hz \(on.fundamental) dB")
        #expect(off.sub < -80)
        #expect(on.sub > on.fundamental - 12, "40 Hz only \(on.sub) vs 80 Hz \(on.fundamental)")
        #expect(on.sub < on.fundamental + 6, "sub is too hot")
    }

    @Test func noSubharmonicBelowTheAudibleBand() {
        // A 30 Hz tone must not be divided down to 15 Hz.
        let r = run({ e in equ_engine_set_param(e, .autoHeadroom, 0); equ_engine_set_param(e, .limiterEnabled, 0); equ_engine_set_param(e, .deepBass, 1) }, freq: 30, levelDB: -18)
        #expect(goertzelDB(r.out[20000..<44000], 15, 48000) < -45)
    }
}

@Suite("Voice mix")
struct VoiceTests {
    private func render(voiceDB: Float = 0, mute: Float = 0, duck: Float = 0, music: Float = 0.2, voice: Float = 0.2, seconds: Double = 1.5) -> (out: [Float], musicOnly: [Float]) {
        let fs = 48000.0, n = Int(seconds * fs)
        let e = equ_engine_create()!; defer { equ_engine_destroy(e) }
        equ_engine_prepare(e, fs, 4096)
        equ_engine_set_param(e, .autoHeadroom, 0); equ_engine_set_param(e, .limiterEnabled, 0)
        equ_engine_set_param(e, .voiceGainDB, voiceDB); equ_engine_set_param(e, .voiceMute, mute); equ_engine_set_param(e, .voiceDuck, duck)
        var l = (0..<n).map { music * Float(sin(2 * .pi * 200 * Double($0) / fs)) }, r = l
        let v = (0..<n).map { voice * Float(sin(2 * .pi * 1000 * Double($0) / fs)) }
        let dry = l
        equ_engine_process_voice(e, l, r, v, &l, &r, UInt32(n))
        return (l, dry)
    }
    private func tone(_ x: ArraySlice<Float>, _ f: Double) -> Double {
        let fs = 48000.0, w = 2 * Double.pi * f / fs, c = 2 * cos(w); var s1 = 0.0, s2 = 0.0
        for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
        return 2 * sqrt(max(s1 * s1 + s2 * s2 - c * s1 * s2, 0)) / Double(x.count)
    }

    @Test func voiceIsMixedAtItsGain() {
        let r = render(voiceDB: -6)
        let level = tone(r.out[40000..<60000], 1000)
        #expect(abs(20 * log10(level / 0.2) + 6) < 0.5, "voice at \(20 * log10(level / 0.2)) dB, expected -6")
        #expect(abs(tone(r.out[40000..<60000], 200) - 0.2) < 0.02, "music was disturbed")
    }

    @Test func muteSilencesVoiceOnly() {
        let r = render(mute: 1)
        #expect(tone(r.out[40000..<60000], 1000) < 1e-3)
        #expect(tone(r.out[40000..<60000], 200) > 0.15)
    }

    @Test func duckLowersMusicWhileVoiceIsActive() {
        let ducked = tone(render(duck: 1).out[40000..<60000], 200)
        let plain = tone(render(duck: 0).out[40000..<60000], 200)
        print("music with duck \(20 * log10(ducked / plain)) dB")
        #expect(20 * log10(ducked / plain) < -8)
    }

    @Test func noVoiceMeansNoChange() {
        let e = equ_engine_create()!; defer { equ_engine_destroy(e) }
        equ_engine_prepare(e, 48000, 4096)
        equ_engine_set_param(e, .voiceDuck, 1); equ_engine_set_param(e, .autoHeadroom, 0); equ_engine_set_param(e, .limiterEnabled, 0)
        var l = (0..<48000).map { 0.2 * Float(sin(2 * .pi * 200 * Double($0) / 48000)) }, r = l
        equ_engine_process(e, l, r, &l, &r, 48000)
        #expect(abs(tone(l[20000..<40000], 200) - 0.2) < 0.005)
    }
}

@Suite("Short-term loudness meter")
struct LoudnessMeterTests {
    @Test func fastRMSTracksLevelWhilePeaksStayAtTheCeiling() {
        let e = equ_engine_create()!; defer { equ_engine_destroy(e) }
        equ_engine_prepare(e, 48000, 4096)
        equ_engine_set_param(e, .autoHeadroom, 0)
        // A loud 100 Hz tone through +12 dB hits the limiter ceiling; halving the input must still lower the RMS reading.
        func rms(at amp: Float) -> Float {
            equ_engine_set_param(e, .preampDB, 12)
            var l = (0..<48000).map { amp * Float(sin(2 * .pi * 100 * Double($0) / 48000)) }, r = l
            equ_engine_process(e, l, r, &l, &r, 48000)
            var m = EquMeters(); equ_engine_read_meters(e, &m)
            return m.outputRMSFast.0
        }
        let loud = rms(at: 0.9), quieter = rms(at: 0.45)
        #expect(loud > 0.3 && loud < 0.75, "loud rms \(loud)")
        #expect(quieter > 0.3 && quieter <= loud + 0.001)
    }
}
