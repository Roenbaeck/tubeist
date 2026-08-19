//
//  HLSMediaPlaylistTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct HLSMediaPlaylistTests {
    @Test func rendersDeterministicRollingMediaPlaylist() throws {
        var playlist = try HLSMediaPlaylist(
            sessionIdentifier: "20260819_003000_a1b2c3d4e5f6",
            acknowledgedTailCount: 2
        )
        let first = try playlist.append(duration: 1.95)
        #expect(first.sequence == 0)
        #expect(first.filename == "tubeist_20260819_003000_a1b2c3d4e5f6_0.ts")
        #expect(playlist.targetDuration == 2)
        #expect(playlist.render() == """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXTINF:1.950000,
        tubeist_20260819_003000_a1b2c3d4e5f6_0.ts

        """)

        try playlist.acknowledge(sequence: 0)
        _ = try playlist.append(duration: 3.01, discontinuity: true)
        #expect(playlist.targetDuration == 4)
        #expect(playlist.render().contains("#EXT-X-DISCONTINUITY\n#EXTINF:3.010000,"))
        try playlist.acknowledge(sequence: 1)
        _ = try playlist.append(duration: 1.1)
        try playlist.acknowledge(sequence: 2)
        #expect(playlist.entries.map(\.sequence) == [1, 2])
        #expect(playlist.mediaSequence == 1)
        #expect(playlist.targetDuration == 4) // target duration never decreases
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
