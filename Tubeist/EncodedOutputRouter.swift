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

    // Local live-latency policy, independent of outstanding playlist entries.
    // The count cap also bounds memory for unusually short segments.
    static let maximumQueuedFragments = 30
    static let maximumQueuedDuration: TimeInterval = 10
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
    private var uploadWatchdog: Task<Void, Never>?
    private var needsLiveCatchup = false
    private var uploadNow: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
#if DEBUG
    private var acceptanceSessionIdentifier = ""
    private var dropReportingTask: Task<Void, Never>?
#endif

    func prepare(
        endpoint: YouTubeHLSEndpoint,
        sessionIdentifier: String,
        userAgent: String,
        endingPolicy: HLSStreamEndingPolicy = .automatic,
        transport: (any YouTubeHLSHTTPTransport)? = nil,
        bitrateController: AdaptiveBitrateController? = nil,
        retryPolicy: YouTubeHLSRetryPolicy = .default,
        sleeper: @escaping YouTubeHLSUploader.Sleeper = { try await Task.sleep(for: $0) },
        uploadNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        let previousUploader = uploader
        processingTask?.cancel()
        uploadWatchdog?.cancel()
        uploadWatchdog = nil
        self.uploadNow = uploadNow
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
        var uploadTransport: any YouTubeHLSHTTPTransport = transport ?? URLSessionYouTubeHLSHTTPTransport()
#if DEBUG
        if let directory = await HLSAcceptanceRecorder.shared.begin(
            sessionIdentifier: sessionIdentifier,
            enabled: Settings.recordHLSAcceptance || endingPolicy == .manualDiagnostic
        ) {
            let capture = HLSRequestCapture(directory: directory)
            await capture.start(endingPolicy: endingPolicy)
            uploadTransport = HLSCapturingHTTPTransport(underlying: uploadTransport, capture: capture)
        }
#endif
        guard generation == sessionGeneration else {
            await uploadTransport.invalidate()
            throw YouTubeHLSPackagingError.notPrepared
        }
        uploader = try YouTubeHLSUploader(
            endpoint: endpoint, sessionIdentifier: sessionIdentifier, userAgent: userAgent,
            transport: uploadTransport, retryPolicy: retryPolicy, keepRetrying: true,
            endingPolicy: endingPolicy, sleeper: sleeper
        )
        isPrepared = true
        LOG("YouTube HLS output is prepared", level: .debug)
    }

    func enqueue(_ fragment: Fragment) async {
        guard isPrepared, failure == nil else {
            LOG("Ignoring an encoded fragment because YouTube HLS output is unavailable", level: .warning)
            return
        }
        if queue.count >= Self.maximumQueuedFragments ||
            queue.reduce(fragment.duration, { $0 + $1.duration }) > Self.maximumQueuedDuration {
            needsLiveCatchup = true
            discardQueuedMedia(before: fragment.type == .finalization
                ? (queue.lastIndex(where: { $0.type == .separable }) ?? 0) : queue.count)
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

    private func discardQueuedMedia(before endIndex: Int) {
        var discarded = 0
#if DEBUG
        var events: [(sequence: Int, total: Int)] = []
#endif
        // Select by position, not summed duration: retain the latest complete
        // segment AND any finalization callbacks after it when Stop is draining.
        var retained: [Fragment] = []
        for (index, fragment) in queue.enumerated() {
            if index < endIndex, fragment.type != .initialization {
#if DEBUG
                events.append((fragment.sequence, droppedFragments + discarded + 1))
#endif
                discarded += 1
            } else { retained.append(fragment) }
        }
        queue = retained
        if discarded > 0 {
            droppedFragments += discarded
            pendingDiscontinuity = true
            bitrateController?.discardedBacklog(now: uploadNow())
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

    @discardableResult
    func finish(timeout: TimeInterval = 120) async throws -> Bool {
        let clock = ContinuousClock()
        return try await finish(deadline: clock.now.advanced(by: .seconds(timeout)))
    }

    @discardableResult
    func finish(deadline: ContinuousClock.Instant) async throws -> Bool {
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
            processingTask = Task(priority: .utility) {
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
        var endListAcknowledged = false
        if let finishingUploader {
            if finishingFailure == nil {
                do {
                    if let sequence = lastAcceptedMediaSequence {
                        LOG("YouTube upload queue drained; final acknowledged media sequence \(sequence)", level: .debug)
                    }
                    endListAcknowledged = try await finishingUploader.finish(deadline: deadline)
                    if finishingUploader.endingPolicy == .manualDiagnostic {
                        LOG("YouTube ending test: uploads finished; no ENDLIST or completion sent. End the broadcast manually in YouTube Studio after checking the ending.", level: .info)
                    }
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
        LOG("YouTube HLS output stopped", level: .debug)
        return endListAcknowledged
    }

    func cancel() async {
        sessionGeneration &+= 1
        processingTask?.cancel()
        uploadWatchdog?.cancel()
        uploadWatchdog = nil
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
        let now = uploadNow()
        bitrateController?.update(
            waitingBytes: queue.reduce(0) { $0 + ($1.type == .initialization ? 0 : $1.segment.count) },
            waitingMediaSeconds: queue.reduce(0) { $0 + $1.duration },
            inFlightBytes: currentBytes,
            inFlightDuration: currentDuration,
            inFlightSeconds: uploadStartedAt.map { max(0, now - $0) } ?? 0,
            now: now
        )
        if bitrateController?.state == .capacityBelowQualityFloor, previous != .capacityBelowQualityFloor {
            LOG("Available bandwidth is below the quality floor for this preset; choose a lower resolution for the next stream", level: .warning)
        }
    }

    private func drainQueue(sessionGeneration generation: UInt64) async {
        while generation == sessionGeneration,
              !Task.isCancelled,
              isPrepared,
              failure == nil,
              !queue.isEmpty {
            if needsLiveCatchup, uploadStartedAt == nil {
                // The stalled transaction may have outlived several overflow
                // trims. Resume with the newest complete segment at its ACK.
                discardQueuedMedia(before: queue.lastIndex(where: { $0.type == .separable }) ?? 0)
                needsLiveCatchup = false
            }
            guard !queue.isEmpty else { break }
            let fragment = queue.removeFirst()
            currentFragmentType = fragment.type
            currentDuration = fragment.duration
            currentBytes = fragment.segment.count
            do {
                try await process(fragment, sessionGeneration: generation)
                guard generation == sessionGeneration else { return }
            } catch {
                guard generation == sessionGeneration else { return }
                await handleProcessingFailure(error, sessionGeneration: generation)
            }
            guard generation == sessionGeneration else { return }
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
        guard generation == sessionGeneration else { return }
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
        currentBytes = uploadData.count
        currentDuration = duration
        uploadStartedAt = uploadNow()
        // ACKs and segment boundaries alone can be several seconds apart.
        // Observe a stuck transaction promptly, without counting polls as samples.
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                guard !Task.isCancelled, let self,
                      await self.observeActiveUpload(sessionGeneration: generation) else { return }
            }
        }
        uploadWatchdog = watchdog
        defer {
            watchdog.cancel()
            if generation == sessionGeneration { uploadWatchdog = nil }
        }
#if DEBUG
        let deliveryDetail = String(format: "rate=unpaced;pacingReason=workConserving;pacingWait=0;videoTarget=%ld;mediaMbps=%.3f",
                                    locale: Locale(identifier: "en_US_POSIX"),
                                    bitrateController?.targetBitrate ?? 0,
                                    Double(data.count) * 8 / max(duration, 0.001) / 1_000_000)
#endif
        let receipt = try await uploader.upload(
            segment: uploadData,
            duration: duration,
            discontinuity: signalDiscontinuity
        )
        guard generation == sessionGeneration else { return }
        currentBytes = 0
        currentDuration = 0
        uploadStartedAt = nil
        bitrateController?.delivered(bytes: uploadData.count, elapsed: receipt.elapsedSeconds,
                                     mediaDuration: duration, now: uploadNow())
        updateBitrateController()
        lastAcceptedMediaSequence = receipt.sequence
        let diagnostics = await uploader.diagnostics
        guard generation == sessionGeneration else { return }
        // The uploader has just acknowledged its single outstanding segment;
        // the remaining backlog lives here, not in its playlist bookkeeping.
        let queuedDuration = queue.reduce(0) { $0 + $1.duration }
#if DEBUG
        await HLSAcceptanceRecorder.shared.segmentAccepted(
            sequence: receipt.sequence,
            duration: duration,
            queuedDuration: queuedDuration,
            retryCount: diagnostics.retryCount,
            httpStatus: diagnostics.lastHTTPStatus,
            detail: deliveryDetail
        )
#endif
        let queuedDurationDescription = String(format: "%.2f", queuedDuration)
        let status = diagnostics.lastHTTPStatus.map(String.init) ?? "network"
        LOG(
            "YouTube direct accepted media sequence \(receipt.sequence); queued \(queuedDurationDescription)s; retries \(diagnostics.retryCount); HTTP \(status)",
            level: .debug
        )
    }

    private func observeActiveUpload(sessionGeneration generation: UInt64) -> Bool {
        guard generation == sessionGeneration, isPrepared, uploadStartedAt != nil else { return false }
        updateBitrateController()
        return true
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
        userAgent: String,
        endingPolicy: HLSStreamEndingPolicy = .automatic
    ) async throws {
        resetOrdering()
        let generation = routingGeneration
        mode = .none
        try await YouTubeHLSStreamSink.shared.prepare(
            endpoint: endpoint,
            sessionIdentifier: sessionIdentifier,
            userAgent: userAgent,
            endingPolicy: endingPolicy,
            bitrateController: Self.makeBitrateController()
        )
        guard generation == routingGeneration else {
            throw YouTubeHLSPackagingError.notPrepared
        }
        mode = .direct
    }

    private static func makeBitrateController() -> AdaptiveBitrateController {
        let preset = Settings.selectedPreset
        return AdaptiveBitrateController(ladder: preset.bitrateLadder,
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

    @discardableResult
    func finish(timeout: TimeInterval = 120) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        return try await finish(deadline: deadline)
    }

    @discardableResult
    func finish(deadline: ContinuousClock.Instant) async throws -> Bool {
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
        let endListAcknowledged: Bool
        switch mode {
        case .none:
            endListAcknowledged = false
        case .direct:
            endListAcknowledged = try await YouTubeHLSStreamSink.shared.finish(deadline: deadline)
        }
        if generation == routingGeneration {
            mode = .none
        }
        return endListAcknowledged
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
