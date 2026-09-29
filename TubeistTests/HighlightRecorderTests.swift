// Adapted from Jan Lindhardsen's highlight tests for the current pipeline.
import Foundation
import Testing
@testable import Tubeist

private final class InjectedHighlightFile: RecordingFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()
    var data: Data { lock.withLock { storedData } }
    func write(_ data: Data) throws { lock.withLock { storedData.append(data) } }
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

private final class BlockedHighlightFile: RecordingFileWriting, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    var isWriting: Bool { lock.withLock { entered } }
    func write(_ data: Data) throws {
        let first = lock.withLock {
            let first = !entered
            entered = true
            return first
        }
        if first { _ = release.wait(timeout: .now() + 5) }
    }
    func synchronize() throws {}
    func close() throws {}
}

private struct BlockedHighlightFactory: RecordingFileCreating {
    let file: BlockedHighlightFile
    func createFile(at url: URL) throws -> any RecordingFileWriting { file }
}

private struct FailedHighlightFactory: RecordingFileCreating {
    func createFile(at url: URL) throws -> any RecordingFileWriting { throw CocoaError(.fileWriteNoPermission) }
}

private final class HighlightEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HighlightEvent] = []
    func append(_ event: HighlightEvent) { lock.withLock { events.append(event) } }
    var last: HighlightEvent? { lock.withLock { events.last } }
}

private func highlightFragment(_ sequence: Int, _ text: String, duration: Double = 2,
                               type: Fragment.SegmentType = .separable) -> Fragment {
    Fragment(sequence: sequence, segment: Data(text.utf8), duration: duration, type: type)
}

@PipelineActor
struct HighlightRecorderTests {
    private func makeRecorder(_ factory: InjectedHighlightFileFactory) -> HighlightRecorder {
        HighlightRecorder(folder: FileManager.default.temporaryDirectory, fileFactory: factory, normalize: false)
    }
    private func initialize(_ recorder: HighlightRecorder, sessionID: UUID = UUID()) {
        recorder.prepareForNewSession(sessionID: sessionID)
        recorder.observe(highlightFragment(0, "init", duration: 0, type: .initialization))
    }

    @Test func assemblesInitializationBeforeAndAfterFragments() async throws {
        let factory = InjectedHighlightFileFactory()
        let recorder = makeRecorder(factory)
        initialize(recorder)
        recorder.observe(highlightFragment(1, "before1"))
        recorder.observe(highlightFragment(2, "before2"))
        try recorder.requestHighlight()
        recorder.observe(highlightFragment(3, "after1"))
        recorder.observe(highlightFragment(4, "after2"))
        #expect(factory.files.isEmpty)
        recorder.observe(highlightFragment(5, "after3"))
        await recorder.flushPending()
        #expect(factory.files.count == 1)
        #expect(factory.files.values.first?.data == Data("initbefore1before2after1after2after3".utf8))
    }

    @Test func ringBufferKeepsAboutTenSecondsRatherThanTheWholeSession() async throws {
        let factory = InjectedHighlightFileFactory()
        let recorder = makeRecorder(factory)
        initialize(recorder)
        for i in 1...10 { recorder.observe(highlightFragment(i, "f\(i)")) }
        try recorder.requestHighlight()
        for i in 11...13 { recorder.observe(highlightFragment(i, "f\(i)")) }
        await recorder.flushPending()
        #expect(factory.files.values.first?.data == Data("initf6f7f8f9f10f11f12f13".utf8))
    }

    @Test func unavailableFootageAndDuplicatePressesAreRejected() async throws {
        let factory = InjectedHighlightFileFactory()
        let recorder = makeRecorder(factory)
        recorder.prepareForNewSession()
        #expect(throws: HighlightError.missingInitialization) { try recorder.requestHighlight() }
        initialize(recorder)
        recorder.observe(highlightFragment(1, "before"))
        try recorder.requestHighlight()
        #expect(throws: HighlightError.busy) { try recorder.requestHighlight() }
        await recorder.flushPending()
        #expect(factory.files.count == 1)
        #expect(throws: HighlightError.unavailable) { try recorder.requestHighlight() }
    }

    @Test func flushPendingAssemblesWhateverArrivedBeforeShutdown() async throws {
        let factory = InjectedHighlightFileFactory()
        let recorder = makeRecorder(factory)
        initialize(recorder)
        recorder.observe(highlightFragment(1, "before1"))
        try recorder.requestHighlight()
        recorder.observe(highlightFragment(2, "after1"))
        await recorder.flushPending()
        #expect(factory.files.values.first?.data == Data("initbefore1after1".utf8))
    }

