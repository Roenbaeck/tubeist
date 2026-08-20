//
//  JournalTests.swift
//  TubeistTests
//

import Testing
@testable import Tubeist

struct JournalTests {
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
