import Foundation
import Testing
@testable import Tubeist

struct HorizonLevelFilterTests {
    @Test func landscapeHorizonUsesGravityRegardlessOfHeadingOrPitch() throws {
        for direction in [1.0, -1.0] {
            var filter = HorizonLevelFilter()
            let result = filter.update(HorizonGravity(x: direction * 0.6, y: 0, z: -0.8))
            let angle = try #require(result)
            #expect(abs(angle) < 0.0001)
        }
    }

    @Test func projectsTiltInBothDirectionsIntoScreenCoordinates() throws {
        // In landscape, screen-down is sensor x and screen-left is sensor y.
        // A positive y component makes the horizon slope clockwise on screen.
        for degrees in [-30.0, -5.0, 5.0, 30.0] {
            var filter = HorizonLevelFilter()
            let radians = degrees * .pi / 180
            let result = filter.update(HorizonGravity(x: cos(radians), y: sin(radians), z: 0))
            let angle = try #require(result)
            #expect(abs(angle - degrees) < 0.0001)
        }
    }

    @Test func lookingStraightUpOrDownCannotReportAFalseLevel() {
        var filter = HorizonLevelFilter()
        _ = filter.update(HorizonGravity(x: 1, y: 0, z: 0))
        #expect(filter.update(HorizonGravity(x: 0.01, y: 0.01, z: 1)) == nil)
        #expect(filter.update(HorizonGravity(x: 0, y: 0, z: -1)) == nil)
        #expect(filter.update(HorizonGravity(x: .nan, y: 0, z: 0)) == nil)
        #expect(!HorizonLevelReading.indeterminate.isLevel)
    }

    @Test func smoothingTakesTheShortPathAcrossTheVerticalBoundary() throws {
        var filter = HorizonLevelFilter()
        let first = 89.0 * .pi / 180
        _ = filter.update(HorizonGravity(x: cos(first), y: sin(first), z: 0))
        let next = -89.0 * .pi / 180
        let result = filter.update(HorizonGravity(x: cos(next), y: sin(next), z: 0))
        let angle = try #require(result)
        #expect(abs(angle) > 89)
        #expect(!HorizonLevelReading.angle(angle).isLevel)
    }

    @Test func smoothingConvergesToLevelAfterAdjustment() throws {
        var filter = HorizonLevelFilter()
        _ = filter.update(HorizonGravity(x: 0.8, y: 0.6, z: 0))
        var angle = 90.0
        for _ in 0..<20 {
            let result = filter.update(HorizonGravity(x: 1, y: 0, z: 0))
            angle = try #require(result)
        }
        #expect(HorizonLevelReading.angle(angle).isLevel)
    }
}

@MainActor
private final class HorizonMotionProbe: HorizonMotionSource {
    var isAvailable = true
    var sample: HorizonGravity? = HorizonGravity(x: 1, y: 0, z: 0)
    var starts = 0
    var stops = 0
    var reads = 0
    var isRunning = false
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var readWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var gravity: HorizonGravity? {
        reads += 1
        let ready = readWaiters.filter { $0.0 <= reads }
        readWaiters.removeAll { $0.0 <= reads }
        ready.forEach { $0.1.resume() }
        return sample
    }

    func start() {
        starts += 1
        isRunning = true
        let ready = startWaiters.filter { $0.0 <= starts }
        startWaiters.removeAll { $0.0 <= starts }
        ready.forEach { $0.1.resume() }
    }

    func stop() {
        stops += 1
        isRunning = false
    }

    func waitForStart(_ count: Int) async {
        guard starts < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func waitForRead(_ count: Int) async {
        guard reads < count else { return }
        await withCheckedContinuation { readWaiters.append((count, $0)) }
    }
}

@MainActor
struct HorizonLevelLifecycleTests {
    @Test func constructingTheModelDoesNotStartMotion() {
        let motion = HorizonMotionProbe()
        let model = HorizonLevelModel(motion: motion)
        #expect(model.reading == .waiting)
        #expect(motion.starts == 0)
        #expect(motion.reads == 0)
    }

    @Test func cancellingTheVisibleTaskStopsMotion() async {
        let motion = HorizonMotionProbe()
        let model = HorizonLevelModel(motion: motion)
        let task = Task { await model.run() }
        await motion.waitForStart(1)
        #expect(model.reading.isLevel)
        task.cancel()
        await task.value
        #expect(!motion.isRunning)
        #expect(motion.stops == 1)
    }

    @Test func oldTaskCannotStopAQuicklyReopenedLevel() async {
        let motion = HorizonMotionProbe()
        let model = HorizonLevelModel(motion: motion)
        let old = Task { await model.run() }
        await motion.waitForStart(1)
        model.stop()
        let current = Task { await model.run() }
        await motion.waitForStart(2)
        old.cancel()
        await old.value
        #expect(motion.isRunning)
        #expect(motion.stops == 1)
        current.cancel()
        await current.value
        #expect(!motion.isRunning)
        #expect(motion.stops == 2)
    }

    @Test func unavailableHardwareDoesNotStartAPollingLoop() async {
        let motion = HorizonMotionProbe()
        motion.isAvailable = false
        let model = HorizonLevelModel(motion: motion)
        await model.run()
        #expect(model.reading == .unavailable)
        #expect(motion.starts == 0)
        #expect(motion.reads == 0)
    }

    @Test func missingMotionDataStopsInsteadOfPollingForever() async {
        let motion = HorizonMotionProbe()
        motion.sample = nil
        let model = HorizonLevelModel(motion: motion)
        await model.run()
        #expect(model.reading == .unavailable)
        #expect(motion.stops == 1)
        #expect(!motion.isRunning)
    }

    @Test func smallChangesStillUpdateTheLevelColorAtTheThreshold() async {
        let motion = HorizonMotionProbe()
        let initial = 0.52 * .pi / 180
        motion.sample = HorizonGravity(x: cos(initial), y: sin(initial), z: 0)
        let model = HorizonLevelModel(motion: motion)
        let task = Task { await model.run() }
        await motion.waitForRead(1)
        #expect(!model.reading.isLevel)
        let adjusted = 0.4 * .pi / 180
        motion.sample = HorizonGravity(x: cos(adjusted), y: sin(adjusted), z: 0)
        await motion.waitForRead(2)
        #expect(model.reading.isLevel)
        task.cancel()
        await task.value
    }
}
