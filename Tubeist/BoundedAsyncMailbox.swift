//
//  BoundedAsyncMailbox.swift
//  Tubeist
//

import Foundation

enum AsyncMailboxPolicy: Sendable, Equatable {
    case latest
    case fifo(limit: Int)
}

struct AsyncMailboxSubmission: Sendable, Equatable {
    let dropped: Bool
    let totalDropped: Int
}

struct AsyncMailboxSnapshot: Sendable, Equatable {
    let queued: Int
    let isProcessing: Bool
    let totalDropped: Int
}

final class BoundedAsyncMailbox<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let policy: AsyncMailboxPolicy
    private let priority: TaskPriority
    private let processor: @Sendable (Element) async -> Void
    private var queue: [Element] = []
    private var isProcessing = false
    private var totalDropped = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        policy: AsyncMailboxPolicy,
        priority: TaskPriority = .userInitiated,
        processor: @escaping @Sendable (Element) async -> Void
    ) {
        self.policy = policy
        self.priority = priority
        self.processor = processor
    }

    @discardableResult
    func submit(_ element: Element) -> AsyncMailboxSubmission {
        let result = lock.withLock { () -> (submission: AsyncMailboxSubmission, startDrain: Bool) in
            var dropped = false
            switch policy {
            case .latest:
                if !queue.isEmpty {
                    queue.removeAll(keepingCapacity: true)
                    totalDropped += 1
                    dropped = true
                }
                queue.append(element)
            case .fifo(let requestedLimit):
                let limit = max(1, requestedLimit)
                if queue.count >= limit {
                    queue.removeFirst(queue.count - limit + 1)
                    totalDropped += 1
                    dropped = true
                }
                queue.append(element)
            }

            guard !isProcessing else {
                return (
                    AsyncMailboxSubmission(dropped: dropped, totalDropped: totalDropped),
                    false
                )
            }
            isProcessing = true
            return (
                AsyncMailboxSubmission(dropped: dropped, totalDropped: totalDropped),
                true
            )
        }

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
        let element: Element? = lock.withLock { () -> Element? in
            guard !queue.isEmpty else {
                isProcessing = false
                waiters = idleWaiters
                idleWaiters.removeAll(keepingCapacity: true)
                return nil
            }
            return queue.removeFirst()
        }
        waiters.forEach { $0.resume() }
        return element
    }
}
