import Testing
@testable import SiliconMonitor

@Suite @MainActor struct ThrottleReadingTests {
    @Test func nominalReadingHasNoCauses() {
        #expect(ThrottleReading().causes.isEmpty)
    }

    @Test func thermalPressureIsReportedWithItsLevelName() {
        var r = ThrottleReading()
        r.thermalLevel = 2
        #expect(r.causes == ["Thermal pressure: Heavy"])
    }

    @Test func thermalLevelAboveTheTableIsClampedToTheLastName() {
        var r = ThrottleReading()
        r.thermalLevel = 9
        #expect(r.causes == ["Thermal pressure: Emergency"])
    }

    @Test func gpuThermalLimitFromEachSource() {
        var cltm = ThrottleReading(); cltm.gpuCLTM = 0.10
        var ctl = ThrottleReading(); ctl.gpuThermalCtl = 0.20
        var reason = ThrottleReading(); reason.gpuReason = "GPU_TH"; reason.gpuReasonShare = 0.10
        for r in [cltm, ctl, reason] { #expect(r.causes == ["GPU thermal limit"]) }
    }

    @Test func gpuThermalLimitIgnoresNoise() {
        var r = ThrottleReading()
        r.gpuCLTM = 0.02; r.gpuThermalCtl = 0.04
        r.gpuReason = "GPU_TH"; r.gpuReasonShare = 0.02
        #expect(r.causes.isEmpty)
    }

    @Test func emergencyReasonNeedsEnoughTime() {
        var r = ThrottleReading()
        r.gpuReason = "FAB_EMT"; r.gpuReasonShare = 0.5
        #expect(r.causes == ["GPU emergency thermal limit"])
        r.gpuReasonShare = 0.01
        #expect(r.causes.isEmpty)
    }

    @Test func powerLimitOnlyCountsWhileTheGPUIsBusy() {
        var r = ThrottleReading()
        r.gpuPowerCtl = 0.5
        r.gpuLoad = 10
        #expect(r.causes.isEmpty, "an idle GPU under a power controller is not being held back")
        r.gpuLoad = 80
        #expect(r.causes == ["GPU power limit"])
    }

    @Test func powerBudgetNeedsLoadAndAShortfall() {
        var r = ThrottleReading()
        r.gpuBudget = 0.5; r.gpuLoad = 30
        #expect(r.causes.isEmpty)
        r.gpuLoad = 90
        #expect(r.causes == ["GPU power budget 50%"])
        r.gpuBudget = 0.8
        #expect(r.causes.isEmpty)
    }

    @Test func causesAreOrderedMostImportantFirst() {
        var r = ThrottleReading()
        r.thermalLevel = 1
        r.gpuCLTM = 0.5
        r.gpuPowerCtl = 0.5
        r.gpuLoad = 90
        #expect(r.causes == ["Thermal pressure: Moderate", "GPU thermal limit", "GPU power limit"])
    }
}
