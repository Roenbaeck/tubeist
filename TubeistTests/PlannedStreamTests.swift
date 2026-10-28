//
//  PlannedStreamTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct PlannedStreamTests {
    private var oslo: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func broadcast(_ id: String, title: String = "Match", stream: String? = "stream-1",
                           start: String? = "2026-10-31T09:00:00Z", status: String? = "ready") -> YouTubeBroadcast {
        YouTubeBroadcast(
            id: id, title: title, privacyStatus: "unlisted", boundStreamId: stream,
            scheduledStartTime: start, actualStartTime: nil, publishedAt: nil,
            lifeCycleStatus: status, enableDvr: true, latencyPreference: "low",
            enableMonitorStream: false, broadcastStreamDelayMs: 0, enableEmbed: false,
            recordFromStart: true, enableAutoStart: true, enableAutoStop: true,
            selfDeclaredMadeForKids: false
        )
    }

    private func selection() -> PlannedStreamSelection {
        let b = broadcast("b-1", title: "Match 5")
        var edited = PlannedStreamDetails(broadcast: b, playlistId: "pl-1")
        let loaded = edited
        edited.title = "Edited title"
        edited.privacyStatus = "public"
        return PlannedStreamSelection(
            kind: .planned, broadcastId: "b-1", streamId: "stream-1",
            scheduledStartTime: "2026-10-31T09:00:00Z", loaded: loaded, edited: edited,
            loadedMembership: YouTubePlaylistMembership(playlistId: "pl-1", itemId: "item-1"),
            thumbnailChanged: true
        )
    }

    @Test func todayUsesTheLocalCalendarDay() {
        let now = date("2026-10-31T10:00:00Z")
        #expect(PlannedStreams.isScheduledToday("2026-10-30T23:30:00Z", now: now, calendar: oslo))
        #expect(PlannedStreams.isScheduledToday("2026-10-31T22:59:00Z", now: now, calendar: oslo))
        #expect(!PlannedStreams.isScheduledToday("2026-10-31T23:00:00Z", now: now, calendar: oslo))
        #expect(!PlannedStreams.isScheduledToday(nil, now: now, calendar: oslo))
    }

    @Test func todayFiltersBoundUpcomingAndSortsByTime() {
        let now = date("2026-10-31T10:00:00Z")
        let input = [
            broadcast("b-1300", start: "2026-10-31T12:00:00Z"),
            broadcast("b-0800", start: "2026-10-31T07:00:00Z"),
            broadcast("b-done", start: "2026-10-31T08:00:00Z", status: "complete"),
            broadcast("b-other", stream: "stream-2", start: "2026-10-31T08:00:00Z"),
            broadcast("b-tomorrow", start: "2026-11-01T09:00:00Z"),
            broadcast("b-excluded", start: "2026-10-31T09:00:00Z"),
            // Start refuses a broadcast that is not ready, so it is not listed.
            broadcast("b-created", start: "2026-10-31T10:00:00Z", status: "created"),
        ]
        let result = PlannedStreams.today(input, streamId: "stream-1", excluding: ["b-excluded"],
                                          now: now, calendar: oslo)
        #expect(result.map(\.id) == ["b-0800", "b-1300"])
    }

    @Test func labelIsTwentyFourHourLocalTimeWithEnDash() {
        let b = broadcast("b-1", title: "Match 5", start: "2026-10-31T09:30:00Z")
        #expect(PlannedStreams.label(for: b, calendar: oslo) == "10:30 – Match 5")
    }

    @Test func restartingCopiesEditedDetailsAndDropsMembership() {
        let original = selection()
        let restart = original.restarting()
        #expect(restart.kind == .restart)
        #expect(restart.loaded == restart.edited)
        #expect(restart.loaded == original.edited)
        #expect(restart.loadedMembership == nil)
        #expect(restart.thumbnailChanged == original.thumbnailChanged)
        #expect(PlannedStreams.restartLabel(for: restart) == "Restart: Edited title")
    }

    @Test func restartAfterStartCarriesTheDetailsAppliedAtStart() {
        let original = selection()
        // Studio changed visibility after the pick; the untouched field kept it at Start.
        var applied = broadcast("b-1", title: "Edited title")
        applied.privacyStatus = "private"
        applied.enableDvr = false
        let restart = original.restarting(after: applied)
        #expect(restart.kind == .restart)
        #expect(restart.broadcastId == "b-1")
        #expect(restart.edited.privacyStatus == "private")
        #expect(restart.edited.enableDvr == false)
        #expect(restart.edited.title == "Edited title")
        #expect(restart.edited.playlistId == original.edited.playlistId)
        #expect(restart.loaded == restart.edited)
        #expect(restart.loadedMembership == nil)
        #expect(restart.scheduledStartTime == original.scheduledStartTime)
        #expect(restart.thumbnailChanged == original.thumbnailChanged)
    }

    @Test func restartAfterARestartPointsAtTheBroadcastJustUsed() {
        let restart = selection().restarting()
        let again = restart.restarting(after: broadcast("new-event", title: "Edited title"))
        #expect(again.broadcastId == "new-event")
        #expect(again.streamId == restart.streamId)
    }

    @Test func selectionRoundTripsThroughJSON() throws {
        let original = selection()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlannedStreamSelection.self, from: data)
        #expect(decoded == original)
    }

    @Test func broadcastDecodesBestThumbnailURL() throws {
        let withThumbs = #"""
        {"id":"b-1","snippet":{"title":"T","thumbnails":{
          "default":{"url":"https://img/default.jpg"},
          "high":{"url":"https://img/high.jpg"},
          "maxres":{"url":"https://img/maxres.jpg"}}}}
        """#
        let resource = try JSONDecoder().decode(YouTubeBroadcastResource.self, from: Data(withThumbs.utf8))
        #expect(resource.broadcast?.thumbnailURL == "https://img/maxres.jpg")
        let without = #"{"id":"b-1","snippet":{"title":"T"}}"#
        let bare = try JSONDecoder().decode(YouTubeBroadcastResource.self, from: Data(without.utf8))
        #expect(bare.broadcast?.thumbnailURL == nil)
    }

    @Test func saveClearsSavedSelectionOnlyWhenKnownNotToApply() {
        // Loaded for this key and "New stream" chosen: the user dropped the pick.
        #expect(PlannedStreams.shouldClearSavedSelection(choice: .newStream, plannedListLoaded: true, streamKeyChanged: false))
        // Still loading, or the load failed: "New stream" is only the default.
        #expect(!PlannedStreams.shouldClearSavedSelection(choice: .newStream, plannedListLoaded: false, streamKeyChanged: false))
        // A pick is saved by its own path, not cleared.
        #expect(!PlannedStreams.shouldClearSavedSelection(choice: .planned("b-1"), plannedListLoaded: true, streamKeyChanged: false))
        #expect(!PlannedStreams.shouldClearSavedSelection(choice: .restart, plannedListLoaded: true, streamKeyChanged: false))
        // A new key: the pick belonged to the old stream.
        #expect(PlannedStreams.shouldClearSavedSelection(choice: .newStream, plannedListLoaded: false, streamKeyChanged: true))
        #expect(PlannedStreams.shouldClearSavedSelection(choice: .newStream, plannedListLoaded: true, streamKeyChanged: true))
    }
}
