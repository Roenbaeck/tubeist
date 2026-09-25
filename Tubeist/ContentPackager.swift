//
//  ContentPackager.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

// @preconcurrency needed to pass CMSampleBuffer around
import AVFoundation

enum MediaType {
    case audio
    case video
}

private final class OneShotBoolContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Bool) {
        let continuation = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.resume(returning: value)
    }
}


enum RecordingError: LocalizedError, Equatable {
    case folderUnavailable
    case missingInitialization
    case createFailed(String)
    case writeFailed(sequence: Int, message: String)
    case finalizeFailed(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable:
            "The local recording folder is unavailable"
        case .missingInitialization:
            "The local recording did not receive an initialization fragment"
        case .createFailed(let message):
            "Could not create the local recording: \(message)"
        case .writeFailed(let sequence, let message):
            "Could not write recording fragment \(sequence): \(message)"
        case .finalizeFailed(let message):
            "Could not finalize the local recording: \(message)"
        }
    }
}

protocol RecordingFileWriting: Sendable {
    func write(_ data: Data) throws
    func synchronize() throws
    func close() throws
}

protocol RecordingFileCreating: Sendable {
    func createFile(at url: URL) throws -> any RecordingFileWriting
}

struct SystemRecordingFileFactory: RecordingFileCreating {
    func createFile(at url: URL) throws -> any RecordingFileWriting {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        ) else {
            throw RecordingError.createFailed("The file could not be created")
        }
        return SystemRecordingFile(handle: try FileHandle(forWritingTo: url))
    }
}

private final class SystemRecordingFile: RecordingFileWriting, @unchecked Sendable {
    private var handle: FileHandle?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        guard let handle else {
            throw CocoaError(.fileNoSuchFile)
        }
        try handle.write(contentsOf: data)
    }

    func synchronize() throws {
        try handle?.synchronize()
    }

    func close() throws {
        try handle?.close()
        handle = nil
    }

    deinit {
        try? handle?.close()
    }
}

actor RecordingActor {
    private var filename: String?
    private var fileURL: URL?
    private var file: (any RecordingFileWriting)?
    private let recordingFolder: URL?
    private let fileFactory: any RecordingFileCreating
    private var prepared = false
    private var sawInitialization = false
    private var closed = true
    private var failure: RecordingError?
    private var fileFailure = RecordingFileFailure()

    init(
        recordingFolder: URL? = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first,
        fileFactory: any RecordingFileCreating = SystemRecordingFileFactory()
    ) {
        self.recordingFolder = recordingFolder
        self.fileFactory = fileFactory
        if recordingFolder == nil {
            LOG("Could not access directory where fragments are stored", level: .error)
        }
    }

    func prepareForNewSession(fileFailure: RecordingFileFailure = RecordingFileFailure()) {
        try? file?.close()
        filename = nil
        fileURL = nil
        file = nil
        prepared = true
        sawInitialization = false
        closed = false
        failure = nil
        self.fileFailure = fileFailure
    }

    func enqueueFragment(_ fragment: Fragment) {
        guard prepared, failure == nil else {
            return
        }
        do {
            try writeFragment(fragment)
        } catch let recordingError as RecordingError {
            stopAfterFileFailure(recordingError)
        } catch {
            let recordingError = RecordingError.writeFailed(
                sequence: fragment.sequence,
                message: error.localizedDescription
            )
            stopAfterFileFailure(recordingError)
        }
    }

    private func stopAfterFileFailure(_ error: RecordingError) {
        failure = error
        fileFailure.report(error.localizedDescription)
        // Preserve the existing file, but release its handle immediately.
        try? file?.close()
        file = nil
        closed = true
        LOG(error.localizedDescription, level: .error)
    }

    func finish() throws {
        guard prepared else {
            return
        }
        defer { prepared = false }
        if let failure {
            try? file?.close()
            file = nil
            closed = true
            throw failure
        }
        guard sawInitialization else {
            closed = true
            throw RecordingError.missingInitialization
        }
        if !closed {
            try finalizeFile()
        }
    }

    func recordingURL() -> URL? {
        fileURL
    }

    private func writeFragment(_ fragment: Fragment) throws {
        if fragment.type == .initialization {
            LOG("Starting recording", level: .debug)
            try openRecording()
            sawInitialization = true
        }
        guard let file else {
            throw RecordingError.missingInitialization
        }
        do {
            try file.write(fragment.segment)
            LOG("Appended fragment \(fragment.sequence) to file: \(filename ?? "<none>")", level: .debug)
        } catch {
            throw RecordingError.writeFailed(
                sequence: fragment.sequence,
                message: error.localizedDescription
            )
        }
    }

    private func openRecording() throws {
        guard let recordingFolder else {
            throw RecordingError.folderUnavailable
        }
        let filename = "recording_\(HLSMediaPlaylist.makeSessionIdentifier()).mp4"
        self.filename = filename
        let fileURL = recordingFolder.appendingPathComponent(filename)
        self.fileURL = fileURL
        do {
            file = try fileFactory.createFile(at: fileURL)
        } catch let error as RecordingError {
            file = nil
            throw error
        } catch {
            file = nil
            throw RecordingError.createFailed(error.localizedDescription)
        }
    }

    private func finalizeFile() throws {
        guard let file else {
            if closed { return }
            throw RecordingError.finalizeFailed("The recording file is not open")
        }
        do {
            try file.synchronize()
            try file.close()
            self.file = nil
            closed = true
        } catch {
            throw RecordingError.finalizeFailed(error.localizedDescription)
        }
    }

    deinit {
        try? file?.close()
    }
}

