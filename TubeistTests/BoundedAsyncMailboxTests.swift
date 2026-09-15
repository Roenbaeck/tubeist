//
//  BoundedAsyncMailboxTests.swift
//  TubeistTests
//

import Foundation
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

private final class MailboxClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func read() -> TimeInterval { lock.withLock { value } }
    func set(_ time: TimeInterval) { lock.withLock { value = time } }
}

private final class MailboxDropReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [AsyncMailboxSubmission] = []

    func append(_ report: AsyncMailboxSubmission) { lock.withLock { reports.append(report) } }
    func read() -> [AsyncMailboxSubmission] { lock.withLock { reports } }
}

private struct TimedMailboxValue: Sendable {
    let number: Int
    let duration: TimeInterval
    var receivedAt: TimeInterval = 0

    var timing: AsyncMailboxTiming {
        AsyncMailboxTiming(duration: duration, receivedAt: receivedAt)
    }
}

private func timedMailbox(_ probe: MailboxProbe, clock: MailboxClock,
                          policy: AsyncMailboxPolicy = CaptureBuffering.videoPolicy) -> BoundedAsyncMailbox<TimedMailboxValue> {
    BoundedAsyncMailbox(policy: policy, timing: { $0.timing }, now: { clock.read() }) { value in
        await probe.process(value.number)
    }
}

