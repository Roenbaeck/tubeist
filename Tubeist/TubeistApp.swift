//
//  TubeistApp.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-11-10.
//

import SwiftUI
import Observation
import AVFoundation
import StoreKit

@MainActor
protocol BackgroundTaskManaging: Sendable {
    func beginTask(
        named name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier
    func endTask(_ identifier: UIBackgroundTaskIdentifier)
}

@MainActor
struct UIKitBackgroundTaskManager: BackgroundTaskManaging {
    func beginTask(
        named name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(
            withName: name,
            expirationHandler: expirationHandler
        )
    }

    func endTask(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

@MainActor
final class BackgroundExecutionLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var finalizationTask: Task<Void, Never>?
    private let manager: any BackgroundTaskManaging
    private var generation = UUID()

    init(manager: any BackgroundTaskManaging = UIKitBackgroundTaskManager()) {
        self.manager = manager
    }

    var isActive: Bool {
        identifier != .invalid || finalizationTask != nil
    }

    @discardableResult
    func run(
        name: String,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        guard !isActive else { return nil }
        let generation = UUID()
        self.generation = generation
        identifier = manager.beginTask(named: name) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                LOG("iOS background execution time expired while finalizing the stream", level: .error)
                self.finalizationTask?.cancel()
                self.end()
            }
        }
        finalizationTask = Task {
            await operation()
            guard self.generation == generation else { return }
            end()
        }
        return finalizationTask
    }

    func end() {
        generation = UUID()
        let endingIdentifier = identifier
        identifier = .invalid
        finalizationTask = nil
        if endingIdentifier != .invalid {
            manager.endTask(endingIdentifier)
        }
    }

    func cancel() {
        finalizationTask?.cancel()
        end()
    }
}

private enum BackgroundStreamPolicy {
    static let stopGracePeriod: Duration = .seconds(3)
}

// these are my shared variables
@Observable @MainActor
final class AppState {
    var isBatterySavingOn = false
    var streamSessionState: StreamSessionState = .idle
    var isStreamActive: Bool { streamSessionState.isLive }
    var isStreamSessionRunning: Bool { streamSessionState.ownsMediaPipeline }
    var isAudioLevelRunning = true
    var isStabilizationOn = true
    var isFocusLocked = false
    var isExposureLocked = false
    var isWhiteBalanceLocked = false
    var areOverlaysHidden = Settings.hideOverlays
    var isAppInitialization = true
    var soonGoingToBackground = false
    var justCameFromBackground = false
    var hadToStopStreaming = false
    var isBackgroundStopCommitted = false
    private var localStreamHealth = StreamHealth.silenced
    let youtubeHealth = YouTubeStreamHealthMonitor()
    var streamHealth: StreamHealth {
        get {
            guard isStreamActive, youtubeHealth.target != nil else { return localStreamHealth }
            return youtubeHealth.assessment.combining(localStreamHealth)
        }
        set { localStreamHealth = newValue }
    }
    var isYouTubeSignedIn = false
    var youtubeStatus: String? = nil
    var youtubeBroadcastId: String? = nil
    var activeAlert: String?
    var availableProducts: [String: Product] = [:]
    var lastKnownBrightness: CGFloat = UIScreen.main.brightness

    var activeMonitor: Monitor = DEFAULT_MONITOR
    func setStreamSessionState(_ state: StreamSessionState) {
        streamSessionState = state
        if !state.isLive { youtubeHealth.configure(nil) }
        switch state {
        case .preparing, .live:
            streamHealth = .awaiting
        case .idle:
            streamHealth = .silenced
        case .stopping:
            break
        case .failed:
            streamHealth = .unusable
            if case .failed(let message) = state {
                activeAlert = message
            }
        }
    }
    var cameraMonitorId = UUID()
    func refreshCameraView() {
        cameraMonitorId = UUID()
    }
    var outputMonitorId = UUID()
    func refreshOutputView() {
        outputMonitorId = UUID()
    }
}

@main
struct TubeistApp: App {
    @State private var appState = AppState()
    @State private var backgroundExecutionLease = BackgroundExecutionLease()
    @Environment(\.scenePhase) private var scenePhase
    private let startupAlert: String?
    
    var body: some Scene {
        WindowGroup {
#if DEBUG
            if HEVC422Probe.isRequested {
                HEVC422ProbeView()
            } else if HLSUploadReplay.isRequested {
                HLSUploadReplayView()
            } else {
                applicationView
            }
#else
            applicationView
#endif
        }
        .onChange(of: scenePhase) { oldValue, newValue in
#if DEBUG
            guard !HLSUploadReplay.isRequested, !HEVC422Probe.isRequested else { return }
#endif
            handleScenePhase(oldValue, newValue)
        }
    }