actor OrderedFragmentDispatcher {
    private var pending: [Int: Fragment] = [:]
    private var nextExpectedSequence = 0
    private var streams = false
    private var records = false
    private var isDispatching = false
    private var generation: UInt64 = 0

    func prepare(stream: Bool, record: Bool) {
        generation &+= 1
        isDispatching = false
        pending.removeAll(keepingCapacity: true)
        nextExpectedSequence = 0
        streams = stream
        records = record
    }

    func enqueue(_ fragment: Fragment, recording: RecordingActor) async {
        pending[fragment.sequence] = fragment
        guard !isDispatching else { return }
        isDispatching = true
        let activeGeneration = generation
        defer { if activeGeneration == generation { isDispatching = false } }
        while activeGeneration == generation,
              let next = pending.removeValue(forKey: nextExpectedSequence) {
            nextExpectedSequence += 1
            if streams {
                await EncodedOutputRouter.shared.route(next)
            }
            if records {
                await recording.enqueueFragment(next)
            }
        }
    }

    func finish() throws {
        guard pending.isEmpty else {
            throw ContentPackagingError.fragmentSequenceGap(
                expected: nextExpectedSequence,
                pending: pending.keys.sorted()
            )
        }
    }
}

/// Cancelling a writer does not retract callbacks already queued by its
/// delegate. Ignore those callbacks after another recording has been prepared.
final class RecordingCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var writerID: ObjectIdentifier?
    private var generation: UInt64 = 0
    private var sequence = 0

    func prepare(writerID: ObjectIdentifier?) {
        lock.withLock {
            self.writerID = writerID
            generation &+= 1
            sequence = 0
        }
    }

    func next(writerID: ObjectIdentifier) -> (sequence: Int, generation: UInt64)? {
        lock.withLock {
            guard self.writerID == writerID else { return nil }
            defer { sequence += 1 }
            return (sequence, generation)
        }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { self.generation == generation }
    }
}

final class ContentPackager: NSObject, AVAssetWriterDelegate, Sendable {
    @PipelineActor public static let shared = ContentPackager()
    private static let assetWriterFinalizationFlag = AssetWriterFinalizationFlag()
    @PipelineActor private static let pipeline = LiveEncodingPipeline()
    private let recordingCallbacks = RecordingCallbackState()
    private let recording = RecordingActor()
    private let fragmentDispatcher = OrderedFragmentDispatcher()
    private let fragmentDispatchGroup = DispatchGroup()

    func isPackaging() async -> Bool {
        await Self.pipeline.isActive
    }

    func captureState() async -> CaptureLiveness.State? {
        await Self.pipeline.captureState
    }

    func beginFinalization() async {
        await Self.pipeline.beginFinalization()
    }

    func beginPackaging(stream: Bool, record: Bool, serviceName: String) async throws {
        guard await !Self.pipeline.isActive else { throw ContentPackagingError.alreadyEncoding }
        recordingCallbacks.prepare(writerID: nil)
        await fragmentDispatcher.prepare(stream: false, record: record)
        let recordingWriter = try await makeRecordingWriter(enabled: record)
        if let recordingWriter {
            await recording.prepareForNewSession(fileFailure: recordingWriter.fileFailure)
        }
        try await Self.pipeline.start(preset: Settings.selectedPreset, stream: stream,
                                      recording: recordingWriter,
                                      allows422: Settings.prefers422Chroma, serviceName: serviceName)
        LOG("VideoToolbox and AAC encoders are now accepting sample buffers", level: .debug)
    }

    @PipelineActor
    private func makeRecordingWriter(enabled: Bool) throws -> RecordingAssetWriter? {
        guard enabled else { return nil }
        let writer = try RecordingAssetWriter(delegate: self, finalizationFlag: Self.assetWriterFinalizationFlag)
        recordingCallbacks.prepare(writerID: writer.identifier)
        return writer
    }

