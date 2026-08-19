//
//  Streamer.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-06.
//
import CoreMedia
import UIKit

enum StreamHealth {
    case silenced   // When stream is not running
    case awaiting   // Health has not been determined
    case unusable   // Stream is too bad to watch
    case degraded   // Noticeable quality issues
    case pristine   // Perfect viewing experience
}

enum EncodedStreamDelivery: Sendable, Equatable {
    case none
    case relay
    case youTubeDirect
}

struct StreamOutputPlan: Sendable, Equatable {
    let delivery: EncodedStreamDelivery
    let recordsOriginalFMP4: Bool

    var routesEncodedFragments: Bool { delivery != .none }
    var uploadsOriginalFMP4: Bool { delivery == .relay }
    var remuxesToTransportStream: Bool { delivery == .youTubeDirect }

    static func resolve(
        stream: Bool,
        record: Bool,
        destination: StreamDestination,
        target: String,
        directYouTubeAvailable: Bool
    ) throws -> StreamOutputPlan {
        guard stream else {
            return StreamOutputPlan(delivery: .none, recordsOriginalFMP4: record)
        }

        switch destination {
        case .relay:
            return StreamOutputPlan(delivery: .relay, recordsOriginalFMP4: record)

        case .youTubeDirect:
            guard directYouTubeAvailable else {
                throw StreamStartError.directModeUnavailable
            }
            guard target == "youtube" else {
                throw StreamStartError.directModeRequiresYouTube
            }
            return StreamOutputPlan(delivery: .youTubeDirect, recordsOriginalFMP4: record)
        }
    }
}

actor StreamingActor {
    private var appState: AppState?
    func setAppState(_ appState: AppState) {
        self.appState = appState
    }
    func run() {
        Task { @MainActor in
            await appState?.isStreamActive = true
            await appState?.streamHealth = .awaiting
        }
    }
    func pause() {
        Task { @MainActor in
            await appState?.isStreamActive = false
        }
    }
    func setStreamHealth(_ health: StreamHealth) {
        Task { @MainActor in
            await appState?.streamHealth = health
        }
    }
    func getStreamHealth() async -> StreamHealth {
        await appState?.streamHealth ?? .awaiting
    }
    func isStreaming() async -> Bool {
        await appState?.isStreamActive ?? false
    }
    func toggleBatterySaving() {
        Task { @MainActor in
            await appState?.isBatterySavingOn.toggle()
            OutputMonitorView.isBatterySavingOn = await appState?.isBatterySavingOn ?? false
        }
    }
    func refreshCameraView() {
        Task { @MainActor in
            await appState?.refreshCameraView()
        }
    }
    func getMonitor() async -> Monitor {
        await appState?.activeMonitor ?? DEFAULT_MONITOR
    }
}

final class Streamer: Sendable {
    @PipelineActor public static let shared = Streamer()
    private let streamingActor = StreamingActor()
    private static let streamIDFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    static func makeStreamID(at date: Date = Date(), uuid: UUID = UUID()) -> String {
        let suffix = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        return "\(streamIDFormatter.string(from: date))_\(suffix)"
    }
    
