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
    var videoBitrate: Int? = nil
    var belowQualityFloor: Bool = false
}

struct EncodedOutputMetrics: Sendable, Equatable {
    let networkMbps: Int
    let networkUtilization: Int
    let bufferedFragments: Int
    let queuedDuration: Double
    let hasFailure: Bool
    var videoBitrate: Int? = nil
    var belowQualityFloor: Bool = false
}

actor YouTubeHLSStreamSink {
    static let shared = YouTubeHLSStreamSink()

    // This is the local encoded-segment queue, not YouTube's limit of five
    // outstanding playlist entries. With two-second writer fragments, thirty
    // entries absorb at least sixty seconds of a temporary network stall while
    // keeping worst-case high-bitrate 4K memory use bounded near 120 MB.
    static let maximumQueuedFragments = 30
    static let maximumQueuedDuration: TimeInterval = 60
    static let recoveryQueuedDuration: TimeInterval = 6
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
    private var bitrateController: AdaptiveBitrateController?
    private var currentBytes = 0
    private var uploadStartedAt: TimeInterval?
    private var processingTask: Task<Void, Never>?
    private var needsLiveCatchup = false
#if DEBUG
    private var acceptanceSessionIdentifier = ""
    private var dropReportingTask: Task<Void, Never>?
#endif

    func prepare(
        endpoint: YouTubeHLSEndpoint,
        sessionIdentifier: String,
        userAgent: String,
        transport: (any YouTubeHLSHTTPTransport)? = nil,
        bitrateController: AdaptiveBitrateController? = nil,
        retryPolicy: YouTubeHLSRetryPolicy = .default,
        sleeper: @escaping YouTubeHLSUploader.Sleeper = { try await Task.sleep(for: $0) }
    ) async throws {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        let previousUploader = uploader
        processingTask?.cancel()
        processingTask = nil
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
        needsLiveCatchup = false
#if DEBUG
        dropReportingTask?.cancel()
        dropReportingTask = nil
        acceptanceSessionIdentifier = sessionIdentifier
#endif
        clearFinalizationBuffer()
        droppedFragments = 0
        lastAcceptedMediaSequence = nil
        failure = nil
        self.bitrateController = bitrateController
        currentBytes = 0
        uploadStartedAt = nil
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
                transport: transport,
                retryPolicy: retryPolicy,
                keepRetrying: true,
                sleeper: sleeper
            )
        } else {
            uploader = try YouTubeHLSUploader(
                endpoint: endpoint,
                sessionIdentifier: sessionIdentifier,
                userAgent: userAgent,
                retryPolicy: retryPolicy,
                keepRetrying: true,
                sleeper: sleeper
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
        if queue.count >= Self.maximumQueuedFragments ||
            queue.reduce(fragment.duration, { $0 + $1.duration }) > Self.maximumQueuedDuration {
            needsLiveCatchup = true
            trimQueue(to: max(0, Self.recoveryQueuedDuration - fragment.duration))
        }
        queue.append(fragment)
        updateBitrateController()
        if !isProcessing {
            isProcessing = true
            let generation = sessionGeneration
            processingTask = Task(priority: .utility) {
                await self.drainQueue(sessionGeneration: generation)
            }
        }
    }

    private func trimQueue(to duration: TimeInterval) {
        var discarded = 0
#if DEBUG
        var events: [(sequence: Int, total: Int)] = []
#endif
        while queue.reduce(0, { $0 + $1.duration }) > duration || queue.count >= Self.maximumQueuedFragments {
            guard let index = queue.firstIndex(where: { $0.type != .initialization }) else { break }
#if DEBUG
            events.append((queue[index].sequence, droppedFragments + discarded + 1))
#endif
            queue.remove(at: index)
            discarded += 1
        }
        if discarded > 0 {
            droppedFragments += discarded
            pendingDiscontinuity = true
            LOG("Discarded \(discarded) queued segments to recover live latency after overflow", level: .warning)
#if DEBUG
            let previous = dropReportingTask
            let identifier = acceptanceSessionIdentifier
            dropReportingTask = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                await HLSAcceptanceRecorder.shared.segmentsDropped(events, sessionIdentifier: identifier)
            }
#endif
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
                    try await finishingUploader.finish(deadline: deadline)
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
        await dropReportingTask?.value
        await HLSAcceptanceRecorder.shared.stopped()
#endif
        LOG("YouTube HLS output stopped", level: .info)
    }

    func cancel() async {
        sessionGeneration &+= 1
        processingTask?.cancel()
        processingTask = nil
        let cancelledUploader = uploader
        uploader = nil
        queue.removeAll(keepingCapacity: true)
        isPrepared = false
        isProcessing = false
        currentFragmentType = nil
        isUploadingFinalization = false
        currentDuration = 0
        currentBytes = 0
        uploadStartedAt = nil
        bitrateController = nil
        clearFinalizationBuffer()
        if let cancelledUploader {
            await cancelledUploader.stop()
        }
#if DEBUG
        await dropReportingTask?.value
        await HLSAcceptanceRecorder.shared.cancelled()
#endif
    }

    func metrics() async -> YouTubeHLSPackagingMetrics {
        let uploadDuration = await uploader?.queuedDuration ?? 0
        let performance = await uploader?.performance ?? (0, 0)
        let reconnecting = await uploader?.diagnostics.isReconnecting ?? false
        let queuedSeparableFragments = queue.lazy.filter { $0.type == .separable }.count
        let currentSeparableFragment = currentFragmentType == .separable ? 1 : 0
        let hasFinalizationSegment = isUploadingFinalization
            || currentFragmentType == .finalization
            || !finalizationSamples.isEmpty
            || queue.contains { $0.type == .finalization }
        return YouTubeHLSPackagingMetrics(
            networkMbps: reconnecting ? 0 : performance.0,
            networkUtilization: reconnecting ? max(100, performance.1) : performance.1,
            queuedFragments: queuedSeparableFragments
                + currentSeparableFragment
                + (hasFinalizationSegment ? 1 : 0),
            queuedDuration: queue.reduce(
                max(currentDuration, uploadDuration, finalizationReportedDuration)
            ) { $0 + $1.duration },
            lastAcceptedMediaSequence: lastAcceptedMediaSequence,
            droppedFragments: droppedFragments,
            failure: failure,
            videoBitrate: bitrateController?.targetBitrate,
            belowQualityFloor: bitrateController?.state == .capacityBelowQualityFloor
        )
    }

    func recommendedVideoBitrate() -> Int? {
        updateBitrateController()
        return bitrateController?.targetBitrate
    }

    private func updateBitrateController() {
        let previous = bitrateController?.state
        let now = ProcessInfo.processInfo.systemUptime
        bitrateController?.update(
            queuedBytes: queue.reduce(currentBytes) { $0 + $1.segment.count },
            queuedMediaSeconds: queue.reduce(currentDuration) { $0 + $1.duration },
            inFlightBytes: currentBytes,
            inFlightSeconds: uploadStartedAt.map { max(0, now - $0) } ?? 0,
            now: now
        )
        if bitrateController?.state == .capacityBelowQualityFloor, previous != .capacityBelowQualityFloor {
            LOG("Available bandwidth is below the quality floor for this preset; choose a lower resolution for the next stream", level: .warning)
        }
    }

    private func drainQueue(sessionGeneration generation: UInt64) async {
        while generation == sessionGeneration,
              isPrepared,
              failure == nil,
              !queue.isEmpty {
            if needsLiveCatchup, uploadStartedAt == nil {
                trimQueue(to: Self.recoveryQueuedDuration)
                needsLiveCatchup = false
            }
            guard !queue.isEmpty else { break }
            let fragment = queue.removeFirst()
            currentFragmentType = fragment.type
            currentDuration = fragment.duration
            currentBytes = fragment.segment.count
            uploadStartedAt = ProcessInfo.processInfo.systemUptime
            do {
                try await process(fragment, sessionGeneration: generation)
                guard generation == sessionGeneration else { return }
            } catch {
                guard generation == sessionGeneration else { return }
                await handleProcessingFailure(error, sessionGeneration: generation)
            }
            currentDuration = 0
            currentBytes = 0
            uploadStartedAt = nil
            currentFragmentType = nil
            updateBitrateController()
        }
        if generation == sessionGeneration {
            isProcessing = false
        }
    }

    private func process(_ fragment: Fragment, sessionGeneration generation: UInt64) async throws {
        if fragment.container == .mpegTransportStream {
            try await uploadTransportData(fragment.segment, duration: fragment.duration,
                                          discontinuity: fragment.discontinuity, sessionGeneration: generation)
            return
        }
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
        try await uploadTransportData(transportSegment.data, duration: duration,
                                      discontinuity: discontinuity, sessionGeneration: generation)
    }

    private func uploadTransportData(
        _ data: Data, duration: Double, discontinuity: Bool, sessionGeneration generation: UInt64
    ) async throws {
        guard let uploader else { throw YouTubeHLSPackagingError.notPrepared }
        let signalDiscontinuity = discontinuity || pendingDiscontinuity
        // Consume only the gap known at upload start. An overflow while this
        // request is in flight belongs to the next segment and must survive ACK.
        pendingDiscontinuity = false
        let uploadData = signalDiscontinuity ? try MPEGTransportStreamMuxer.markingDiscontinuity(data) : data
        let receipt = try await uploader.upload(
            segment: uploadData,
            duration: duration,
            discontinuity: signalDiscontinuity
        )
        guard generation == sessionGeneration else { return }
        bitrateController?.delivered(bytes: data.count, elapsed: receipt.elapsedSeconds)
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
    private var pendingFragments = FragmentReorderBuffer()
    private var isRouting = false
    private var routingGeneration: UInt64 = 0
    private var routingTask: Task<Void, Never>?

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
            userAgent: userAgent,
            bitrateController: Self.makeBitrateController()
        )
        guard generation == routingGeneration else {
            throw YouTubeHLSPackagingError.notPrepared
        }
        mode = .direct
    }

    private static func makeBitrateController() -> AdaptiveBitrateController {
        let preset = Settings.selectedPreset
        // A starting quality guardrail, not a promise about scene complexity.
        // Never raise a user's selected target, including unusually low presets.
        let floor = Int(max(250_000, Double(preset.width * preset.height) * preset.frameRate * 0.015))
        return AdaptiveBitrateController(maximumBitrate: preset.videoBitrate, minimumBitrate: floor,
                                         audioBitrate: preset.audioBitrate * preset.audioChannels)
    }

    func recommendedVideoBitrate() async -> Int? {
        guard case .direct = mode else { return nil }
        return await YouTubeHLSStreamSink.shared.recommendedVideoBitrate()
    }

    func route(_ fragment: Fragment) {
        guard case .direct = mode else { return }
        pendingFragments.insert(fragment)
        if !isRouting {
            isRouting = true
            let generation = routingGeneration
            routingTask = Task(priority: .utility) {
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
                hasFailure: metrics.failure != nil,
                videoBitrate: metrics.videoBitrate,
                belowQualityFloor: metrics.belowQualityFloor
            )
        }
    }

    private func drainOrderedFragments(routingGeneration generation: UInt64) async {
        do {
            while generation == routingGeneration, !pendingFragments.isEmpty, !Task.isCancelled {
                if let fragment = try pendingFragments.takeNext(now: ProcessInfo.processInfo.systemUptime) {
                    await routeInCurrentMode(fragment)
                } else {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
        } catch {
            guard generation == routingGeneration, !Task.isCancelled else { return }
            await cancel()
            await Streamer.shared.handleRuntimeFailure(error)
        }
        if generation == routingGeneration {
            isRouting = false
        }
    }

    private func resetOrdering() {
        routingGeneration &+= 1
        routingTask?.cancel()
        routingTask = nil
        pendingFragments = FragmentReorderBuffer()
        isRouting = false
    }
}
