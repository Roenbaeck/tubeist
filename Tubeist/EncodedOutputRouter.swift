//
//  EncodedOutputRouter.swift
//  Tubeist
//

import Foundation

enum YouTubeHLSPackagingError: LocalizedError, CustomStringConvertible {
    case notPrepared
    case initializationMissing
    case segmentDurationMismatch(reported: Double, parsed: Double)
    case packagingFailed
    case shutdownTimedOut

    var description: String {
        switch self {
        case .notPrepared: "YouTube HLS output was not prepared"
        case .initializationMissing: "A media fragment arrived before its initialization segment"
        case .segmentDurationMismatch(let reported, let parsed):
            "Fragment duration mismatch (writer \(reported)s, parsed \(parsed)s)"
        case .packagingFailed: "YouTube HLS packaging failed before shutdown completed"
        case .shutdownTimedOut: "YouTube HLS output did not drain before its shutdown deadline"
        }
    }

    var errorDescription: String? { description }
}

struct YouTubeHLSPackagingMetrics: Sendable, Equatable {
    let networkMbps: Int
    let networkUtilization: Int
    let queuedFragments: Int
    let queuedDuration: Double
    let lastAcceptedMediaSequence: Int?
    let droppedFragments: Int
    let failure: String?
}

struct EncodedOutputMetrics: Sendable, Equatable {
    let networkMbps: Int
    let networkUtilization: Int
    let bufferedFragments: Int
    let queuedDuration: Double
    let hasFailure: Bool
}