    @Test func oldActivityCannotRequestAHighlightFromANewSession() async throws {
        let factory = InjectedHighlightFileFactory()
        let recorder = makeRecorder(factory)
        let old = UUID()
        initialize(recorder, sessionID: old)
        recorder.observe(highlightFragment(1, "stale"))
        try recorder.requestHighlight(sessionID: old)
        let new = UUID()
        initialize(recorder, sessionID: new)
        recorder.observe(highlightFragment(1, "fresh"))
        #expect(throws: HighlightError.unavailable) { try recorder.requestHighlight(sessionID: old) }
        try recorder.requestHighlight(sessionID: new)
        await recorder.flushPending()
        #expect(factory.files.count == 1)
        #expect(factory.files.values.first?.data == Data("initfresh".utf8))
    }

    @Test func rapidSavesUseDifferentFilenames() async throws {
        let factory = InjectedHighlightFileFactory()
        let recorder = makeRecorder(factory)
        for _ in 0..<2 {
            initialize(recorder)
            recorder.observe(highlightFragment(1, "before"))
            try recorder.requestHighlight()
            await recorder.flushPending()
        }
        #expect(factory.files.count == 2)
    }

    @Test func slowSavingDoesNotBlockShutdownOrNextSessionAndCannotQueueMoreClips() async throws {
        let file = BlockedHighlightFile()
        defer { file.release.signal() }
        let recorder = HighlightRecorder(folder: FileManager.default.temporaryDirectory,
                                         fileFactory: BlockedHighlightFactory(file: file), normalize: false)
        initialize(recorder)
        recorder.observe(highlightFragment(1, "before"))
        try recorder.requestHighlight()
        for i in 2...4 { recorder.observe(highlightFragment(i, "after")) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !file.isWriting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(file.isWriting)
        await recorder.flushPending(waitForWrites: false)
        #expect(file.isWriting)
        initialize(recorder)
        recorder.observe(highlightFragment(1, "next session"))
        #expect(throws: HighlightError.busy) { try recorder.requestHighlight() }
        file.release.signal()
        await recorder.flushPending()
    }

    @Test func aFileFailureReportsFailedRatherThanSaved() async throws {
        let recorder = HighlightRecorder(folder: FileManager.default.temporaryDirectory,
                                         fileFactory: FailedHighlightFactory(), normalize: false)
        let events = HighlightEvents()
        recorder.setOnEvent { _, event in events.append(event) }
        initialize(recorder)
        recorder.observe(highlightFragment(1, "before"))
        try recorder.requestHighlight()
        await recorder.flushPending()
        guard case .failed(.writeFailed) = events.last else {
            Issue.record("A file creation failure must produce failed feedback")
            return
        }
    }
}

struct HighlightClipAssemblerTests {
    @Test func shiftsBothTracksTogetherAndPreservesCompressedSamples() throws {
        let reader = ISOBMFFReader()
        let initData = FMP4Fixture.initialization()
        let metadata = try reader.parseInitializationSegment(initData)
        let first = FMP4Fixture.mediaSegment(videoDecodeTime: 900_000, audioDecodeTime: 480_120)
        let next = FMP4Fixture.mediaSegment(videoDecodeTime: 1_080_000, audioDecodeTime: 576_120)
        let clip = try HighlightClipAssembler(initialization: initData, first: first)
        let original = try reader.parseMediaSegment(first, initialization: metadata).samples
        let shifted = try reader.parseMediaSegment(clip.normalize(first, fileOffset: initData.count), initialization: metadata).samples
        #expect(shifted.map(\.data) == original.map(\.data))
        #expect(shifted.map(\.duration) == original.map(\.duration))
        #expect(shifted.map(\.isRandomAccess) == original.map(\.isRandomAccess))
        #expect(shifted.allSatisfy { $0.presentationTime >= 0 && $0.decodeTime < 1_024 })
        let later = try reader.parseMediaSegment(clip.normalize(next, fileOffset: initData.count + first.count), initialization: metadata).samples
        #expect(later[0].decodeTime - shifted[0].decodeTime == 180_000)
        #expect(later[1].decodeTime - shifted[1].decodeTime == 96_000)
        let beforeDelta = Double(original[1].presentationTime) / 48_000 - Double(original[0].presentationTime) / 90_000
        let afterDelta = Double(shifted[1].presentationTime) / 48_000 - Double(shifted[0].presentationTime) / 90_000
        #expect(abs(beforeDelta - afterDelta) <= 1.0 / 48_000)
    }

    @Test func rejectsAClipWithoutALeadingKeyframeAndTruncatedFields() throws {
        #expect(throws: ISOBMFFError.self) {
            try HighlightClipAssembler(initialization: FMP4Fixture.initialization(),
                first: FMP4Fixture.mediaSegment(videoIsRandomAccess: false))
        }
        let clip = try HighlightClipAssembler(initialization: FMP4Fixture.initialization(), first: FMP4Fixture.mediaSegment())
        #expect(throws: ISOBMFFError.self) { try clip.normalize(Data([0, 0, 0, 8]), fileOffset: 0) }
    }
}
