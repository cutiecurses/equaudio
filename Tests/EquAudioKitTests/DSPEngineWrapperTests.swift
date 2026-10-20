import EquAudioKit
import EquCore
import Testing

@Suite("Swift engine wrapper")
struct DSPEngineWrapperTests {
    @Test func parameterInfoCoversEveryParameter() {
        #expect(ParameterInfo.all.count == Int(EquParam.count.rawValue))
        #expect(ParameterInfo.param(forIdentifier: "eq_1k") == .eqBand5)
        #expect(EquParam.eqBand(9) == .eqBand9)
        #expect(eqBandFrequencies.count == 10)
    }

    @Test func subscriptValidates() {
        let engine = DSPEngine()
        engine[.bassBoostDB] = 50
        #expect(engine[.bassBoostDB] == 12)
        engine.bypass = true
        #expect(engine.bypass)
    }
}