    func setAppState(_ appState: AppState) async {
        await self.streamingActor.setAppState(appState)
    }
    func cycleSessions() async {
        let outputting = await CaptureDirector.shared.isOutputting()
        if outputting {
            await CaptureDirector.shared.stopOutput()
        }
        await FrameGrabber.shared.resetTinkerer()
        await CaptureDirector.shared.cycleSessions()
        await streamingActor.refreshCameraView()
        OverlayBundler.shared.refreshCombinedImage()
        if outputting {
            await CaptureDirector.shared.startOutput()
        }
    }
    func startSessions() async {
        await CaptureDirector.shared.startSessions()
    }
    func stopSessions() async {
        await CaptureDirector.shared.stopSessions()
    }
    func startStream(streamID: String) async throws {
        guard await !ContentPackager.shared.isPackaging() else {
            throw ContentPackagingError.assetWriterAlreadyWriting
        }
        let outputPlan = try StreamOutputPlan.resolve(
            stream: Settings.stream,
            record: Settings.record,
            destination: Settings.streamDestination,
            target: Settings.target,
            directYouTubeAvailable: DIRECT_YOUTUBE_HLS_AVAILABLE
        )
        do {
            try await prepareEncodedOutput(streamID: streamID, plan: outputPlan)
            try await ContentPackager.shared.beginPackaging(
                stream: outputPlan.routesEncodedFragments,
                record: outputPlan.recordsOriginalFMP4
            )
        } catch {
            await EncodedOutputRouter.shared.cancel()
            throw error
        }
        await SoundGrabber.shared.commenceGrabbing()
        await FrameGrabber.shared.commenceGrabbing()
        await CaptureDirector.shared.startOutput()
        await streamingActor.run()
    }
    func endStream() async {
        // session time is close to real time
        // presentation time can be earlier because of camera stabilization
        if let sessionTime = await CaptureDirector.shared.getSessionTime(),
           let presentationTime = await FrameGrabber.shared.getCurrentPresentationTimestamp() {
            let difference = CMTimeSubtract(sessionTime, presentationTime)
            let duration = CMTimeGetSeconds(difference)
            LOG("Sleeping \(duration) seconds to await late frames", level: .debug)
            if duration > 0 {
                do {
                    try await Task.sleep(for: .seconds(duration))
                }
                catch {
                    LOG("The sleep intended to await late frames was interrupted", level: .warning)
                }
            }
        }
        
        await streamingActor.pause()
        if await streamingActor.getMonitor() == .camera {
            await CaptureDirector.shared.stopOutput()
            await FrameGrabber.shared.terminateGrabbing()
        }
        await SoundGrabber.shared.terminateGrabbing()
        await ContentPackager.shared.endPackaging()
        do {
            try await EncodedOutputRouter.shared.finish()
        } catch {
            LOG("Encoded output shutdown failed: \(error)", level: .error)
            await streamingActor.setStreamHealth(.unusable)
        }
    }
    func isStreaming() async -> Bool {
        await streamingActor.isStreaming()
    }
    func setStreamHealth(_ health: StreamHealth) {
        Task {
            await streamingActor.setStreamHealth(health)
        }
    }
    func getStreamHealth() async -> StreamHealth {
        await streamingActor.getStreamHealth()
    }
    func toggleBatterySaving() async {
        await streamingActor.toggleBatterySaving()
    }
    func getMonitor() async -> Monitor {
        await streamingActor.getMonitor()
    }
    func setMonitor(_ monitor: Monitor) async {
        LOG("Setting monitor to \(monitor)", level: .debug)
        if monitor == .output, await !isStreaming() {
            LOG("Starting half the streaming pipeline", level: .debug)
            await FrameGrabber.shared.commenceGrabbing()
            await CaptureDirector.shared.startOutput()
        }
        else if monitor == .camera, await !isStreaming() {
            LOG("Stopping half the streaming pipeline", level: .debug)
            await CaptureDirector.shared.stopOutput()
            await FrameGrabber.shared.terminateGrabbing()
        }
    }

    private func prepareEncodedOutput(streamID: String, plan: StreamOutputPlan) async throws {
        switch plan.delivery {
        case .none:
            await EncodedOutputRouter.shared.prepareForRecordingOnly()

        case .relay:
            await EncodedOutputRouter.shared.prepareRelay(streamID: streamID)

        case .youTubeDirect:
            guard let streamKey = Settings.streamKey, !streamKey.isEmpty else {
                throw StreamStartError.missingStreamKey
            }

            let endpoint: YouTubeHLSEndpoint
            if Settings.youtubeRefreshToken != nil {
                let service = await YouTubeService()
                endpoint = try await service.findHLSIngestionEndpoint(forStreamKey: streamKey)
            } else {
                endpoint = try YouTubeHLSEndpoint.manualPrimary(streamKey: streamKey)
            }
            let model = await MainActor.run { UIDevice.current.model.replacingOccurrences(of: " ", with: "_") }
            let userAgent = "Apple / \(model) / Tubeist-\(Bundle.main.appVersion ?? "unknown")"
            try await EncodedOutputRouter.shared.prepareDirect(
                endpoint: endpoint,
                sessionIdentifier: streamID,
                userAgent: userAgent
            )
        }
    }
}

enum StreamStartError: LocalizedError, Equatable {
    case directModeUnavailable
    case directModeRequiresYouTube
    case missingStreamKey

    var errorDescription: String? {
        switch self {
        case .directModeUnavailable: "Direct YouTube HLS is not enabled in this build"
        case .directModeRequiresYouTube: "Direct HLS delivery is available only for YouTube"
        case .missingStreamKey: "Enter a YouTube HLS stream key before starting"
        }
    }
}
