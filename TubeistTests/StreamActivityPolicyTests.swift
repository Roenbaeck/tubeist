//
//  StreamActivityPolicyTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct StreamActivityPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(
        health: YouTubeStreamHealth = .good,
        healthAge: TimeInterval? = 0,
        at now: Date,
        phase: StreamPhase = .live,
        viewers: Int? = 42
    ) -> StreamSnapshot {
        StreamSnapshot(
            phase: phase,
            youtubeHealth: health,
            healthUpdatedAt: healthAge.map { now.addingTimeInterval(-$0) },
            viewers: viewers,
            bitrateKbps: 6000,
            link: .good,
            thermal: .nominal,
            batteryPercent: 80,
            warning: nil
        )
    }

    private func policy(
        detail: LiveActivityDetail = .standard,
        alertOnBad: Bool = true,
        alertOnRecovery: Bool = false
    ) -> StreamActivityPolicy {
        StreamActivityPolicy(detail: detail, alertOnBad: alertOnBad, alertOnRecovery: alertOnRecovery)
    }

    @Test func healthMapsApiValues() {
        #expect(YouTubeStreamHealth(apiValue: "good") == .good)
        #expect(YouTubeStreamHealth(apiValue: "ok") == .ok)
        #expect(YouTubeStreamHealth(apiValue: "bad") == .bad)
        #expect(YouTubeStreamHealth(apiValue: "noData") == .noData)
        #expect(YouTubeStreamHealth(apiValue: "revoked") == .unknown)
        #expect(YouTubeStreamHealth(apiValue: nil) == .unknown)
    }

    @Test func standardOmitsFullFieldsAndFullIncludesThem() {
        var standard = policy(detail: .standard)
        var full = policy(detail: .full)

        let s = standard.evaluate(snapshot(at: t0), now: t0).content
        let f = full.evaluate(snapshot(at: t0), now: t0).content

        #expect(s?.health == .good)
        #expect(s?.viewers == nil)
        #expect(s?.bitrateKbps == nil)
        #expect(s?.batteryPercent == nil)
        #expect(f?.viewers == 42)
        #expect(f?.bitrateKbps == 6000)
        #expect(f?.thermal == .nominal)
        #expect(f?.batteryPercent == 80)
        #expect(f?.link == .good)
    }

    @Test func offProducesNoContentButStillAlerts() {
        var p = policy(detail: .off)
        _ = p.evaluate(snapshot(health: .bad, at: t0), now: t0)
        let later = t0.addingTimeInterval(10)
        let decision = p.evaluate(snapshot(health: .bad, at: later), now: later)

        #expect(decision.content == nil)
        #expect(decision.alert == .degraded(.bad))
    }

    @Test func updatesAreThrottledToFiveSeconds() {
        var p = policy(detail: .full)
        #expect(p.evaluate(snapshot(at: t0, viewers: 1), now: t0).content != nil)

        let t2 = t0.addingTimeInterval(2)
        #expect(p.evaluate(snapshot(at: t2, viewers: 2), now: t2).content == nil)

        let t5 = t0.addingTimeInterval(5)
        #expect(p.evaluate(snapshot(at: t5, viewers: 3), now: t5).content?.viewers == 3)
    }

    @Test func phaseChangeBypassesThrottle() {
        var p = policy()
        _ = p.evaluate(snapshot(at: t0, phase: .connecting), now: t0)
        let t1 = t0.addingTimeInterval(1)
        #expect(p.evaluate(snapshot(at: t1, phase: .live), now: t1).content?.phase == .live)
    }

    @Test func badHealthAlertsOnlyAfterDebounce() {
        var p = policy()
        #expect(p.evaluate(snapshot(health: .bad, at: t0), now: t0).alert == nil)
        let t9 = t0.addingTimeInterval(9)
        #expect(p.evaluate(snapshot(health: .bad, at: t9), now: t9).alert == nil)
        let t10 = t0.addingTimeInterval(10)
        let decision = p.evaluate(snapshot(health: .bad, at: t10), now: t10)
        #expect(decision.alert == .degraded(.bad))
        #expect(decision.content?.health == .bad)  // alert forces a content push
    }

    @Test func shortBlipDoesNotAlert() {
        var p = policy()
        _ = p.evaluate(snapshot(health: .bad, at: t0), now: t0)
        let t5 = t0.addingTimeInterval(5)
        _ = p.evaluate(snapshot(health: .good, at: t5), now: t5)
        let t20 = t0.addingTimeInterval(20)
        #expect(p.evaluate(snapshot(health: .bad, at: t20), now: t20).alert == nil)
        let t30 = t0.addingTimeInterval(30)
        #expect(p.evaluate(snapshot(health: .bad, at: t30), now: t30).alert == .degraded(.bad))
    }

    @Test func sustainedBadAlertsOnce() {
        var p = policy()
        _ = p.evaluate(snapshot(health: .noData, at: t0), now: t0)
        let t10 = t0.addingTimeInterval(10)
        #expect(p.evaluate(snapshot(health: .noData, at: t10), now: t10).alert == .degraded(.noData))
        for offset in [15.0, 60, 300] {
            let t = t0.addingTimeInterval(offset)
            #expect(p.evaluate(snapshot(health: .noData, at: t), now: t).alert == nil)
        }
    }

    @Test func cooldownDelaysRepeatAlerts() {
        var p = policy()
        _ = p.evaluate(snapshot(health: .bad, at: t0), now: t0)
        let t10 = t0.addingTimeInterval(10)
        #expect(p.evaluate(snapshot(health: .bad, at: t10), now: t10).alert != nil)
        let t12 = t0.addingTimeInterval(12)
        _ = p.evaluate(snapshot(health: .good, at: t12), now: t12)
        let t15 = t0.addingTimeInterval(15)
        _ = p.evaluate(snapshot(health: .bad, at: t15), now: t15)
        let t26 = t0.addingTimeInterval(26)  // debounce met, cooldown (60 s from t10) not
        #expect(p.evaluate(snapshot(health: .bad, at: t26), now: t26).alert == nil)
        let t70 = t0.addingTimeInterval(70)
        #expect(p.evaluate(snapshot(health: .bad, at: t70), now: t70).alert == .degraded(.bad))
    }

    @Test func recoveryAlertOnlyWhenEnabled() {
        for enabled in [false, true] {
            var p = policy(alertOnRecovery: enabled)
            _ = p.evaluate(snapshot(health: .bad, at: t0), now: t0)
            let t10 = t0.addingTimeInterval(10)
            _ = p.evaluate(snapshot(health: .bad, at: t10), now: t10)
            let t20 = t0.addingTimeInterval(20)
            let decision = p.evaluate(snapshot(health: .good, at: t20), now: t20)
            #expect((decision.alert == .recovered) == enabled)
        }
    }

    @Test func alertsCanBeDisabled() {
        var p = policy(alertOnBad: false)
        _ = p.evaluate(snapshot(health: .bad, at: t0), now: t0)
        let t60 = t0.addingTimeInterval(60)
        #expect(p.evaluate(snapshot(health: .bad, at: t60), now: t60).alert == nil)
    }

    @Test func staleHealthIsFlaggedAndNeverAlerts() {
        var p = policy()
        let stale = snapshot(health: .bad, healthAge: 120, at: t0)
        #expect(p.evaluate(stale, now: t0).content?.isStale == true)
        let t30 = t0.addingTimeInterval(30)
        #expect(p.evaluate(snapshot(health: .bad, healthAge: 150, at: t30), now: t30).alert == nil)
    }

    @Test func missingHealthTimestampCountsAsStale() {
        var p = policy()
        let decision = p.evaluate(snapshot(healthAge: nil, at: t0), now: t0)
        #expect(decision.content?.isStale == true)
    }
}