actor YouTubeHLSStreamSink {
    static let shared = YouTubeHLSStreamSink()

    // This is the local fMP4 jitter queue, not YouTube's limit of five
    // outstanding playlist entries. With two-second writer fragments, thirty
    // entries absorb at least sixty seconds of a temporary network stall while
    // keeping worst-case high-bitrate 4K memory use bounded near 120 MB.
    static let maximumQueuedFragments = 30
    private let reader = ISOBMFFReader()
    private var initialization: ISOBMFFInitialization?
    private var muxer = MPEGTransportStreamMuxer()
    private var uploader: YouTubeHLSUploader?
    private var queue: [Fragment] = []
    private var isProcessing = false
    private var currentFragmentType: Fragment.SegmentType?
    private var isUploadingFinalization = false
    private var isPrepared = false
    private var currentDuration = 0.0
    private var pendingDiscontinuity = false
    private var finalizationSamples: [ISOBMFFSample] = []
    private var finalizationSequenceNumber: UInt32?
    private var finalizationFragmentCount = 0
    private var finalizationReportedDuration = 0.0
    private var finalizationDiscontinuity = false
    private var droppedFragments = 0
    private var lastAcceptedMediaSequence: Int?
    private var failure: String?
    private var sessionGeneration: UInt64 = 0

    func prepare(
        endpoint: YouTubeHLSEndpoint,
        sessionIdentifier: String,
        userAgent: String,
        transport: (any YouTubeHLSHTTPTransport)? = nil
    ) async throws {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        let previousUploader = uploader
        uploader = nil
        isPrepared = false
        initialization = nil
        muxer.reset()
        queue.removeAll(keepingCapacity: true)
        isProcessing = false
        currentFragmentType = nil
        isUploadingFinalization = false
        currentDuration = 0
        pendingDiscontinuity = false
        clearFinalizationBuffer()
        droppedFragments = 0
        lastAcceptedMediaSequence = nil
        failure = nil
        if let previousUploader {
            await previousUploader.stop()
        }
        guard generation == sessionGeneration else {
            throw YouTubeHLSPackagingError.notPrepared
        }
        if let transport {
            uploader = try YouTubeHLSUploader(
                endpoint: endpoint,
                sessionIdentifier: sessionIdentifier,
                userAgent: userAgent,
                transport: transport
            )
        } else {
            uploader = try YouTubeHLSUploader(
                endpoint: endpoint,
                sessionIdentifier: sessionIdentifier,
                userAgent: userAgent
            )
        }
        isPrepared = true
#if DEBUG
        await HLSAcceptanceRecorder.shared.begin(
            sessionIdentifier: sessionIdentifier,
            enabled: Settings.recordHLSAcceptance
        )
#endif
        LOG("YouTube HLS output is prepared", level: .info)
    }

    func enqueue(_ fragment: Fragment) async {
        guard isPrepared, failure == nil else {
            LOG("Ignoring an encoded fragment because YouTube HLS output is unavailable", level: .warning)
            return
        }
        if queue.count >= Self.maximumQueuedFragments {
            if let dropIndex = queue.firstIndex(where: { $0.type != .initialization }) {
                let dropped = queue.remove(at: dropIndex)
                droppedFragments += 1
                pendingDiscontinuity = true
#if DEBUG
                await HLSAcceptanceRecorder.shared.segmentDropped(
                    sequence: dropped.sequence,
                    droppedFragments: droppedFragments
                )
#endif
                LOG("YouTube HLS queue dropped fragment \(dropped.sequence); the next segment will be discontinuous", level: .warning)
                await Streamer.shared.setStreamHealth(.degraded)
            }
        }
        queue.append(fragment)
        if !isProcessing {
            isProcessing = true
            let generation = sessionGeneration
            Task(priority: .utility) {
                await self.drainQueue(sessionGeneration: generation)
            }
        }
    }

    func finish(timeout: TimeInterval = 120) async throws {
        let clock = ContinuousClock()
        try await finish(deadline: clock.now.advanced(by: .seconds(timeout)))
    }

    func finish(deadline: ContinuousClock.Instant) async throws {
        let generation = sessionGeneration
        let clock = ContinuousClock()
        while generation == sessionGeneration,
              (isProcessing || !queue.isEmpty),
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard generation == sessionGeneration else {
            throw YouTubeHLSPackagingError.notPrepared
        }
        guard !isProcessing, queue.isEmpty else {
            await cancel()
            throw YouTubeHLSPackagingError.shutdownTimedOut
        }
        if !finalizationSamples.isEmpty {
            isProcessing = true
            Task(priority: .utility) {
                await self.drainFinalization(sessionGeneration: generation)
            }
            while generation == sessionGeneration,
                  isProcessing,
                  clock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard generation == sessionGeneration else {
                throw YouTubeHLSPackagingError.notPrepared
            }
            guard !isProcessing else {
                await cancel()
                throw YouTubeHLSPackagingError.shutdownTimedOut
            }
        }
        let finishingUploader = uploader
        uploader = nil
        isPrepared = false
        let finishingFailure = failure
        if let finishingUploader {
            if finishingFailure == nil {
                do {
                    try await finishingUploader.finish()
                } catch {
                    failure = String(describing: error)
                    LOG("YouTube final playlist publication failed: \(error)", level: .error)
                    throw YouTubeHLSPackagingError.packagingFailed
                }
            } else {
                await finishingUploader.stop()
            }
        }
        guard generation == sessionGeneration else {
            throw YouTubeHLSPackagingError.notPrepared
        }
        if finishingFailure != nil {
            // The detailed failure was already journaled without an ingestion
            // URL. Keep the public shutdown error stable and non-secret.
            throw YouTubeHLSPackagingError.packagingFailed
        }
#if DEBUG
        await HLSAcceptanceRecorder.shared.stopped()
#endif
        LOG("YouTube HLS output stopped", level: .info)
    }

    func cancel() async {
        sessionGeneration &+= 1
        let cancelledUploader = uploader
        uploader = nil
        queue.removeAll(keepingCapacity: true)
        isPrepared = false
        isProcessing = false
        currentFragmentType = nil
        isUploadingFinalization = false
        currentDuration = 0
        clearFinalizationBuffer()
        if let cancelledUploader {
            await cancelledUploader.stop()
        }
#if DEBUG
        await HLSAcceptanceRecorder.shared.cancelled()
#endif
    }

    func metrics() async -> YouTubeHLSPackagingMetrics {
        let uploadDuration = await uploader?.queuedDuration ?? 0
        let performance = await uploader?.performance ?? (0, 0)
        let queuedSeparableFragments = queue.lazy.filter { $0.type == .separable }.count
        let currentSeparableFragment = currentFragmentType == .separable ? 1 : 0
        let hasFinalizationSegment = isUploadingFinalization
            || currentFragmentType == .finalization
            || !finalizationSamples.isEmpty
            || queue.contains { $0.type == .finalization }
        return YouTubeHLSPackagingMetrics(
            networkMbps: performance.0,
            networkUtilization: performance.1,
            queuedFragments: queuedSeparableFragments
                + currentSeparableFragment
                + (hasFinalizationSegment ? 1 : 0),
            queuedDuration: queue.reduce(
                max(currentDuration, uploadDuration, finalizationReportedDuration)
            ) { $0 + $1.duration },
            lastAcceptedMediaSequence: lastAcceptedMediaSequence,
            droppedFragments: droppedFragments,
            failure: failure
        )
    }

    private func drainQueue(sessionGeneration generation: UInt64) async {
        while generation == sessionGeneration,
              isPrepared,
              failure == nil,
              !queue.isEmpty {
            let fragment = queue.removeFirst()
            currentFragmentType = fragment.type
            currentDuration = fragment.duration
            do {
                try await process(fragment, sessionGeneration: generation)
                guard generation == sessionGeneration else { return }
            } catch {
                await handleProcessingFailure(error, sessionGeneration: generation)
            }
            currentDuration = 0
            currentFragmentType = nil
        }
        if generation == sessionGeneration {
            isProcessing = false
        }
    }

    private func process(_ fragment: Fragment, sessionGeneration generation: UInt64) async throws {
        switch fragment.type {
        case .initialization:
            initialization = try reader.parseInitializationSegment(fragment.segment)
#if DEBUG
            await HLSAcceptanceRecorder.shared.initializationParsed()
#endif
            LOG("Parsed YouTube HLS initialization metadata", level: .debug)

        case .separable, .finalization:
            guard let initialization else {
                throw YouTubeHLSPackagingError.initializationMissing
            }
            let media = try reader.parseMediaSegment(fragment.segment, initialization: initialization)
            if fragment.type == .finalization {
                finalizationSamples.append(contentsOf: media.samples)
                if finalizationSequenceNumber == nil {
                    finalizationSequenceNumber = media.sequenceNumber
                }
                finalizationFragmentCount += 1
                finalizationReportedDuration = max(
                    finalizationReportedDuration,
                    fragment.duration
                )
                finalizationDiscontinuity = finalizationDiscontinuity || fragment.discontinuity
                return
            }
            try await upload(
                media,
                reportedDuration: fragment.duration,
                validateReportedDuration: true,
                discontinuity: fragment.discontinuity,
                sessionGeneration: generation
            )
        }
    }

    private func drainFinalization(sessionGeneration generation: UInt64) async {
        guard generation == sessionGeneration, isPrepared, failure == nil else {
            return
        }
        let samples = finalizationSamples
        let sequenceNumber = finalizationSequenceNumber
        let fragmentCount = finalizationFragmentCount
        let reportedDuration = finalizationReportedDuration
        let discontinuity = finalizationDiscontinuity
        isUploadingFinalization = true
        clearFinalizationBuffer()
        currentDuration = reportedDuration

        let hasVideo = samples.contains { $0.kind == .video }
        let hasAudio = samples.contains { $0.kind == .audio }
        if hasVideo, hasAudio {
            do {
                try await upload(
                    ISOBMFFMediaSegment(
                        sequenceNumber: sequenceNumber,
                        samples: samples
                    ),
                    reportedDuration: reportedDuration,
                    validateReportedDuration: false,
                    discontinuity: discontinuity,
                    sessionGeneration: generation
                )
                if fragmentCount > 1 {
                    LOG(
                        "Coalesced \(fragmentCount) final AVAssetWriter callbacks into one muxed audio/video segment",
                        level: .debug
                    )
                }
            } catch {
                await handleProcessingFailure(error, sessionGeneration: generation)
            }
        } else if !samples.isEmpty {
            let mediaKind = hasVideo ? "video" : "audio"
            LOG(
                "AVAssetWriter ended with an unmatched \(mediaKind)-only tail; all complete audio/video media was uploaded",
                level: .warning
            )
        }
        currentDuration = 0
        isUploadingFinalization = false
        if generation == sessionGeneration {
            isProcessing = false
        }
    }

    private func upload(
        _ media: ISOBMFFMediaSegment,
        reportedDuration: Double,
        validateReportedDuration: Bool,
        discontinuity: Bool,
        sessionGeneration generation: UInt64
    ) async throws {
        guard let initialization else {
            throw YouTubeHLSPackagingError.initializationMissing
        }
        guard let uploader else {
            throw YouTubeHLSPackagingError.notPrepared
        }
        let transportSegment = try muxer.mux(media, initialization: initialization)
        let duration = transportSegment.duration
        let tolerance = max(0.1, reportedDuration / 20)
        if validateReportedDuration,
           reportedDuration > 0,
           abs(reportedDuration - duration) > tolerance {
            throw YouTubeHLSPackagingError.segmentDurationMismatch(
                reported: reportedDuration,
                parsed: duration
            )
        }
        let receipt = try await uploader.upload(
            segment: transportSegment.data,
            duration: duration,
            discontinuity: discontinuity || pendingDiscontinuity
        )
        guard generation == sessionGeneration else { return }
        pendingDiscontinuity = false
        lastAcceptedMediaSequence = receipt.sequence
        let diagnostics = await uploader.diagnostics
        let queuedDuration = await uploader.queuedDuration
#if DEBUG
        await HLSAcceptanceRecorder.shared.segmentAccepted(
            sequence: receipt.sequence,
            duration: duration,
            queuedDuration: queuedDuration,
            retryCount: diagnostics.retryCount,
            httpStatus: diagnostics.lastHTTPStatus
        )
#endif
        let queuedDurationDescription = String(format: "%.2f", queuedDuration)
        let status = diagnostics.lastHTTPStatus.map(String.init) ?? "network"
        LOG(
            "YouTube direct accepted media sequence \(receipt.sequence); queued \(queuedDurationDescription)s; retries \(diagnostics.retryCount); HTTP \(status)",
            level: .debug
        )
    }

    private func handleProcessingFailure(
        _ error: Error,
        sessionGeneration generation: UInt64
    ) async {
        guard generation == sessionGeneration else { return }
        failure = String(describing: error)
        queue.removeAll(keepingCapacity: true)
        clearFinalizationBuffer()
#if DEBUG
        await HLSAcceptanceRecorder.shared.failed(String(describing: error))
#endif
        LOG("YouTube HLS packaging stopped: \(error)", level: .error)
        await Streamer.shared.setStreamHealth(.unusable)
        if let uploader {
            await uploader.stop()
        }
    }

    private func clearFinalizationBuffer() {
        finalizationSamples.removeAll(keepingCapacity: true)
        finalizationSequenceNumber = nil
        finalizationFragmentCount = 0
        finalizationReportedDuration = 0
        finalizationDiscontinuity = false
    }
}

