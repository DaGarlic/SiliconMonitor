import Foundation
import Testing
@testable import SiliconMonitor

@Suite @MainActor struct FormattingTests {
    @Test func rateUnits() {
        #expect(Monitor.rate(0) == "0 KB/s")
        #expect(Monitor.rate(42_000) == "42 KB/s")
        #expect(Monitor.rate(2_500_000) == "2.5 MB/s")
        #expect(Monitor.rate(250_000_000) == "250 MB/s")
    }

    @Test func ratePadsToAFixedWidthAndNeverTruncates() {
        #expect(Monitor.rate(42_000, width: 10) == "   42 KB/s")
        #expect(Monitor.rate(42_000, width: 3) == "42 KB/s")
    }

    @Test func fourCCRoundTrips() {
        for key in ["PSTR", "FNum", "F0Ac", "#KEY"] {
            #expect(fourCCString(fourCC(key)) == key)
        }
        #expect(fourCC("ABCD") == 0x41424344)
    }

    @Test func throttleEventSurvivesBeingSaved() throws {
        let e = ThrottleEvent(start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 1_090),
                              causes: ["GPU thermal limit"], peakCPUTemp: 88, peakGPUTemp: nil, peakPower: 61,
                              cpuLoad: 90, gpuLoad: 40)
        let back = try JSONDecoder().decode([ThrottleEvent].self, from: JSONEncoder().encode([e]))
        #expect(back.first?.causes == ["GPU thermal limit"])
        #expect(back.first?.peakCPUTemp == 88)
        #expect(back.first?.peakGPUTemp == nil)
        #expect(back.first?.id == e.id)
    }
}
