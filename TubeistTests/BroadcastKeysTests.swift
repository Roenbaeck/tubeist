//
//  BroadcastKeysTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct BroadcastKeysTests {
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
        var own = broadcast(id, title: "Manual stream", stream: stream,
                  scheduled: "2026-10-28T10:00:10Z", published: "2026-10-28T10:00:00Z")
        own.broadcastDescription = BroadcastKeys.broadcastDescription
        return own
    }

    private let m1 = BroadcastKeyStream(id: "m1", title: "Tubeist stream 1")
    private let m2 = BroadcastKeyStream(id: "m2", title: "Tubeist stream 2")
    private let m3 = BroadcastKeyStream(id: "m3", title: "Tubeist stream 3")
    private let phone = BroadcastKeyStream(id: "p", title: "Tubeist – Jans Duo")

    @Test func broadcastKeyTitlesAreRecognisedByPrefix() {
        #expect(BroadcastKeys.isBroadcastKey(title: "Tubeist stream 3"))
        #expect(!BroadcastKeys.isBroadcastKey(title: "Tubeist – Jans Duo"))
        #expect(!BroadcastKeys.isBroadcastKey(title: "Default stream key"))
        #expect(!BroadcastKeys.isBroadcastKey(title: nil))
        #expect(BroadcastKeys.title(number: 7) == "Tubeist stream 7")
    }

    @Test func nextNumberContinuesAfterHighestRemaining() {
        #expect(BroadcastKeys.nextNumber(existingTitles: ["Tubeist stream 1", "Tubeist stream 4", "Court 2"]) == 5)
        #expect(BroadcastKeys.nextNumber(existingTitles: []) == 1)
    }

    @Test func legacyKeysRemainReusableAlongsideGenericKeys() {
        let legacy = BroadcastKeyStream(id: "old", title: "Tubeist match 4")
        let current = BroadcastKeyStream(id: "new", title: "Tubeist stream 5")
        #expect(BroadcastKeys.freeKeys([current, legacy], upcoming: [], active: []) == [legacy, current])
        #expect(BroadcastKeys.broadcastsNeedingOwnKey(
            upcoming: [broadcast("planned", stream: legacy.id)], streams: [legacy], remembered: []).isEmpty)
        #expect(BroadcastKeys.nextNumber(existingTitles: [legacy.title, current.title]) == 6)
        #expect(BroadcastKeys.title(number: 6) == "Tubeist stream 6")
    }

    @Test func tubeistOwnRequiresARecordOrAnExplicitMarker() {
        let close = broadcast("a", scheduled: "2026-10-28T10:00:10Z", published: "2026-10-28T10:00:00Z")
        let far = broadcast("b", scheduled: "2026-10-28T10:01:01Z", published: "2026-10-28T10:00:00Z")
        let remembered = broadcast("c", scheduled: "2026-10-28T13:00:00Z", published: "2026-10-28T10:00:00Z")
        #expect(!BroadcastKeys.isTubeistOwn(close, remembered: []))
        #expect(BroadcastKeys.isPlannedBroadcast(close, remembered: []))
        #expect(BroadcastKeys.isTubeistOwn(tubeists("own", stream: "k1"), remembered: []))
        #expect(!BroadcastKeys.isTubeistOwn(far, remembered: []))
        #expect(!BroadcastKeys.isTubeistOwn(remembered, remembered: []))
        #expect(BroadcastKeys.isTubeistOwn(remembered, remembered: ["c"]))
    }

    @Test func missingTimestampsAreNotTubeistsOwn() {
        #expect(!BroadcastKeys.isTubeistOwn(broadcast("a", published: nil), remembered: []))
        #expect(!BroadcastKeys.isTubeistOwn(broadcast("a", scheduled: nil), remembered: []))
    }

    @Test func plannedMatchExcludesPersistentLiveAndTubeists() {
        #expect(BroadcastKeys.isPlannedBroadcast(broadcast("a"), remembered: []))
        #expect(BroadcastKeys.isPlannedBroadcast(broadcast("a", status: "created"), remembered: []))
        #expect(!BroadcastKeys.isPlannedBroadcast(broadcast("a", persistent: true), remembered: []))
        #expect(!BroadcastKeys.isPlannedBroadcast(broadcast("a", status: "live"), remembered: []))
        #expect(!BroadcastKeys.isPlannedBroadcast(broadcast("a", status: "complete"), remembered: []))
        #expect(!BroadcastKeys.isPlannedBroadcast(tubeists("a", stream: "k1"), remembered: []))
    }

    @Test func freeKeysSkipKeysWithAnyUpcomingOrActiveBroadcast() {
        let free = BroadcastKeys.freeKeys(
            [m3, phone, m1, m2],
            upcoming: [tubeists("t", stream: "m1")],
            active: [broadcast("l", stream: "m2", status: "live")])
        #expect(free == [m3])
    }

    @Test func freeKeysAreSortedByNumber() {
        let ten = BroadcastKeyStream(id: "m10", title: "Tubeist stream 10")
        #expect(BroadcastKeys.freeKeys([ten, m2], upcoming: [], active: []) == [m2, ten])
    }

    @Test func broadcastsNeedingOwnKey() {
        let streams = [m1, m2, m3, phone]
        let alone = broadcast("alone", stream: "m1")
        let sharedA = broadcast("sharedA", stream: "m2")
        let sharedB = broadcast("sharedB", stream: "m2")
        let onPhone = broadcast("onPhone", stream: "p")
        let unbound = broadcast("unbound", stream: nil)
        let withTubeist = broadcast("withTubeist", stream: "m3")
        let upcoming = [alone, sharedA, sharedB, onPhone, unbound, withTubeist, tubeists("t", stream: "m3")]
        let result = BroadcastKeys.broadcastsNeedingOwnKey(upcoming: upcoming, streams: streams, remembered: [])
        #expect(result.map(\.id) == ["sharedA", "sharedB", "onPhone", "unbound", "withTubeist"])
    }
}