actor EncodedOutputRouter {
    static let shared = EncodedOutputRouter()

    private enum Mode {
        case none
        case direct
    }

    private var mode: Mode = .none
    private var pendingFragments: [Int: Fragment] = [:]
    private var nextExpectedSequence = 0
    private var isRouting = false
    private var routingGeneration: UInt64 = 0

    func prepareForRecordingOnly() {
        resetOrdering()
        mode = .none
    }

    func prepareYouTube(
        endpoint: YouTubeHLSEndpoint,
        sessionIdentifier: String,
        userAgent: String
    ) async throws {
        resetOrdering()
        let generation = routingGeneration
        mode = .none
        try await YouTubeHLSStreamSink.shared.prepare(
            endpoint: endpoint,
            sessionIdentifier: sessionIdentifier,
            userAgent: userAgent
        )
        guard generation == routingGeneration else {
            throw YouTubeHLSPackagingError.notPrepared
        }
        mode = .direct
    }

    func route(_ fragment: Fragment) {
        pendingFragments[fragment.sequence] = fragment
        if !isRouting {
            isRouting = true
            let generation = routingGeneration
            Task(priority: .utility) {
                await self.drainOrderedFragments(routingGeneration: generation)
            }
        }
    }

    private func routeInCurrentMode(_ fragment: Fragment) async {
        switch mode {
        case .none:
            break
        case .direct:
            await YouTubeHLSStreamSink.shared.enqueue(fragment)
        }
    }

    func finish(timeout: TimeInterval = 120) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        try await finish(deadline: deadline)
    }

    func finish(deadline: ContinuousClock.Instant) async throws {
        let generation = routingGeneration
        let clock = ContinuousClock()
        while generation == routingGeneration,
              (isRouting || !pendingFragments.isEmpty),
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard generation == routingGeneration else {
            throw YouTubeHLSPackagingError.notPrepared
        }
        guard !isRouting, pendingFragments.isEmpty else {
            await cancel()
            throw YouTubeHLSPackagingError.shutdownTimedOut
        }
        switch mode {
        case .none:
            break
        case .direct:
            try await YouTubeHLSStreamSink.shared.finish(deadline: deadline)
        }
        if generation == routingGeneration {
            mode = .none
        }
    }

    func cancel() async {
        let wasDirect = if case .direct = mode { true } else { false }
        resetOrdering()
        mode = .none
        if wasDirect {
            await YouTubeHLSStreamSink.shared.cancel()
        }
    }

    func metrics() async -> EncodedOutputMetrics {
        switch mode {
        case .none:
            return EncodedOutputMetrics(
                networkMbps: 0,
                networkUtilization: 0,
                bufferedFragments: 0,
                queuedDuration: 0,
                hasFailure: false
            )
        case .direct:
            let metrics = await YouTubeHLSStreamSink.shared.metrics()
            return EncodedOutputMetrics(
                networkMbps: metrics.networkMbps,
                networkUtilization: metrics.queuedFragments > 1
                    ? max(100, metrics.networkUtilization)
                    : metrics.networkUtilization,
                bufferedFragments: metrics.queuedFragments,
                queuedDuration: metrics.queuedDuration,
                hasFailure: metrics.failure != nil
            )
        }
    }

    private func drainOrderedFragments(routingGeneration generation: UInt64) async {
        while generation == routingGeneration,
              let fragment = pendingFragments.removeValue(forKey: nextExpectedSequence) {
            nextExpectedSequence += 1
            await routeInCurrentMode(fragment)
        }
        if generation == routingGeneration {
            isRouting = false
        }
    }

    private func resetOrdering() {
        routingGeneration &+= 1
        pendingFragments.removeAll(keepingCapacity: true)
        nextExpectedSequence = 0
        isRouting = false
    }
}
