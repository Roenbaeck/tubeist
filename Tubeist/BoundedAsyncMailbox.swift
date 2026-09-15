//
//  BoundedAsyncMailbox.swift
//  Tubeist
//

import Foundation

enum AsyncMailboxPolicy: Sendable, Equatable {
    case latest
    case fifo(limit: Int)
    case buffered(duration: TimeInterval, limit: Int)
}

struct AsyncMailboxTiming: Sendable {
    let duration: TimeInterval
    let receivedAt: TimeInterval
}

struct AsyncMailboxSubmission: Sendable, Equatable {
    let droppedCount: Int
    let totalDropped: Int

    var dropped: Bool { droppedCount > 0 }

    func shouldReport(every interval: Int) -> Bool {
        let previous = totalDropped - droppedCount
        return dropped && (previous == 0 || previous / max(1, interval) != totalDropped / max(1, interval))
    }
}

struct AsyncMailboxSnapshot: Sendable, Equatable {
    let queued: Int
    let queuedDuration: TimeInterval
    let isProcessing: Bool
    let totalDropped: Int
}

final class BoundedAsyncMailbox<Element: Sendable>: @unchecked Sendable {
    private struct Entry {
        let element: Element
        let timing: AsyncMailboxTiming?

        var duration: TimeInterval {
            guard let duration = timing?.duration, duration.isFinite else { return 0 }
            return max(0, duration)
        }
    }

    private let lock = NSLock()
    private let policy: AsyncMailboxPolicy
    private let priority: TaskPriority
    private let processor: @Sendable (Element) async -> Void
    private let timing: (@Sendable (Element) -> AsyncMailboxTiming)?
    private let now: @Sendable () -> TimeInterval
    private let onDrop: @Sendable (AsyncMailboxSubmission) -> Void
    private var queue: [Entry] = []
    private var isProcessing = false
    private var totalDropped = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        policy: AsyncMailboxPolicy,
        priority: TaskPriority = .userInitiated,
        timing: (@Sendable (Element) -> AsyncMailboxTiming)? = nil,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onDrop: @escaping @Sendable (AsyncMailboxSubmission) -> Void = { _ in },
        processor: @escaping @Sendable (Element) async -> Void
    ) {
        if case .buffered(let duration, _) = policy {
            precondition(duration.isFinite && duration > 0 && timing != nil)
        }
        self.policy = policy
        self.priority = priority
        self.timing = timing
        self.now = now
        self.onDrop = onDrop
        self.processor = processor
    }

    @discardableResult
    func submit(_ element: Element) -> AsyncMailboxSubmission {
        let entry = Entry(element: element, timing: timing?(element))
        let result = lock.withLock { () -> (submission: AsyncMailboxSubmission, startDrain: Bool) in
            let previousDrops = totalDropped
            switch policy {
            case .latest:
                if !queue.isEmpty {
                    queue.removeAll(keepingCapacity: true)
                    totalDropped += 1
                }
                queue.append(entry)
            case .fifo(let requestedLimit):
                let limit = max(1, requestedLimit)
                if queue.count >= limit {
                    let count = queue.count - limit + 1
                    queue.removeFirst(count)
                    totalDropped += count
                }
                queue.append(entry)
            case .buffered(let duration, let requestedLimit):
                let time = now()
                discardExpired(at: time, budget: duration)
                if isExpired(entry, at: time, budget: duration) {
                    totalDropped += 1
                } else {
                    // Capture callbacks and each processing stage are serial.
                    // Preserve arrival order and start draining immediately.
                    queue.append(entry)
                    // Keep one indivisible sample even if it is longer than
                    // the budget. The count cap also bounds malformed timing.
                    while queue.count > max(1, requestedLimit) ||
                            (queue.count > 1 && queuedDuration > duration + 0.000_001) {
                        queue.removeFirst()
                        totalDropped += 1
                    }
                }
            }

            let submission = AsyncMailboxSubmission(droppedCount: totalDropped - previousDrops, totalDropped: totalDropped)
            guard !isProcessing, !queue.isEmpty else {
                return (
                    submission,
                    false
                )
            }
            isProcessing = true
            return (
                submission,
                true
            )
        }

        if result.submission.dropped { onDrop(result.submission) }
        if result.startDrain {
            Task(priority: priority) { [self] in
                await drain()
            }
        }
        return result.submission
    }

    func snapshot() -> AsyncMailboxSnapshot {
        lock.withLock {
            AsyncMailboxSnapshot(
                queued: queue.count,
                queuedDuration: queuedDuration,
                isProcessing: isProcessing,
                totalDropped: totalDropped
            )
        }
    }

    func resetDropCount() {
        lock.withLock {
            totalDropped = 0
        }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let isAlreadyIdle = lock.withLock {
                guard isProcessing || !queue.isEmpty else { return true }
                idleWaiters.append(continuation)
                return false
            }
            if isAlreadyIdle {
                continuation.resume()
            }
        }
    }

    func waitUntilIdle(deadline: ContinuousClock.Instant) async -> Bool {
        let clock = ContinuousClock()
        while clock.now < deadline {
            let isIdle = lock.withLock { !isProcessing && queue.isEmpty }
            if isIdle {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return false
            }
        }
        return lock.withLock { !isProcessing && queue.isEmpty }
    }

    private func drain() async {
        while let next = takeNext() {
            await processor(next)
        }
    }

    private func takeNext() -> Element? {
        var waiters: [CheckedContinuation<Void, Never>] = []
        var drops: AsyncMailboxSubmission?
        let element: Element? = lock.withLock { () -> Element? in
            let previousDrops = totalDropped
            if case .buffered(let duration, _) = policy {
                // Also expire at dequeue: after a stall there may be no new
                // submission to remove old work. In-flight work is never cancelled.
                discardExpired(at: now(), budget: duration)
            }
            if totalDropped > previousDrops {
                drops = AsyncMailboxSubmission(droppedCount: totalDropped - previousDrops, totalDropped: totalDropped)
            }
            guard !queue.isEmpty else {
                isProcessing = false
                waiters = idleWaiters
                idleWaiters.removeAll(keepingCapacity: true)
                return nil
            }
            return queue.removeFirst().element
        }
        if let drops { onDrop(drops) }
        waiters.forEach { $0.resume() }
        return element
    }

    // Accessed only while holding lock.
    private var queuedDuration: TimeInterval {
        queue.reduce(0) { $0 + $1.duration }
    }

    private func isExpired(_ entry: Entry, at time: TimeInterval, budget: TimeInterval) -> Bool {
        guard let receivedAt = entry.timing?.receivedAt, receivedAt.isFinite else { return true }
        return time - receivedAt > budget
    }

    private func discardExpired(at time: TimeInterval, budget: TimeInterval) {
        let previousCount = queue.count
        queue.removeAll { isExpired($0, at: time, budget: budget) }
        totalDropped += previousCount - queue.count
    }
}
