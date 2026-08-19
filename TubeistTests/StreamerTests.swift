//
//  StreamerTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct StreamerTests {
    @Test func outputPlanCoversTheRecordRelayAndDirectRegressionMatrix() throws {
        let cases: [(StreamOutputPlan, Bool, Bool, StreamDestination)] = [
            (StreamOutputPlan(delivery: .none, recordsOriginalFMP4: true), false, true, .relay),
            (StreamOutputPlan(delivery: .relay, recordsOriginalFMP4: false), true, false, .relay),
            (StreamOutputPlan(delivery: .relay, recordsOriginalFMP4: true), true, true, .relay),
            (StreamOutputPlan(delivery: .youTubeDirect, recordsOriginalFMP4: false), true, false, .youTubeDirect),
            (StreamOutputPlan(delivery: .youTubeDirect, recordsOriginalFMP4: true), true, true, .youTubeDirect),
        ]

        for (expected, stream, record, destination) in cases {
            let plan = try StreamOutputPlan.resolve(
                stream: stream,
                record: record,
                destination: destination,
                target: "youtube",
                directYouTubeAvailable: true
            )
            #expect(plan == expected)
            #expect(plan.routesEncodedFragments == stream)
            #expect(plan.uploadsOriginalFMP4 == (stream && destination == .relay))
            #expect(plan.remuxesToTransportStream == (stream && destination == .youTubeDirect))
        }
    }

    @Test func recordOnlyIgnoresAnUnavailableDirectDestination() throws {
        let plan = try StreamOutputPlan.resolve(
            stream: false,
            record: true,
            destination: .youTubeDirect,
            target: "twitch",
            directYouTubeAvailable: false
        )
        #expect(plan == StreamOutputPlan(delivery: .none, recordsOriginalFMP4: true))
    }

    @Test(arguments: [
        (false, "youtube", StreamStartError.directModeUnavailable),
        (true, "twitch", StreamStartError.directModeRequiresYouTube),
    ])
    func directOutputRejectsUnavailableOrNonYouTubeConfigurations(
        directAvailable: Bool,
        target: String,
        expected: StreamStartError
    ) {
        do {
            _ = try StreamOutputPlan.resolve(
                stream: true,
                record: false,
                destination: .youTubeDirect,
                target: target,
                directYouTubeAvailable: directAvailable
            )
            Issue.record("Expected invalid direct-output configuration to fail")
        } catch let error as StreamStartError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected output-plan error: \(error)")
        }
    }

    @Test func sameSecondStreamRestartsHaveDistinctSafeIdentifiers() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let firstUUID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let secondUUID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let first = Streamer.makeStreamID(
            at: date,
            uuid: firstUUID
        )
        let second = Streamer.makeStreamID(
            at: date,
            uuid: secondUUID
        )

        #expect(first != second)
        #expect(first.hasSuffix("_111111111111"))
        #expect(second.hasSuffix("_222222222222"))
        #expect(first.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5f
        })
    }
}
