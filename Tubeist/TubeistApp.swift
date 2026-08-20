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

    init(manager: any BackgroundTaskManaging = UIKitBackgroundTaskManager()) {
        self.manager = manager
    }

    var isActive: Bool {
        identifier != .invalid || finalizationTask != nil
    }

    func run(
        name: String,
        operation: @escaping @Sendable () async -> Void
    ) {
        guard identifier == .invalid else { return }
        identifier = manager.beginTask(named: name) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                LOG("iOS background execution time expired while finalizing the stream", level: .error)
                self.finalizationTask?.cancel()
                self.end()
            }
        }
        finalizationTask = Task {
            await operation()
            end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        manager.endTask(identifier)
        identifier = .invalid
        finalizationTask = nil
    }
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
    var streamHealth = StreamHealth.silenced
    var youtubeStatus: String? = nil
    var youtubeBroadcastId: String? = nil
    var activeAlert: String?
    var availableProducts: [String: Product] = [:]
    var lastKnownBrightness: CGFloat = UIScreen.main.brightness

    var activeMonitor: Monitor = DEFAULT_MONITOR
    func setStreamSessionState(_ state: StreamSessionState) {
        streamSessionState = state
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
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            TubeistView().environment(appState)
                .onAppear {
                    Task {
                        await Streamer.shared.setAppState(appState)
                    }
                    UIApplication.shared.isIdleTimerDisabled = true
                    // scenePhase triggers on app init - distinguish this from backgrounding the app
                    appState.isAppInitialization = false
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
        .onChange(of: scenePhase) { oldValue, newValue in
            switch (oldValue, newValue) {
            case (.inactive, .background), (.active, .background):
                if !appState.soonGoingToBackground, !appState.isAppInitialization {
                    appState.soonGoingToBackground = true
                    appState.justCameFromBackground = false
                    LOG("App is entering background", level: .debug)
                    OutputMonitorView.deleteDisplayLayer()
                    CameraMonitorView.deletePreviewLayer()
                    let backgroundLease = BackgroundExecutionLease()
                    backgroundLease.run(name: "Finalize Tubeist stream") {
                        let sessionState = await Streamer.shared.sessionState()
                        if sessionState.ownsMediaPipeline {
                            await MainActor.run {
                                LOG("Stopping stream due to background state", level: .warning)
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
                }
            case (.background, .inactive), (.background, .active):
                if !appState.justCameFromBackground, !appState.isAppInitialization {
                    appState.justCameFromBackground = true
                    appState.soonGoingToBackground = false
                    appState.isBatterySavingOn = false
                    OutputMonitorView.isBatterySavingOn = false
                    LOG("App is coming back from background", level: .debug)
                    Task {
                        await CameraMonitorView.createPreviewLayer()
                        appState.refreshCameraView()
                        if appState.activeMonitor == .output {
                            OutputMonitorView.createDisplayLayer()
                            appState.refreshOutputView()
                        }
                        await Streamer.shared.setMonitor(appState.activeMonitor)
                    }
                }
            default: break
            }
        }
    }
    
    init() {
        Settings.configureJournal()
        do {
            let migration = try Settings.migrateLegacySettings()
            if migration.performed {
                LOG("Migrated legacy streaming settings to the YouTube-only schema", level: .info)
            }
            if migration.requiresYouTubeSetup {
                appState.activeAlert = "YouTube streaming needs setup. Open Settings and enter a YouTube HLS stream key, or choose local recording."
            }
        } catch {
            LOG("Could not migrate legacy streaming credentials; legacy values were preserved", level: .error)
        }
        if CommandLine.arguments.contains("-ui-testing") {
            try? Settings.setStreamKey(nil)
            try? Settings.clearYouTubeAuthorization()
            Settings.stream = true
            Settings.record = false
            appState.activeAlert = nil
        }
        appState.isAppInitialization = true
        LOG("Starting Tubeist version \(VERSION_BUILD)", level: .info)
        UIApplication.shared.isIdleTimerDisabled = true
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
}



 
 
