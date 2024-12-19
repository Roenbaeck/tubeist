//
//  TubeistApp.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-11-10.
//

import SwiftUI
import Observation

// these are my shared variables
@Observable
class AppState {
    var isBatterySavingOn = false
    var isStreamActive = false
    var isAudioLevelRunning = true
    var isStabilizationOn = true
    var isFocusLocked = false
    var isExposureLocked = false
    var justCameFromBackground = false
    var hadToStopStreaming = false
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
                LOG("App is coming back from background", level: .debug)
                appState.justCameFromBackground = true
                // Refresh the camera view
                appState.refreshCameraView()
            default: break
            }
        }
    }
    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        LOG("Starting Tubeist", level: .info)
    }
}



 
 
