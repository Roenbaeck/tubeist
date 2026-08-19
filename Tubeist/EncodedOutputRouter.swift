//
//  EncodedOutputRouter.swift
//  Tubeist
//

import Foundation

enum DirectHLSStreamError: LocalizedError, CustomStringConvertible {
    case notPrepared
    case initializationMissing
    case segmentDurationMismatch(reported: Double, parsed: Double)
    case shutdownTimedOut

    var description: String {
        switch self {
        case .notPrepared: "Direct HLS output was not prepared"
        case .initializationMissing: "A media fragment arrived before its initialization segment"
        case .segmentDurationMismatch(let reported, let parsed):
            "Fragment duration mismatch (writer \(reported)s, parsed \(parsed)s)"
        case .shutdownTimedOut: "Direct HLS output did not drain before its shutdown deadline"
        }
    }

    var errorDescription: String? { description }
}

struct DirectHLSMetrics: Sendable, Equatable {
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

actor DirectHLSStreamSink {
    static let shared = DirectHLSStreamSink()

    private static let maximumQueuedFragments = 5
    private let reader = ISOBMFFReader()
    private var initialization: ISOBMFFInitialization?
    private var muxer = MPEGTransportStreamMuxer()
    private var uploader: YouTubeHLSUploader?
    private var queue: [Fragment] = []
    private var isProcessing = false
    private var isPrepared = false
    private var currentDuration = 0.0
    private var pendingDiscontinuity = false
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
        currentDuration = 0
        pendingDiscontinuity = false
        droppedFragments = 0
        lastAcceptedMediaSequence = nil
        failure = nil
        if let previousUploader {
            await previousUploader.stop()
        }
        guard generation == sessionGeneration else {
            throw DirectHLSStreamError.notPrepared
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
        LOG("Direct YouTube HLS output is prepared", level: .info)
    }

    func enqueue(_ fragment: Fragment) async {
        guard isPrepared, failure == nil else {
            LOG("Ignoring an encoded fragment because direct HLS output is unavailable", level: .warning)
            return
        }
        if queue.count >= Self.maximumQueuedFragments {
            if let dropIndex = queue.firstIndex(where: { $0.type != .initialization }) {
                let dropped = queue.remove(at: dropIndex)
                droppedFragments += 1
                pendingDiscontinuity = true
                LOG("Direct HLS queue dropped fragment \(dropped.sequence); the next segment will be discontinuous", level: .warning)
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

    func finish(timeout: TimeInterval = 20) async throws {
        let generation = sessionGeneration
        let deadline = Date().addingTimeInterval(timeout)
        while generation == sessionGeneration,
              (isProcessing || !queue.isEmpty),
              failure == nil,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard generation == sessionGeneration else {
            throw DirectHLSStreamError.notPrepared
        }
        guard !isProcessing, queue.isEmpty else {
            await cancel()
            throw DirectHLSStreamError.shutdownTimedOut
        }
        let finishingUploader = uploader
        uploader = nil
        isPrepared = false
        let finishingFailure = failure
        if let finishingUploader {
            await finishingUploader.stop()
        }
        guard generation == sessionGeneration else {
            throw DirectHLSStreamError.notPrepared
        }
        if finishingFailure != nil {
            // The detailed failure was already journaled without an ingestion
            // URL. Keep the public shutdown error stable and non-secret.
            throw DirectHLSStreamError.notPrepared
        }
        LOG("Direct YouTube HLS output stopped", level: .info)
    }

    func cancel() async {
        sessionGeneration &+= 1
        let cancelledUploader = uploader
        uploader = nil
        queue.removeAll(keepingCapacity: true)
        isPrepared = false
        isProcessing = false
        currentDuration = 0
        if let cancelledUploader {
            await cancelledUploader.stop()
        }
    }

    func metrics() async -> DirectHLSMetrics {
        let uploadDuration = await uploader?.queuedDuration ?? 0
        let performance = await uploader?.performance ?? (0, 0)
        return DirectHLSMetrics(
            networkMbps: performance.0,
            networkUtilization: performance.1,
            queuedFragments: queue.count + (isProcessing ? 1 : 0),
            queuedDuration: queue.reduce(max(currentDuration, uploadDuration)) { $0 + $1.duration },
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
            currentDuration = fragment.duration
            do {
                try await process(fragment, sessionGeneration: generation)
                guard generation == sessionGeneration else { return }
            } catch {
                guard generation == sessionGeneration else { return }
                failure = String(describing: error)
                queue.removeAll(keepingCapacity: true)
                LOG("Direct HLS packaging stopped: \(error)", level: .error)
                await Streamer.shared.setStreamHealth(.unusable)
                if let uploader {
                    await uploader.stop()
                }
            }
            currentDuration = 0
        }
        if generation == sessionGeneration {
            isProcessing = false
        }
    }

    private func process(_ fragment: Fragment, sessionGeneration generation: UInt64) async throws {
        switch fragment.type {
        case .initialization:
            initialization = try reader.parseInitializationSegment(fragment.segment)
            LOG("Parsed direct HLS initialization metadata", level: .debug)

        case .separable, .finalization:
            guard let initialization else {
                throw DirectHLSStreamError.initializationMissing
            }
            guard let uploader else {
                throw DirectHLSStreamError.notPrepared
            }
            let media = try reader.parseMediaSegment(fragment.segment, initialization: initialization)
            let transportSegment = try muxer.mux(media, initialization: initialization)
            let duration = fragment.duration > 0 ? fragment.duration : transportSegment.duration
            let tolerance = max(0.1, duration / 20)
            if fragment.duration > 0,
               abs(fragment.duration - transportSegment.duration) > tolerance {
                throw DirectHLSStreamError.segmentDurationMismatch(
                    reported: fragment.duration,
                    parsed: transportSegment.duration
                )
            }
            let receipt = try await uploader.upload(
                segment: transportSegment.data,
                duration: duration,
                discontinuity: fragment.discontinuity || pendingDiscontinuity
            )
            guard generation == sessionGeneration else { return }
            pendingDiscontinuity = false
            lastAcceptedMediaSequence = receipt.sequence
            let diagnostics = await uploader.diagnostics
            let queuedDuration = await uploader.queuedDuration
            let queuedDurationDescription = String(format: "%.2f", queuedDuration)
            let status = diagnostics.lastHTTPStatus.map(String.init) ?? "network"
            LOG(
                "YouTube direct accepted media sequence \(receipt.sequence); queued \(queuedDurationDescription)s; retries \(diagnostics.retryCount); HTTP \(status)",
                level: .debug
            )
        }
    }
}

actor EncodedOutputRouter {
    static let shared = EncodedOutputRouter()

    private enum Mode {
        case none
        case relay
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

    func prepareRelay(streamID: String) async {
        resetOrdering()
        let generation = routingGeneration
        mode = .none
        await FragmentPusher.shared.immediatePreparation(streamID: streamID)
        if generation == routingGeneration {
            mode = .relay
        }
    }

    func prepareDirect(
        endpoint: YouTubeHLSEndpoint,
        sessionIdentifier: String,
        userAgent: String
    ) async throws {
        resetOrdering()
        let generation = routingGeneration
        mode = .none
        try await DirectHLSStreamSink.shared.prepare(
            endpoint: endpoint,
            sessionIdentifier: sessionIdentifier,
            userAgent: userAgent
        )
        guard generation == routingGeneration else {
            throw DirectHLSStreamError.notPrepared
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
        case .relay:
            await FragmentPusher.shared.addFragment(fragment)
            await FragmentPusher.shared.uploadFragment(attempt: 1)
        case .direct:
            await DirectHLSStreamSink.shared.enqueue(fragment)
        }
    }

    func finish(timeout: TimeInterval = 25) async throws {
        let generation = routingGeneration
        let deadline = Date().addingTimeInterval(timeout)
        while generation == routingGeneration,
              (isRouting || !pendingFragments.isEmpty),
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard generation == routingGeneration else {
            throw DirectHLSStreamError.notPrepared
        }
        guard !isRouting, pendingFragments.isEmpty else {
            await cancel()
            throw DirectHLSStreamError.shutdownTimedOut
        }
        switch mode {
        case .none:
            break
        case .relay:
            await FragmentPusher.shared.gracefulShutdown()
        case .direct:
            try await DirectHLSStreamSink.shared.finish()
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
            await DirectHLSStreamSink.shared.cancel()
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
        case .relay:
            let (mbps, utilization) = await FragmentPusher.shared.networkPerformance()
            let buffered = await FragmentPusher.shared.fragmentBufferCount()
            return EncodedOutputMetrics(
                networkMbps: mbps,
                networkUtilization: utilization,
                bufferedFragments: buffered,
                queuedDuration: Double(buffered) * FRAGMENT_DURATION,
                hasFailure: false
            )
        case .direct:
            let metrics = await DirectHLSStreamSink.shared.metrics()
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
