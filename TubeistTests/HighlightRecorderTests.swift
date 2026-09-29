//
//  HighlightRecorderTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

private final class InjectedHighlightFile: RecordingFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()
    var data: Data { lock.withLock { storedData } }

    func write(_ data: Data) throws {
        lock.withLock { storedData.append(data) }
    }
    func synchronize() throws {}
    func close() throws {}
}

private final class InjectedHighlightFileFactory: RecordingFileCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFiles: [URL: InjectedHighlightFile] = [:]
    var files: [URL: InjectedHighlightFile] { lock.withLock { storedFiles } }

    func createFile(at url: URL) throws -> any RecordingFileWriting {
        let file = InjectedHighlightFile()
        lock.withLock { storedFiles[url] = file }
        return file
    }
}

private func fragment(_ sequence: Int, _ text: String, duration: Double, type: Fragment.SegmentType = .separable) -> Fragment {
    Fragment(sequence: sequence, segment: Data(text.utf8), duration: duration, type: type)
}

private extension HighlightEvent {
    /// nil for .requested, which the tests don't care about.
    var terminalOutcome: Result<URL, HighlightError>? {
        switch self {
        case .requested: nil
        case .saved(let url): .success(url)
        case .failed(let error): .failure(error)
        }
    }
}

struct HighlightRecorderTests {
    private func makeRecorder(_ factory: InjectedHighlightFileFactory) async -> HighlightRecorder {
        await HighlightRecorder(
            folder: FileManager.default.temporaryDirectory,
            fileFactory: factory
        )
    }

    @Test func assemblesInitializationBeforeAndAfterFragments() async throws {
        let factory = InjectedHighlightFileFactory()
        let recorder = await makeRecorder(factory)
        await recorder.prepareForNewSession()

        await recorder.observe(fragment(0, "init", duration: 0, type: .initialization))
        await recorder.observe(fragment(1, "before1", duration: 2))
        await recorder.observe(fragment(2, "before2", duration: 2))

        let result = await withCheckedContinuation { continuation in
            Task {
                await recorder.setOnEvent { event in
                    guard let outcome = event.terminalOutcome else { return }
                    continuation.resume(returning: outcome)
                }
                await recorder.requestHighlight()
                // Two 2 s fragments (4 s) is not yet the 5 s minimum "after" window.
                await recorder.observe(fragment(3, "after1", duration: 2))
                await recorder.observe(fragment(4, "after2", duration: 2))
                await recorder.observe(fragment(5, "after3", duration: 2))
            }
        }

        let url = try result.get()
        let file = try #require(factory.files[url])
        #expect(file.data == Data("initbefore1before2after1after2after3".utf8))
    }

    @Test func ringBufferDropsFragmentsOlderThanItsCapacity() async throws {
        let factory = InjectedHighlightFileFactory()
        let recorder = await makeRecorder(factory)
        await recorder.prepareForNewSession()
        await recorder.observe(fragment(0, "init", duration: 0, type: .initialization))
        for sequence in 1...10 {
            await recorder.observe(fragment(sequence, "f\(sequence)", duration: 2))
        }

        let result = await withCheckedContinuation { continuation in
            Task {
                await recorder.setOnEvent { event in
                    guard let outcome = event.terminalOutcome else { return }
                    continuation.resume(returning: outcome)
                }
                await recorder.requestHighlight()
                await recorder.observe(fragment(11, "after1", duration: 2))
                await recorder.observe(fragment(12, "after2", duration: 2))
                await recorder.observe(fragment(13, "after3", duration: 2))
            }
        }

        let url = try result.get()
        let file = try #require(factory.files[url])
        // Only the most recent 7 fragments (f4...f10) survive in the ring.
        #expect(file.data == Data("initf4f5f6f7f8f9f10after1after2after3".utf8))
    }

    @Test func missingInitializationFragmentFails() async throws {
        let factory = InjectedHighlightFileFactory()
        let recorder = await makeRecorder(factory)
        await recorder.prepareForNewSession()
        await recorder.observe(fragment(0, "before", duration: 2))

        let result = await withCheckedContinuation { continuation in
            Task {
                await recorder.setOnEvent { event in
                    guard let outcome = event.terminalOutcome else { return }
                    continuation.resume(returning: outcome)
                }
                await recorder.requestHighlight()
                for sequence in 1...3 {
                    await recorder.observe(fragment(sequence, "after\(sequence)", duration: 2))
                }
            }
        }

        #expect(throws: HighlightError.missingInitialization) {
            try result.get()
        }
    }

    @Test func flushPendingAssemblesWhateverArrivedBeforeShutdown() async throws {
        let factory = InjectedHighlightFileFactory()
        let recorder = await makeRecorder(factory)
        await recorder.prepareForNewSession()
        await recorder.observe(fragment(0, "init", duration: 0, type: .initialization))
        await recorder.observe(fragment(1, "before1", duration: 2))
        await recorder.requestHighlight()
        // Only 2 s of "after" — below the 5 s minimum — before the stream ends.
        await recorder.observe(fragment(2, "after1", duration: 2))

        let result = await withCheckedContinuation { continuation in
            Task {
                await recorder.setOnEvent { event in
                    guard let outcome = event.terminalOutcome else { return }
                    continuation.resume(returning: outcome)
                }
                await recorder.flushPending()
            }
        }

        let url = try result.get()
        let file = try #require(factory.files[url])
        #expect(file.data == Data("initbefore1after1".utf8))
    }

    @Test func prepareForNewSessionClearsBufferedAndPendingState() async throws {
        let factory = InjectedHighlightFileFactory()
        let recorder = await makeRecorder(factory)
        await recorder.prepareForNewSession()
        await recorder.observe(fragment(0, "init", duration: 0, type: .initialization))
        await recorder.observe(fragment(1, "stale", duration: 2))
        await recorder.requestHighlight()

        await recorder.prepareForNewSession()
        await recorder.observe(fragment(0, "init2", duration: 0, type: .initialization))
        await recorder.observe(fragment(1, "fresh1", duration: 2))
        await recorder.requestHighlight()
        await recorder.observe(fragment(2, "after1", duration: 2))
        await recorder.observe(fragment(3, "after2", duration: 2))
        await recorder.observe(fragment(4, "after3", duration: 2))

        // The stale pre-reset highlight must never complete once fresh fragments
        // push its "after" duration past the minimum, since prepareForNewSession
        // should have discarded it entirely.
        #expect(factory.files.count <= 1)
    }
}
