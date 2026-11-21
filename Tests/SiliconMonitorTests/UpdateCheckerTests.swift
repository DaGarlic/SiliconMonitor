import Testing
@testable import SiliconMonitor

@Suite @MainActor struct UpdateCheckerTests {
    @Test func comparisonIsNumericNotTextual() {
        #expect(UpdateChecker.isNewer("1.10", than: "1.9"))
        #expect(!UpdateChecker.isNewer("1.9", than: "1.10"))
    }

    @Test func equalVersionsAreNotNewer() {
        #expect(!UpdateChecker.isNewer("1.4", than: "1.4"))
        #expect(!UpdateChecker.isNewer("1.4", than: "1.4.0"))
    }

    @Test func missingComponentsCountAsZero() {
        #expect(UpdateChecker.isNewer("1.4.1", than: "1.4"))
        #expect(UpdateChecker.isNewer("2", than: "1.9.9"))
    }

    @Test func garbageNeverCountsAsNewer() {
        #expect(!UpdateChecker.isNewer("beta", than: "1.0"))
    }
}
