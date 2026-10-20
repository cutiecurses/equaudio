import EquCore
import Testing

@Suite("Parameter metadata and validation")
struct ParameterTests {
    @Test func everyParameterHasConsistentMetadata() {
        var identifiers = Set<String>()
        for raw in 0..<EquParam.count.rawValue {
            var info = EquParamInfo()
            #expect(equ_param_info(EquParam(rawValue: raw)!, &info))
            let identifier = String(cString: info.identifier!)
            #expect(!identifier.isEmpty)
            #expect(identifiers.insert(identifier).inserted, "duplicate identifier \(identifier)")
            #expect(info.minValue < info.maxValue)
            #expect(info.defaultValue >= info.minValue && info.defaultValue <= info.maxValue)
            if info.isToggle { #expect(info.minValue == 0 && info.maxValue == 1) }
        }
    }

    @Test func validationClampsRejectsNonFiniteAndQuantisesToggles() {
        #expect(equ_param_validate(.eqBand3, 40) == 12)
        #expect(equ_param_validate(.eqBand3, -40) == -12)
        #expect(equ_param_validate(.eqBand3, 3.5) == 3.5)
        #expect(equ_param_validate(.preampDB, .nan) == 0)
        #expect(equ_param_validate(.stereoWidth, .infinity) == 1)
        #expect(equ_param_validate(.limiterCeilingDB, 3) == 0)
        #expect(equ_param_validate(.limiterEnabled, 0.7) == 1)
        #expect(equ_param_validate(.limiterEnabled, 0.2) == 0)
        #expect(equ_param_validate(.crossfeedFeedDB, -.infinity) == 4.5)
    }

    @Test func identifiersRoundTrip() {
        for raw in 0..<EquParam.count.rawValue {
            var info = EquParamInfo()
            _ = equ_param_info(EquParam(rawValue: raw)!, &info)
            var found = EquParam.bypass
            #expect(equ_param_from_identifier(info.identifier!, &found))
            #expect(found.rawValue == raw)
        }
        var p = EquParam.bypass
        #expect(!equ_param_from_identifier("no_such_param", &p))
    }

    @Test func bandFrequenciesAreOctaveSpaced() {
        #expect(equ_eq_band_frequency(0) == 31.25)
        #expect(equ_eq_band_frequency(5) == 1000)
        #expect(equ_eq_band_frequency(9) == 16000)
        #expect(equ_eq_band_frequency(10) == 0)
    }

    @Test func engineSetterValidates() {
        let engine = equ_engine_create()!
        defer { equ_engine_destroy(engine) }
        equ_engine_set_param(engine, .eqBand0, 99)
        #expect(equ_engine_get_param(engine, .eqBand0) == 12)
        equ_engine_set_param(engine, .outputGainDB, .nan)
        #expect(equ_engine_get_param(engine, .outputGainDB) == 0)
        #expect(equ_engine_get_param(engine, .limiterCeilingDB) == -1)
    }
}
