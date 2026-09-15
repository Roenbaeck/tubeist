import Foundation
import Testing
@testable import Tubeist

@Suite(.timeLimit(.minutes(1)))
struct PreviewRenderWorkerTests {
    @Test @MainActor
    func stalledDisplayLeavesTheUIFreeAndKeepsOnlyTheLatestPendingFrame() async {
        let release = DispatchSemaphore(value: 0)
        let (events, reporter) = AsyncStream<Int>.makeStream()
        let worker = PreviewRenderWorker<Int> { frame in
            #expect(!Thread.isMainThread)
            reporter.yield(frame)
            if frame == 1 {
                #expect(release.wait(timeout: .now() + 10) == .success)
            }
        }
        defer { release.signal(); worker.stop(); reporter.finish() }
        var arrivals = events.makeAsyncIterator()
        worker.submit(1)
        #expect(await arrivals.next() == 1)

        // The display driver is still blocked. This runs on the UI actor and
        // must reach the release without waiting on that driver.
        for frame in 2...1_000 { worker.submit(frame) }
        release.signal()
        #expect(await arrivals.next() == 1_000)
    }

    @Test @MainActor
    func closingAStalledMonitorDoesNotWaitOrInterfereWithItsReplacement() async {
        let release = DispatchSemaphore(value: 0)
        let (oldEvents, oldReporter) = AsyncStream<Int>.makeStream()
        let oldWorker = PreviewRenderWorker<Int> { frame in
            oldReporter.yield(frame)
            #expect(release.wait(timeout: .now() + 10) == .success)
            oldReporter.finish()
        }
        defer { release.signal(); oldWorker.stop(); oldReporter.finish() }
        var oldArrivals = oldEvents.makeAsyncIterator()
        oldWorker.submit(1)
        #expect(await oldArrivals.next() == 1)
        oldWorker.submit(2)
        oldWorker.stop()
        oldWorker.submit(3)

        let (newEvents, newReporter) = AsyncStream<Int>.makeStream()
        let replacement = PreviewRenderWorker<Int> { newReporter.yield($0) }
        defer { replacement.stop(); newReporter.finish() }
        var newArrivals = newEvents.makeAsyncIterator()
        replacement.submit(4)
        #expect(await newArrivals.next() == 4)
        #expect(oldWorker.isStopped())
        release.signal()
        #expect(await oldArrivals.next() == nil)
        replacement.submit(5)
        #expect(await newArrivals.next() == 5)
    }
}