    func endPackaging(
        deadline requestedDeadline: ContinuousClock.Instant? = nil
    ) async throws -> ContentPackagingShutdownReport {
        let clock = ContinuousClock()
        let deadline = requestedDeadline ?? clock.now.advanced(by: .seconds(10))
        let shouldRecord = await Self.pipeline.isRecording
        let writerWasPrepared = await Self.pipeline.isActive
        var writerStatus: ShutdownComponentStatus = writerWasPrepared ? .completed : .notRequested
        var dispatchStatus: ShutdownComponentStatus = writerWasPrepared ? .completed : .notRequested
        var recordingStatus: ShutdownComponentStatus = shouldRecord ? .completed : .notRequested
        if writerWasPrepared {
            do {
                try await Self.pipeline.finish(deadline: deadline)
            } catch {
                writerStatus = .failed(error.localizedDescription)
            }
            if await waitForFragmentDispatch(deadline: deadline) {
                do {
                    try await fragmentDispatcher.finish()
                } catch {
                    dispatchStatus = .failed(error.localizedDescription)
                }
            } else {
                dispatchStatus = .failed("Fragment delivery did not finish before the shutdown deadline")
            }
        } else {
            LOG("Media encoders had already stopped accepting sample buffers", level: .debug)
        }
        if shouldRecord {
            if dispatchStatus.failedMessage == nil, clock.now < deadline {
                do {
                    try await recording.finish()
                    if clock.now >= deadline {
                        recordingStatus = .failed("Recording finalization exceeded the shutdown deadline")
                    }
                } catch {
                    recordingStatus = .failed(error.localizedDescription)
                }
            } else {
                recordingStatus = .failed("Recording could not finalize before the shutdown deadline")
            }
            // The file keeps what was written before the recording stopped
            // mid-session; streaming continued without it.
            if let failure = await Self.pipeline.recordingFailure {
                recordingStatus = .failed("Stopped during the session: \(failure)")
            }
        }
        LOG("Media encoders are no longer accepting sample buffers", level: .debug)
        let report = ContentPackagingShutdownReport(
            mediaEncoding: writerStatus,
            fragmentDispatch: dispatchStatus,
            recording: recordingStatus
        )
        if !report.succeeded {
            throw ContentPackagingShutdownError(report: report)
        }
        return report
    }

    private func waitForFragmentDispatch(
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let oneShot = OneShotBoolContinuation(continuation)
            let remaining = max(.zero, ContinuousClock().now.duration(to: deadline))
            let timeoutTask = Task.detached(priority: .userInitiated) {
                do {
                    try await Task.sleep(for: remaining)
                } catch {
                    return
                }
                oneShot.resume(returning: false)
            }
            fragmentDispatchGroup.notify(queue: .global(qos: .userInitiated)) {
                timeoutTask.cancel()
                oneShot.resume(returning: true)
            }
        }
    }
    
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async throws {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer
        try await Self.pipeline.appendVideo(sendableSampleBuffer)
    }
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async throws {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer
        try await Self.pipeline.appendAudio(sendableSampleBuffer)
    }
    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        guard let callback = recordingCallbacks.next(writerID: ObjectIdentifier(writer)) else { return }
        let sequenceNumber = callback.sequence
        let isFinalizing = Self.assetWriterFinalizationFlag.read()
        fragmentDispatchGroup.enter()
        Task { @PipelineActor in
            defer { self.fragmentDispatchGroup.leave() }
            guard self.recordingCallbacks.isCurrent(callback.generation) else { return }
            guard let fragmentType: Fragment.SegmentType = {
                switch (segmentType, isFinalizing) {
                case (.separable, false): .separable
                case (.initialization, _): .initialization
                case (.separable, true): .finalization
                @unknown default: nil
                }
            }() else {
                LOG("Unknown segment type", level: .error)
                return
            }
            let duration = segmentReport?.trackReports.first?.duration.seconds ?? 0
            let fragment = Fragment(sequence: sequenceNumber, segment: segmentData, duration: duration, type: fragmentType)
            LOG("Produced \(fragment)", level: .debug)

#if DEBUG
            await FMP4FixtureCapture.shared.capture(fragment)
#endif
            
            guard self.recordingCallbacks.isCurrent(callback.generation) else { return }
            await fragmentDispatcher.enqueue(fragment, recording: recording)
        }
    }
}

enum ContentPackagingError: LocalizedError {
    case alreadyEncoding
    case videoNeverStarted
    case fragmentSequenceGap(expected: Int, pending: [Int])

    var errorDescription: String? {
        switch self {
        case .alreadyEncoding:
            "The HEVC/AAC encoders are already running"
        case .videoNeverStarted:
            "The stream produced no video frames"
        case .fragmentSequenceGap(let expected, let pending):
            "Encoded fragment ordering stopped at \(expected); pending fragments: \(pending)"
        }
    }
}
