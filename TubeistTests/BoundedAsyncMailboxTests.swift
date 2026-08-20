//
//  BoundedAsyncMailboxTests.swift
//  TubeistTests
//

import Testing
@testable import Tubeist

private actor MailboxProbe {
    private var values: [Int] = []
    private var firstStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func process(_ value: Int) async {
        values.append(value)
        guard value == 1 else { return }
        firstStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitForFirstStart() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirst() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func processedValues() -> [Int] {
        values
    }
}

struct BoundedAsyncMailboxTests {
    @Test func latestPolicyRetainsOnlyProcessingAndNewestElements() async {
        let probe = MailboxProbe()
        let mailbox = BoundedAsyncMailbox<Int>(policy: .latest) { value in
            await probe.process(value)
        }

        mailbox.submit(1)
        await probe.waitForFirstStart()
        mailbox.submit(2)
        let replacement = mailbox.submit(3)
        #expect(replacement.dropped)
        #expect(mailbox.snapshot().queued == 1)

        await probe.releaseFirst()
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [1, 3])
        #expect(mailbox.snapshot().totalDropped == 1)
    }

    @Test func fifoPolicyDropsOldestQueuedElementAtItsLimit() async {
        let probe = MailboxProbe()
        let mailbox = BoundedAsyncMailbox<Int>(policy: .fifo(limit: 2)) { value in
            await probe.process(value)
        }

        mailbox.submit(1)
        await probe.waitForFirstStart()
        mailbox.submit(2)
        mailbox.submit(3)
        let overflow = mailbox.submit(4)
        #expect(overflow.dropped)
        #expect(mailbox.snapshot().queued == 2)

        await probe.releaseFirst()
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [1, 3, 4])
        #expect(mailbox.snapshot().totalDropped == 1)
    }

    @Test func deadlineReturnsWithoutDiscardingInFlightWork() async {
        let probe = MailboxProbe()
        let mailbox = BoundedAsyncMailbox<Int>(policy: .latest) { value in
            await probe.process(value)
        }
        mailbox.submit(1)
        await probe.waitForFirstStart()

        let deadline = ContinuousClock().now.advanced(by: .milliseconds(20))
        #expect(!(await mailbox.waitUntilIdle(deadline: deadline)))
        #expect(mailbox.snapshot().isProcessing)

        await probe.releaseFirst()
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [1])
    }
}
