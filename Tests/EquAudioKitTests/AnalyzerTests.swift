import EquAudioKit
import Foundation
import Testing

@Suite("Spectrum analyzer")
struct AnalyzerTests {
    @Test func fullScaleSineOnABinReadsZeroDB() {
        let a = Analyzer()
        let n = Analyzer.fftSize, fs = 48000.0, bin = 171                       // bin 171 = 1001.95 Hz
        let f = Double(bin) * fs / Double(n)
        let x = (0..<n).map { Float(sin(2 * .pi * f * Double($0) / fs)) }
        let db = a.spectrumDB(x)
        #expect(db.indices.max { db[$0] < db[$1] } == bin)
        #expect(abs(db[bin]) < 0.8, "peak reads \(db[bin]) dB")
        #expect(db[bin + 30] < -60, "leakage \(db[bin + 30]) dB")
    }

    @Test func halfScaleSineReadsMinusSixAndShowsInTheRightBand() {
        let engine = DSPEngine()
        engine.prepare(sampleRate: 48000, maxFrames: 4096)
        var l = (0..<16384).map { 0.5 * Float(sin(2 * .pi * 1000 * Double($0) / 48000)) }, r = l
        engine.process(left: &l, right: &r)
        let a = Analyzer()
        a.update(engine: engine, dt: 0.033)
        let top = a.bands.indices.max { a.bands[$0] < a.bands[$1] }!
        #expect(abs(a.bandFrequencies[top] - 1000) < 90, "loudest band is \(a.bandFrequencies[top]) Hz")
        #expect(a.bands[top] > 0.8)
        #expect(a.bands[0] < 0.4 && a.bands[Analyzer.bandCount - 1] < 0.4)
    }

    @Test func measuresTheBassBoostItApplied() {
        let engine = DSPEngine()
        engine.prepare(sampleRate: 48000, maxFrames: 4096)
        engine[.bassBoostDB] = 12
        engine[.autoHeadroom] = 0
        engine[.limiterEnabled] = 0
        var l = (0..<32768).map { 0.05 * Float(sin(2 * .pi * 60 * Double($0) / 48000)) }, r = l
        for _ in 0..<2 { engine.process(left: &l, right: &r); l = (0..<32768).map { 0.05 * Float(sin(2 * .pi * 60 * Double($0) / 48000)) }; r = l }
        engine.process(left: &l, right: &r)
        let a = Analyzer()
        for _ in 0..<60 { a.update(engine: engine, dt: 0.033) }
        #expect(a.delta.bass > 8 && a.delta.bass < 14, "bass delta \(a.delta.bass) dB")
    }
}
