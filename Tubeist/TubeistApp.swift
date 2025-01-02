//
//  TubeistApp.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-11-10.
//

import SwiftUI
import Observation
import AVFoundation

// different views for the iPhone display
enum Monitor {
    case camera
    case output
}

// these are my shared variables
@Observable @MainActor
final class AppState {
    var activeMonitor: Monitor = .camera
    var isBatterySavingOn = false
    var isStreamActive = false
    var isAudioLevelRunning = true
    var isStabilizationOn = true
    var isFocusLocked = false
    var isExposureLocked = false
    var isWhiteBalanceLocked = false
    var areOverlaysHidden = Settings.hideOverlays
    var soonGoingToBackground = false
    var justCameFromBackground = false
    var hadToStopStreaming = false
    var streamHealth = StreamHealth.silenced
    var cameraMonitorId = UUID()
    
    func refreshCameraView() {
        cameraMonitorId = UUID()
    }
}

@main
struct TubeistApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView().environment(appState)
                .onAppear {
                    Task {
                        await Streamer.shared.setAppState(appState)
                    }
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
        .onChange(of: scenePhase) { oldValue, newValue in
            switch (oldValue, newValue) {
            case (.inactive, .background), (.active, .background):
                if !appState.soonGoingToBackground {
                    appState.soonGoingToBackground = true
                    appState.justCameFromBackground = false
                    LOG("App is entering background", level: .debug)
                    Task {
                        if await Streamer.shared.isStreaming() {
                            LOG("Stopping stream due to background state", level: .warning)
                            appState.hadToStopStreaming = true
                            await Streamer.shared.endStream()
                        }
                        await Streamer.shared.stopCamera()
                    }
                }
            case (.background, .inactive), (.background, .active):
                if !appState.justCameFromBackground {
                    appState.justCameFromBackground = true
                    appState.soonGoingToBackground = false
                    LOG("App is coming back from background", level: .debug)
                    Task {
                        // Refresh the camera view
                        await Streamer.shared.startCamera()
                        appState.refreshCameraView()
                    }
                }
            default: break
            }
        }
    }
    
    
    init() {
        LOG("Starting Tubeist", level: .info)
        LOG("Using \(REFERENCE_TIMEPOINT) as reference time for streams", level: .debug)
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.mixWithOthers, .overrideMutedMicrophoneInterruption])
        }
        catch {
            LOG("Could not set up the app audio session: \(error.localizedDescription)", level: .error)
        }
    }
}



 
 
