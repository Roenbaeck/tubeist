import Testing
@testable import Tubeist

struct OverlayRefreshRateTests {
    private func expectBegin(_ schedule: inout OverlayCaptureSchedule, at time: Double,
                             expected: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) {
        let started = schedule.begin(at: time)
        #expect(started == expected, sourceLocation: sourceLocation)
    }

    @Test(arguments: [0, -1, 2, 60])
    func missingOrUnknownPreferenceUsesBatteryFriendlyDefault(_ value: Int) {
        #expect(OverlayRefreshRate.stored(value) == .once)
    }

    @Test(arguments: OverlayRefreshRate.allCases)
    func continuousChangesKeepOriginalDeadline(_ rate: OverlayRefreshRate) throws {
        var schedule = OverlayCaptureSchedule(rate: rate)
        schedule.request()
        expectBegin(&schedule, at: 0)
        schedule.complete()
        for _ in 0..<100 { schedule.request() }
        #expect(try #require(schedule.delay(at: rate.interval / 2)) == rate.interval / 2)
        expectBegin(&schedule, at: rate.interval / 2, expected: false)
        expectBegin(&schedule, at: rate.interval)
        schedule.complete()
        #expect(schedule.delay(at: 100) == nil) // An idle page stays idle.
        #expect(OverlayRefreshRate.stored(rate.rawValue) == rate)
    }

    @Test func slowCaptureCoalescesChangesWithoutOverlapOrCatchUpBurst() {
        var schedule = OverlayCaptureSchedule(rate: .thirty)
        schedule.request()
        expectBegin(&schedule, at: 0)
        for _ in 0..<1_000 { schedule.request() }
        #expect(schedule.isPending)
        #expect(schedule.delay(at: 5) == nil)
        expectBegin(&schedule, at: 5, expected: false)
        schedule.complete()
        expectBegin(&schedule, at: 5)
        schedule.complete()
        schedule.request()
        expectBegin(&schedule, at: 5.001, expected: false)
        expectBegin(&schedule, at: 5 + OverlayRefreshRate.thirty.interval)
        schedule.complete()
        #expect(!schedule.isPending)
    }

    @Test func navigationResetsDeadlineButCannotOverlapOutstandingSnapshot() {
        var schedule = OverlayCaptureSchedule(rate: .once)
        schedule.request()
        expectBegin(&schedule, at: 0)
        schedule.request()
        schedule.reset()
        #expect(!schedule.isPending)
        schedule.rate = .ten
        schedule.request() // Replacement page finished loading.
        expectBegin(&schedule, at: 0.01, expected: false)
        schedule.complete()
        expectBegin(&schedule, at: 0.01)
        schedule.complete()
        schedule.reset()
        #expect(schedule.delay(at: 100) == nil)
    }
}
