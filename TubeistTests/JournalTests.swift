//
//  JournalTests.swift
//  TubeistTests
//

import Testing
import Foundation
@testable import Tubeist

struct JournalTests {
    @Test func messagesArrivingDuringPublicationScheduleAFollowupWithoutASecondPublisher() {
        let gate = JournalPublicationGate()
        #expect(gate.claim())
        #expect(!gate.claim()) // A message arrives after the first snapshot.
        #expect(gate.finishPublication()) // The current publisher must refresh.
        #expect(!gate.claim()) // Still only one publisher while that refresh runs.
        #expect(gate.finishPublication())
        #expect(!gate.finishPublication())
        #expect(gate.claim()) // A later burst can start a new publisher.
    }

    @Test func firstMessageUsesSavedLevelsWithoutWaitingForConfiguration() async throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let journal = JournalActor(enabledLevels: Settings.journalLevels(in: defaults))
        await journal.log(message: "Starting Tubeist version test", level: .info)
        await journal.log(message: "debug hidden", level: .debug)
        #expect(await journal.getJournal().map(\.message) == ["Starting Tubeist version test"])
    }

    @Test func startupHonorsExplicitlyDisabledInfoAndEnabledDebug() async throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "JournalInfo")
        defaults.set(true, forKey: "JournalDebug")
        let journal = JournalActor(enabledLevels: Settings.journalLevels(in: defaults))
        await journal.log(message: "info hidden", level: .info)
        await journal.log(message: "debug visible", level: .debug)
        #expect(await journal.getJournal().map(\.message) == ["debug visible"])
        await journal.setLevels([.info])
        await journal.log(message: "new info", level: .info)
        await journal.log(message: "new debug hidden", level: .debug)
        #expect(await journal.getJournal().map(\.message) == ["debug visible", "new info"])
    }

    @Test func journalCoalescesRepeatsAndBoundsUniqueMessages() async {
        let journal = JournalActor(entryLimit: 2)
        await journal.enable(level: .warning)

        await journal.log(message: "first", level: .warning)
        await journal.log(message: "first", level: .warning)
        await journal.log(message: "second", level: .warning)
        await journal.log(message: "third", level: .warning)

        let entries = await journal.getJournal()
        #expect(entries.count == 2)
        #expect(!entries.contains(where: { $0.message == "first" }))
        #expect(entries.contains(where: { $0.message == "second" }))
        #expect(entries.contains(where: { $0.message == "third" }))
    }
}