struct BoundedAsyncMailboxTests {
    @Test func shortStallKeepsWaitingFramesInArrivalOrder() async {
        let probe = MailboxProbe()
        let clock = MailboxClock()
        let mailbox = timedMailbox(probe, clock: clock)
        mailbox.submit(TimedMailboxValue(number: 1, duration: 1.0 / 60))
        // The first item starts immediately, without waiting to fill the buffer.
        await probe.waitForFirstStart()
        mailbox.submit(TimedMailboxValue(number: 3, duration: 1.0 / 60))
        mailbox.submit(TimedMailboxValue(number: 2, duration: 1.0 / 60))
        mailbox.submit(TimedMailboxValue(number: 4, duration: 1.0 / 60))
        clock.set(0.05)
        await probe.releaseFirst()
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [1, 3, 2, 4])
        #expect(mailbox.snapshot().totalDropped == 0)
    }

    @Test(arguments: [30.0, 60.0])
    func videoBudgetTracksFrameDuration(frameRate: Double) async {
        let probe = MailboxProbe()
        let clock = MailboxClock()
        let mailbox = timedMailbox(probe, clock: clock)
        let duration = 1 / frameRate
        mailbox.submit(TimedMailboxValue(number: 1, duration: duration))
        await probe.waitForFirstStart()
        let capacity = Int((CaptureBuffering.duration * frameRate).rounded())
        for number in 2...(capacity + 1) {
            #expect(!mailbox.submit(TimedMailboxValue(number: number, duration: duration)).dropped)
        }
        #expect(mailbox.snapshot().queued == capacity)
        #expect(abs(mailbox.snapshot().queuedDuration - CaptureBuffering.duration) < 0.000_001)
        #expect(mailbox.submit(TimedMailboxValue(number: capacity + 2, duration: duration)).dropped)
        await probe.releaseFirst()
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [1] + Array(3...(capacity + 2)))
        #expect(mailbox.snapshot().totalDropped == 1)
    }

    @Test(arguments: [44100.0, 48000.0])
    func audioRetainsItsLargerBacklogBeyondTheVideoDeadline(sampleRate: Double) async {
        let probe = MailboxProbe()
        let clock = MailboxClock()
        let mailbox = timedMailbox(probe, clock: clock, policy: CaptureBuffering.audioPolicy)
        let duration = 1024 / sampleRate
        mailbox.submit(TimedMailboxValue(number: 1, duration: duration))
        await probe.waitForFirstStart()
        for number in 2...33 {
            mailbox.submit(TimedMailboxValue(number: number, duration: duration))
        }
        let snapshot = mailbox.snapshot()
        #expect(snapshot.queuedDuration > 0.6)
        #expect(snapshot.queued == 32)
        #expect(snapshot.totalDropped == 0)
        #expect(mailbox.submit(TimedMailboxValue(number: 34, duration: duration)).dropped)
        clock.set(0.5)
        await probe.releaseFirst()
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [1] + Array(3...34))
        #expect(mailbox.snapshot().totalDropped == 1)
    }

    @Test func expiredQueueDrainsWithoutNewArrivalsAndCountsEveryDiscard() async {
        let probe = MailboxProbe()
        let clock = MailboxClock()
        let reports = MailboxDropReports()
        let mailbox = BoundedAsyncMailbox<TimedMailboxValue>(
            policy: CaptureBuffering.videoPolicy, timing: { $0.timing }, now: { clock.read() },
            onDrop: { reports.append($0) }
        ) { value in await probe.process(value.number) }
        mailbox.submit(TimedMailboxValue(number: 1, duration: 0.02))
        await probe.waitForFirstStart()
        for number in 2...4 {
            mailbox.submit(TimedMailboxValue(number: number, duration: 0.02))
        }
        clock.set(0.101)
        await probe.releaseFirst()
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [1])
        #expect(mailbox.snapshot().totalDropped == 3)
        #expect(!mailbox.snapshot().isProcessing)
        #expect(reports.read() == [AsyncMailboxSubmission(droppedCount: 3, totalDropped: 3)])
    }

    @Test func videoStagesShareTheOriginalArrivalDeadline() async {
        let clock = MailboxClock()
        let encoder = MailboxProbe()
        let encodingMailbox = timedMailbox(encoder, clock: clock)
        encodingMailbox.submit(TimedMailboxValue(number: 1, duration: 0.02))
        await encoder.waitForFirstStart()
        let processingMailbox = BoundedAsyncMailbox<TimedMailboxValue>(
            policy: CaptureBuffering.videoPolicy, timing: { $0.timing }, now: { clock.read() }
        ) { value in
            clock.set(0.08)
            encodingMailbox.submit(value)
        }
        processingMailbox.submit(TimedMailboxValue(number: 2, duration: 0.02, receivedAt: 0))
        await processingMailbox.waitUntilIdle()
        #expect(encodingMailbox.snapshot().queued == 1)
        clock.set(0.12)
        await encoder.releaseFirst()
        await encodingMailbox.waitUntilIdle()
        #expect(await encoder.processedValues() == [1])
        #expect(encodingMailbox.snapshot().totalDropped == 1)
        #expect(processingMailbox.snapshot().totalDropped == 0)
    }

    @Test func expiredInputDoesNotStartADrainAndFreshInputCanResume() async {
        let probe = MailboxProbe()
        let clock = MailboxClock()
        let mailbox = timedMailbox(probe, clock: clock)
        clock.set(10)
        #expect(mailbox.submit(TimedMailboxValue(number: 2, duration: 0.02)).dropped)
        await mailbox.waitUntilIdle()
        #expect(!mailbox.snapshot().isProcessing)
        mailbox.submit(TimedMailboxValue(number: 3, duration: 0.02, receivedAt: 10))
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [3])
    }

    @Test func itemCapStillBoundsMissingDurationsAndBurstArrivals() async {
        let probe = MailboxProbe()
        let clock = MailboxClock()
        let mailbox = timedMailbox(probe, clock: clock)
        mailbox.submit(TimedMailboxValue(number: 1, duration: 0))
        await probe.waitForFirstStart()
        for number in 2...101 {
            mailbox.submit(TimedMailboxValue(number: number, duration: .nan))
        }
        #expect(mailbox.snapshot().queued == 6)
        #expect(mailbox.snapshot().totalDropped == 94)
        await probe.releaseFirst()
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [1] + Array(96...101))
    }

    @Test func durationOverflowCountsMultipleDropsAndPreservesWholeAudioBlocks() async {
        let probe = MailboxProbe()
        let clock = MailboxClock()
        // Exercise the generic time-budget policy; live audio deliberately uses
        // the larger FIFO policy tested above instead of this short cutoff.
        let mailbox = timedMailbox(probe, clock: clock, policy: .buffered(duration: 0.1, limit: 32))
        mailbox.submit(TimedMailboxValue(number: 1, duration: 0.02))
        await probe.waitForFirstStart()
        for number in 2...5 {
            mailbox.submit(TimedMailboxValue(number: number, duration: 0.02))
        }
        let submission = mailbox.submit(TimedMailboxValue(number: 6, duration: 0.2))
        #expect(submission.totalDropped == 4)
        #expect(mailbox.snapshot().queued == 1)
        await probe.releaseFirst()
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [1, 6])
    }

    @Test func batchedDropsStillReportTheFirstEventAndCrossedIntervals() {
        #expect(AsyncMailboxSubmission(droppedCount: 3, totalDropped: 3).shouldReport(every: 120))
        #expect(!AsyncMailboxSubmission(droppedCount: 3, totalDropped: 6).shouldReport(every: 120))
        #expect(AsyncMailboxSubmission(droppedCount: 6, totalDropped: 124).shouldReport(every: 120))
    }

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

    @Test func resettingStreamDropCountPreservesPreviewWorkAndCountsOnlyNewDrops() async {
        let probe = MailboxProbe()
        let mailbox = BoundedAsyncMailbox<Int>(policy: .latest) { value in
            await probe.process(value)
        }

        mailbox.submit(1)
        await probe.waitForFirstStart()
        mailbox.submit(2)
        mailbox.submit(3)
        #expect(mailbox.snapshot().totalDropped == 1)

        // Streaming starts while the output preview is still processing.
        mailbox.resetDropCount()
        #expect(mailbox.snapshot().totalDropped == 0)
        #expect(mailbox.snapshot().isProcessing)
        #expect(mailbox.snapshot().queued == 1)
        #expect(mailbox.submit(4).totalDropped == 1)
        #expect(mailbox.submit(5).totalDropped == 2)

        await probe.releaseFirst()
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [1, 5])
        #expect(mailbox.snapshot().totalDropped == 2)

        // A following stream must also report zero when no work was dropped.
        mailbox.resetDropCount()
        mailbox.submit(6)
        await mailbox.waitUntilIdle()
        #expect(await probe.processedValues() == [1, 5, 6])
        #expect(mailbox.snapshot().totalDropped == 0)
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
