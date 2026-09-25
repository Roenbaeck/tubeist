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

    @Test func acknowledgingPreservesEntriesAndNewErrorsRestoreIndicator() async {
        let journal = JournalActor(enabledLevels: Set(LogLevel.allCases))
        await journal.log(message: "stream error", level: .error)
        let original = await journal.snapshot()
        #expect(original.hasErrors)

        await journal.acknowledgeErrors()
        let acknowledged = await journal.snapshot()
        #expect(!acknowledged.hasErrors)
        #expect(acknowledged.entries.map(\.id) == original.entries.map(\.id))
        #expect(acknowledged.entries.first?.level == .error)

        await journal.log(message: "recovered", level: .info)
        await journal.log(message: "connection warning", level: .warning)
        #expect(await journal.hasErrors == false)

        // A repeated error still needs attention even though its entry is reused.
        await journal.log(message: "stream error", level: .error)
        let repeated = await journal.snapshot()
        #expect(repeated.hasErrors)
        #expect(repeated.entries.last?.id == original.entries.first?.id)
        #expect(repeated.entries.last?.repeatCount == 2)

        await journal.acknowledgeErrors()
        await journal.log(message: "different error", level: .error)
        #expect(await journal.hasErrors)
    }
}
