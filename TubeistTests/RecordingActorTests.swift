//
//  RecordingActorTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

enum InjectedRecordingIOError: Error, Equatable {
    case write
    case synchronize
    case close
}

private final class InjectedRecordingFile: RecordingFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    let writeDelay: TimeInterval
    let failure: InjectedRecordingIOError?
    private var storedData = Data()
    private var storedSynchronizeCount = 0
    private var storedCloseCount = 0

    var data: Data { lock.withLock { storedData } }
    var synchronizeCount: Int { lock.withLock { storedSynchronizeCount } }
    var closeCount: Int { lock.withLock { storedCloseCount } }

    init(writeDelay: TimeInterval = 0, failure: InjectedRecordingIOError? = nil) {
        self.writeDelay = writeDelay
        self.failure = failure
    }

    func write(_ data: Data) throws {
        if writeDelay > 0 {
            Thread.sleep(forTimeInterval: writeDelay)
        }
        if failure == .write {
            throw InjectedRecordingIOError.write
        }
        lock.withLock {
            storedData.append(data)
        }
    }

    func synchronize() throws {
        lock.withLock { storedSynchronizeCount += 1 }
        if failure == .synchronize {
            throw InjectedRecordingIOError.synchronize
        }
    }

    func close() throws {
        lock.withLock { storedCloseCount += 1 }
        if failure == .close {
            throw InjectedRecordingIOError.close
        }
    }
}

private struct InjectedRecordingFileFactory: RecordingFileCreating {
    let file: InjectedRecordingFile

    func createFile(at url: URL) throws -> any RecordingFileWriting {
        file
    }
}

struct RecordingActorTests {
    @Test func finishClosesTheCompleteRecording() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tubeist-recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let recording = RecordingActor(recordingFolder: folder)
        await recording.prepareForNewSession()
        await recording.enqueueFragment(Fragment(
            sequence: 0,
            segment: Data("init".utf8),
            duration: 0,
            type: .initialization
        ))
        await recording.enqueueFragment(Fragment(
            sequence: 1,
            segment: Data("media".utf8),
            duration: 2,
            type: .separable
        ))
        await recording.enqueueFragment(Fragment(
            sequence: 2,
            segment: Data("tail".utf8),
            duration: 0.5,
            type: .finalization
        ))

        try await recording.finish()
        let url = try #require(await recording.recordingURL())
        #expect(try Data(contentsOf: url) == Data("initmediatail".utf8))
    }

    @Test func finishClosesARecordingWithoutAFinalizationFragment() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tubeist-recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let recording = RecordingActor(recordingFolder: folder)
        await recording.prepareForNewSession()
        await recording.enqueueFragment(Fragment(
            sequence: 0,
            segment: Data("init".utf8),
            duration: 0,
            type: .initialization
        ))
        await recording.enqueueFragment(Fragment(
            sequence: 1,
            segment: Data("media".utf8),
            duration: 2,
            type: .separable
        ))

        try await recording.finish()
        let url = try #require(await recording.recordingURL())
        #expect(try Data(contentsOf: url) == Data("initmedia".utf8))
    }

    @Test func multipleFinalCallbacksRemainOrderedUntilTheFinishBarrier() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tubeist-recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let recording = RecordingActor(recordingFolder: folder)
        let dispatcher = OrderedFragmentDispatcher()
        await recording.prepareForNewSession()
        await dispatcher.prepare(stream: false, record: true)

        await dispatcher.enqueue(Fragment(
            sequence: 1,
            segment: Data("video-tail".utf8),
            duration: 0.2,
            type: .finalization
        ), recording: recording)
        await dispatcher.enqueue(Fragment(
            sequence: 0,
            segment: Data("init".utf8),
            duration: 0,
            type: .initialization
        ), recording: recording)
        await dispatcher.enqueue(Fragment(
            sequence: 2,
            segment: Data("audio-tail".utf8),
            duration: 0.2,
            type: .finalization
        ), recording: recording)

        try await recording.finish()
        let url = try #require(await recording.recordingURL())
        #expect(try Data(contentsOf: url) == Data("initvideo-tailaudio-tail".utf8))
    }

    @Test func finishReportsAMissingInitializationFragment() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tubeist-recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let recording = RecordingActor(recordingFolder: folder)
        await recording.prepareForNewSession()

        await #expect(throws: RecordingError.self) {
            try await recording.finish()
        }
    }

    @Test func writeFailureIsRetainedUntilTheFinishBarrier() async throws {
        let file = InjectedRecordingFile(failure: .write)
        let recording = RecordingActor(
            recordingFolder: FileManager.default.temporaryDirectory,
            fileFactory: InjectedRecordingFileFactory(file: file)
        )
        await recording.prepareForNewSession()
        await recording.enqueueFragment(Fragment(
            sequence: 0,
            segment: Data("init".utf8),
            duration: 0,
            type: .initialization
        ))

        do {
            try await recording.finish()
            Issue.record("Expected the injected write error to fail finalization")
        } catch let error as RecordingError {
            guard case .writeFailed(sequence: 0, _) = error else {
                Issue.record("Unexpected recording error: \(error)")
                return
            }
        }
    }

    @Test(arguments: [
        InjectedRecordingIOError.synchronize,
        InjectedRecordingIOError.close,
    ])
    func finalDurabilityFailureIsReported(_ failure: InjectedRecordingIOError) async throws {
        let file = InjectedRecordingFile(failure: failure)
        let recording = RecordingActor(
            recordingFolder: FileManager.default.temporaryDirectory,
            fileFactory: InjectedRecordingFileFactory(file: file)
        )
        await recording.prepareForNewSession()
        await recording.enqueueFragment(Fragment(
            sequence: 0,
            segment: Data("init".utf8),
            duration: 0,
            type: .initialization
        ))

        await #expect(throws: RecordingError.self) {
            try await recording.finish()
        }
    }

    @Test func slowStorageAppliesBackpressureToFragmentDelivery() async throws {
        let delay: TimeInterval = 0.05
        let file = InjectedRecordingFile(writeDelay: delay)
        let recording = RecordingActor(
            recordingFolder: FileManager.default.temporaryDirectory,
            fileFactory: InjectedRecordingFileFactory(file: file)
        )
        await recording.prepareForNewSession()
        let clock = ContinuousClock()
        let start = clock.now
        await recording.enqueueFragment(Fragment(
            sequence: 0,
            segment: Data("init".utf8),
            duration: 0,
            type: .initialization
        ))

        #expect(start.duration(to: clock.now) >= .milliseconds(40))
        try await recording.finish()
        #expect(file.data == Data("init".utf8))
    }

    @Test func durabilitySyncOccursOnceAtTheFinalBarrier() async throws {
        let file = InjectedRecordingFile()
        let recording = RecordingActor(
            recordingFolder: FileManager.default.temporaryDirectory,
            fileFactory: InjectedRecordingFileFactory(file: file)
        )
        await recording.prepareForNewSession()
        for sequence in 0..<20 {
            await recording.enqueueFragment(Fragment(
                sequence: sequence,
                segment: Data("fragment-\(sequence)".utf8),
                duration: sequence == 0 ? 0 : 2,
                type: sequence == 0 ? .initialization : .separable
            ))
            #expect(file.synchronizeCount == 0)
        }

        try await recording.finish()
        #expect(file.synchronizeCount == 1)
        #expect(file.closeCount == 1)
    }
}
