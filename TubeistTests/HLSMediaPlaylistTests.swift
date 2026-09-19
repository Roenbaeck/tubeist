//
//  HLSMediaPlaylistTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct HLSMediaPlaylistTests {
    @Test func rendersLivePlaylistThroughEndList() throws {
        var playlist = try HLSMediaPlaylist(
            sessionIdentifier: "20260819_003000_a1b2c3d4e5f6"
        )
        let first = try playlist.append(duration: 1.95)
        #expect(first.sequence == 0)
        #expect(first.filename == "tOyFz3FCiDGeSA1X2QM4uRA_0.ts")
        #expect(playlist.targetDuration == 5)
        #expect(playlist.render() == """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:5
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-DISCONTINUITY-SEQUENCE:0
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXTINF:1.950000,
        tOyFz3FCiDGeSA1X2QM4uRA_0.ts

        """)

        let firstSnapshot = playlist.render()
        try playlist.acknowledge(sequence: 0)
        #expect(playlist.render() == firstSnapshot)
        _ = try playlist.append(duration: 3.01, discontinuity: true)
        #expect(playlist.targetDuration == 5)
        #expect(playlist.render().contains("#EXT-X-DISCONTINUITY\n#EXTINF:3.010000,"))
        try playlist.acknowledge(sequence: 1)
        _ = try playlist.append(duration: 1.1)
        try playlist.acknowledge(sequence: 2)
        #expect(playlist.entries.map(\.sequence) == [0, 1, 2])
        #expect(playlist.mediaSequence == 0)
        #expect(playlist.render().hasPrefix(firstSnapshot))
        #expect(playlist.targetDuration == 5) // target duration never changes
        #expect(!playlist.render().contains("#EXT-X-ENDLIST"))
        #expect(playlist.render(endList: true) == playlist.render() + "#EXT-X-ENDLIST\n")
    }


    @Test func keepsFifteenEntriesAcrossThreeHoursIncludingTheFinalPartialSegment() throws {
        var playlist = try HLSMediaPlaylist(sessionIdentifier: "long_session")
        for index in 0..<5_400 {
            let entry = try playlist.append(duration: index == 5_399 ? 0.2 : 2)
            try playlist.acknowledge(sequence: entry.sequence)
            #expect(playlist.entries.count == min(index + 1, 15))
            #expect(playlist.mediaSequence == max(0, index - 14))
        }
        #expect(playlist.entries.map(\.sequence) == Array(5_385..<5_400))
        #expect(playlist.entries.last?.duration == 0.2)
        #expect(playlist.outstandingCount == 0)
        #expect(playlist.queuedDuration == 0)
        #expect(playlist.render().utf8.count < 1_000)
        #expect(!playlist.render().contains("#EXT-X-PLAYLIST-TYPE"))
        #expect(playlist.render(endList: true) == playlist.render() + "#EXT-X-ENDLIST\n")
    }

    @Test func carriesRemovedDiscontinuitiesIntoTheSequenceHeader() throws {
        var playlist = try HLSMediaPlaylist(sessionIdentifier: "discontinuities")
        for index in 0..<40 {
            let entry = try playlist.append(duration: 2, discontinuity: [1, 5, 25, 30].contains(index))
            try playlist.acknowledge(sequence: entry.sequence)
        }
        #expect(playlist.mediaSequence == 25)
        #expect(playlist.discontinuitySequence == 2)
        #expect(playlist.entries.filter(\.discontinuity).map(\.sequence) == [25, 30])
        #expect(playlist.render().contains("#EXT-X-DISCONTINUITY-SEQUENCE:2\n"))
        let next = try playlist.append(duration: 2)
        try playlist.acknowledge(sequence: next.sequence)
        #expect(playlist.discontinuitySequence == 3)
        #expect(playlist.entries.filter(\.discontinuity).map(\.sequence) == [30])
    }

    @Test func neverRemovesAnUnacknowledgedEntryOrSkipsOverIt() throws {
        var playlist = try HLSMediaPlaylist(sessionIdentifier: "pending")
        _ = try playlist.append(duration: 2, discontinuity: true)
        for _ in 0..<20 {
            let entry = try playlist.append(duration: 2)
            try playlist.acknowledge(sequence: entry.sequence)
        }
        #expect(playlist.entries.count == 21)
        #expect(playlist.mediaSequence == 0)
        #expect(playlist.discontinuitySequence == 0)
        #expect(playlist.outstandingCount == 1)
        try playlist.acknowledge(sequence: 0)
        #expect(playlist.entries.map(\.sequence) == Array(6...20))
        #expect(playlist.discontinuitySequence == 1)
    }

    @Test func unusuallyShortSegmentsKeepTheMinimumLiveWindow() throws {
        var playlist = try HLSMediaPlaylist(sessionIdentifier: "short")
        for _ in 0..<40 {
            let entry = try playlist.append(duration: 0.5)
            try playlist.acknowledge(sequence: entry.sequence)
        }
        #expect(playlist.entries.count == 30)
        #expect(playlist.entries.reduce(0) { $0 + $1.duration } == 15)
        #expect(playlist.mediaSequence == 10)
        for _ in 0..<15 {
            let entry = try playlist.append(duration: 2)
            try playlist.acknowledge(sequence: entry.sequence)
        }
        #expect(playlist.entries.count == 15)
        #expect(playlist.mediaSequence == 40)
    }

    @Test func compactNamesAreStableUniqueAndUseBase36Sequences() throws {
        let first = try HLSMediaPlaylist(sessionIdentifier: "first")
        let same = try HLSMediaPlaylist(sessionIdentifier: "first")
        let other = try HLSMediaPlaylist(sessionIdentifier: "other")
        #expect(first.playlistFilename == same.playlistFilename)
        #expect(first.playlistFilename != other.playlistFilename)
        #expect(first.mediaFilename(sequence: 35).hasSuffix("_z.ts"))
        #expect(first.mediaFilename(sequence: 36).hasSuffix("_10.ts"))
        #expect(first.mediaFilename(sequence: 5_399).hasSuffix("_45z.ts"))
        #expect(first.mediaFilename(sequence: 5_399).count == 30)
        #expect(first.playlistFilename.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95 || $0 == 46
        })
    }

    @Test func capsOutstandingWindowAtFive() throws {
        var playlist = try HLSMediaPlaylist(sessionIdentifier: "safe_session")
        for _ in 0..<HLSMediaPlaylist.maximumOutstandingSegments {
            _ = try playlist.append(duration: 2)
        }
        #expect(playlist.outstandingCount == 5)
        #expect(playlist.queuedDuration == 10)
        do {
            _ = try playlist.append(duration: 2)
            Issue.record("Expected outstanding segment limit")
        } catch let error as HLSPlaylistError {
            #expect(error == .tooManyOutstandingSegments)
        }
        try playlist.acknowledge(sequence: 0)
        let entry = try playlist.append(duration: 1.5)
        #expect(entry.sequence == 5)
        #expect(playlist.entries.count == 6)
        #expect(playlist.outstandingCount == 5)
        #expect(playlist.queuedDuration == 9.5)
    }

    @Test func createsCollisionResistantSafeSessionNames() {
        let date = Date(timeIntervalSince1970: 1_787_099_400)
        let first = HLSMediaPlaylist.makeSessionIdentifier(
            at: date,
            uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let second = HLSMediaPlaylist.makeSessionIdentifier(
            at: date,
            uuid: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        #expect(first != second)
        #expect(first.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x5f
        })
    }
}