    private var applicationView: some View {
            TubeistView().environment(appState)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    // State is installed here. Accessing it in App.init can
                    // create temporary instances instead of the shared model.
                    guard appState.isAppInitialization else { return }
                    if let startupAlert { appState.activeAlert = startupAlert }
                    // scenePhase triggers on app init - distinguish this from backgrounding the app
                    appState.isAppInitialization = false
                    guard !CommandLine.arguments.contains("-ui-testing") else { return }
                    Task { [appState] in
                        let products = await Purchaser.shared.fetchProducts()
                        for product in products {
                            LOG("Available product \(product.id)", level: .debug)
                            appState.availableProducts[product.id] = product
                        }
                    }
                    Task {
                        LOG("Checking for previously made purchases", level: .debug)
                        await Purchaser.shared.verifyPurchases()
                    }
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
    }

    private func handleScenePhase(_ oldValue: ScenePhase, _ newValue: ScenePhase) {
            switch (oldValue, newValue) {
            case (.inactive, .background), (.active, .background):
                if !appState.soonGoingToBackground, !appState.isAppInitialization {
                    appState.soonGoingToBackground = true
                    appState.justCameFromBackground = false
                    appState.isBackgroundStopCommitted = false
                    LOG("App is entering background", level: .debug)
                    OutputMonitorView.stop()
                    CameraMonitorView.deletePreviewLayer()
                    backgroundExecutionLease.run(name: "Finalize Tubeist stream") {
                        do {
                            try await Task.sleep(for: BackgroundStreamPolicy.stopGracePeriod)
                        } catch {
                            LOG("Cancelled pending background stream stop", level: .info)
                            return
                        }
                        let sessionState = await Streamer.shared.sessionState()
                        let canCommitStop = switch sessionState {
                        case .preparing, .live: true
                        case .idle, .stopping, .failed: false
                        }
                        guard canCommitStop else { return }
                        let shouldStop = await MainActor.run {
                            guard appState.soonGoingToBackground,
                                  UIApplication.shared.applicationState == .background else {
                                return false
                            }
                            appState.isBackgroundStopCommitted = true
                            return true
                        }
                        guard shouldStop else { return }
                        await MainActor.run {
                            LOG("Stopping stream after the background grace period", level: .warning)
                            appState.hadToStopStreaming = true
                        }
                        do {
                            _ = try await Streamer.shared.endStream(
                                resumePreviewAfterStop: false,
                                shutdownTimeout: 18
                            )
                        } catch {
                            LOG("Background stream shutdown failed: \(error.localizedDescription)", level: .error)
                            await MainActor.run {
                                appState.activeAlert = "Stream finalization failed in the background: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            case (.background, .inactive), (.background, .active):
                if !appState.justCameFromBackground, !appState.isAppInitialization {
                    let stopWasCommitted = appState.isBackgroundStopCommitted
                    if !stopWasCommitted {
                        backgroundExecutionLease.cancel()
                    } else {
                        // The media pipeline is already finalizing and cannot be
                        // reopened safely. It no longer needs a background lease
                        // now that the app is active again.
                        backgroundExecutionLease.end()
                    }
                    appState.justCameFromBackground = true
                    appState.soonGoingToBackground = false
                    appState.isBackgroundStopCommitted = false
                    appState.isBatterySavingOn = false
                    if stopWasCommitted {
                        LOG("App returned after background stream finalization began", level: .debug)
                    } else {
                        LOG("App returned within the background stop grace period", level: .info)
                    }
                    if appState.activeMonitor == .output {
                        appState.refreshOutputView()
                    }
                }
            default: break
            }
    }
    
    init() {
#if DEBUG
        if HLSUploadReplay.isRequested || HEVC422Probe.isRequested {
            startupAlert = nil
            UIApplication.shared.isIdleTimerDisabled = true
            return
        }
#endif
        // Keep migration before view creation, but carry its result as plain
        // initialization data until SwiftUI installs appState.
        var startupAlert: String?
        do {
            let migration = try Settings.migrateLegacySettings()
            if migration.performed {
                LOG("Migrated legacy streaming settings to the YouTube-only schema", level: .info)
            }
            if migration.requiresYouTubeSetup {
                startupAlert = "YouTube streaming needs setup. Open Settings and enter a YouTube HLS stream key, or choose local recording."
            }
        } catch {
            LOG("Could not migrate legacy streaming credentials; legacy values were preserved", level: .error)
        }
        if CommandLine.arguments.contains("-ui-testing") {
            try? Settings.setStreamKey(nil)
            try? Settings.clearYouTubeAuthorization()
            Settings.stream = true
            Settings.record = false
            startupAlert = nil
        }
        self.startupAlert = startupAlert
        LOG("Starting Tubeist version \(VERSION_BUILD)", level: .info)
        UIApplication.shared.isIdleTimerDisabled = true
    }
}



 
 
