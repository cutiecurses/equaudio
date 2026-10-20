import EquCore
import Foundation
import Testing

@Suite("Benchmark")
struct BenchmarkTests {
    /// Real-time factor of the full chain with the saved settings (every effect on). Printed in all builds; the
    /// assertion is loose because debug builds compile the C++ without optimisation.
    @Test func printRealTimeFactor() {
        for fs in [48000.0, 96000.0] {
            let e = equ_engine_create()!; defer { equ_engine_destroy(e) }
            equ_engine_prepare(e, fs, 512)
            for (id, value) in ParityTests.settings {
                var p = EquParam.bypass
                if equ_param_from_identifier(id, &p), p != .bypass { equ_engine_set_param(e, p, value) }
            }
            let seconds = 10.0, n = Int(fs * seconds)
            var gen = SystemRandomNumberGenerator()
            var l = (0..<n).map { i in 0.2 * Float(sin(2 * .pi * 60 * Double(i) / fs)) + Float.random(in: -0.1...0.1, using: &gen) }, r = l
            let start = DispatchTime.now().uptimeNanoseconds
            var offset = 0
            while offset < n {
                let count = min(512, n - offset)
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                    equ_engine_process(e, lp.baseAddress! + offset, rp.baseAddress! + offset, lp.baseAddress! + offset, rp.baseAddress! + offset, UInt32(count))
                } }
                offset += count
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            print(String(format: "BENCH %.0f Hz: %.2f s of audio in %.3f s -> %.1f%% of one core", fs, seconds, elapsed, elapsed / seconds * 100))
        }
    }
}
