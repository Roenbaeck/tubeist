//
//  MatchKeysTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct MatchKeysTests {
    private func broadcast(
        _ id: String, title: String = "Match", stream: String? = "k1",
        status: String? = "ready", scheduled: String? = "2026-10-31T09:00:00Z",
        published: String? = "2026-10-20T08:00:00Z", persistent: Bool = false
    ) -> YouTubeBroadcast {
        YouTubeBroadcast(
            id: id, title: title, privacyStatus: "unlisted", boundStreamId: stream,
            scheduledStartTime: scheduled, actualStartTime: nil, publishedAt: published,
            lifeCycleStatus: status, enableDvr: true, latencyPreference: "low",
            enableMonitorStream: false, broadcastStreamDelayMs: 0, enableEmbed: false,
            recordFromStart: true, enableAutoStart: true, enableAutoStop: true,
            selfDeclaredMadeForKids: false, isDefaultBroadcast: persistent
        )
    }

    private func tubeists(_ id: String, stream: String?) -> YouTubeBroadcast {
        broadcast(id, title: "Manual stream", stream: stream,
                  scheduled: "2026-10-28T10:00:10Z", published: "2026-10-28T10:00:00Z")
    }

    private let m1 = MatchKeyStream(id: "m1", title: "Tubeist match 1")
    private let m2 = MatchKeyStream(id: "m2", title: "Tubeist match 2")
    private let m3 = MatchKeyStream(id: "m3", title: "Tubeist match 3")
    private let phone = MatchKeyStream(id: "p", title: "Tubeist – Jans Duo")

    @Test func matchKeyTitlesAreRecognisedByPrefix() {
        #expect(MatchKeys.isMatchKey(title: "Tubeist match 3"))
        #expect(!MatchKeys.isMatchKey(title: "Tubeist – Jans Duo"))
        #expect(!MatchKeys.isMatchKey(title: "Default stream key"))
        #expect(!MatchKeys.isMatchKey(title: nil))
        #expect(MatchKeys.title(number: 7) == "Tubeist match 7")
    }

    @Test func nextNumberContinuesAfterHighestRemaining() {
        #expect(MatchKeys.nextNumber(existingTitles: ["Tubeist match 1", "Tubeist match 4", "Court 2"]) == 5)
        #expect(MatchKeys.nextNumber(existingTitles: []) == 1)
    }

    @Test func tubeistOwnByRecordOrTenSecondSchedule() {
        let close = broadcast("a", scheduled: "2026-10-28T10:00:10Z", published: "2026-10-28T10:00:00Z")
        let far = broadcast("b", scheduled: "2026-10-28T10:01:01Z", published: "2026-10-28T10:00:00Z")
        let remembered = broadcast("c", scheduled: "2026-10-28T13:00:00Z", published: "2026-10-28T10:00:00Z")
        #expect(MatchKeys.isTubeistOwn(close, remembered: []))
        #expect(!MatchKeys.isTubeistOwn(far, remembered: []))
        #expect(!MatchKeys.isTubeistOwn(remembered, remembered: []))
        #expect(MatchKeys.isTubeistOwn(remembered, remembered: ["c"]))
    }

    @Test func missingTimestampsAreNotTubeistsOwn() {
        #expect(!MatchKeys.isTubeistOwn(broadcast("a", published: nil), remembered: []))
        #expect(!MatchKeys.isTubeistOwn(broadcast("a", scheduled: nil), remembered: []))
    }

    @Test func plannedMatchExcludesPersistentLiveAndTubeists() {
        #expect(MatchKeys.isPlannedMatch(broadcast("a"), remembered: []))
        #expect(MatchKeys.isPlannedMatch(broadcast("a", status: "created"), remembered: []))
        #expect(!MatchKeys.isPlannedMatch(broadcast("a", persistent: true), remembered: []))
        #expect(!MatchKeys.isPlannedMatch(broadcast("a", status: "live"), remembered: []))
        #expect(!MatchKeys.isPlannedMatch(broadcast("a", status: "complete"), remembered: []))
        #expect(!MatchKeys.isPlannedMatch(tubeists("a", stream: "k1"), remembered: []))
    }

    @Test func freeKeysSkipKeysWithAnyUpcomingOrActiveBroadcast() {
        let free = MatchKeys.freeKeys(
            [m3, phone, m1, m2],
            upcoming: [tubeists("t", stream: "m1")],
            active: [broadcast("l", stream: "m2", status: "live")])
        #expect(free == [m3])
    }

    @Test func freeKeysAreSortedByNumber() {
        let ten = MatchKeyStream(id: "m10", title: "Tubeist match 10")
        #expect(MatchKeys.freeKeys([ten, m2], upcoming: [], active: []) == [m2, ten])
    }

    @Test func matchesNeedingOwnKey() {
        let streams = [m1, m2, m3, phone]
        let alone = broadcast("alone", stream: "m1")
        let sharedA = broadcast("sharedA", stream: "m2")
        let sharedB = broadcast("sharedB", stream: "m2")
        let onPhone = broadcast("onPhone", stream: "p")
        let unbound = broadcast("unbound", stream: nil)
        let withTubeist = broadcast("withTubeist", stream: "m3")
        let upcoming = [alone, sharedA, sharedB, onPhone, unbound, withTubeist, tubeists("t", stream: "m3")]
        let result = MatchKeys.matchesNeedingOwnKey(upcoming: upcoming, streams: streams, remembered: [])
        #expect(result.map(\.id) == ["sharedA", "sharedB", "onPhone", "unbound", "withTubeist"])
    }
}
