//
//  TubeistApp.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-11-10.
//

import SwiftUI
import Observation
import AVFoundation

// these are my shared variables
@Observable @MainActor
final class AppState {
    var isBatterySavingOn = false
    var isStreamActive = false
    var isAudioLevelRunning = true
    var isStabilizationOn = true
    var isFocusLocked = false
    var isExposureLocked = false
    var isWhiteBalanceLocked = false
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
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
        .onChange(of: scenePhase) { oldValue, newValue in
            switch (oldValue, newValue) {
            case (.inactive, .background), (.active, .background):
                LOG("App is entering background", level: .debug)
                Task {
                    if await Streamer.shared.isStreaming() {
                        LOG("Stopping stream due to background state", level: .warning)
                        appState.hadToStopStreaming = true
                        Streamer.shared.endStream()
                    }
                    else {
                        Streamer.shared.stopCamera()
                    }
                }
            case (.background, .inactive), (.background, .active):
                if !appState.justCameFromBackground {
                    appState.justCameFromBackground = true
                    LOG("App is coming back from background", level: .debug)
                    // Refresh the camera view
                    appState.refreshCameraView()
                }
            default: break
            }
        }
    }
    init() {
        LOG("Starting Tubeist", level: .info)
        Streamer.shared.setAppState(appState)
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



 
 
