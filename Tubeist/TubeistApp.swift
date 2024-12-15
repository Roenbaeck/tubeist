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
        }
        .onChange(of: scenePhase) { oldValue, newValue in
            switch (oldValue, newValue) {
            case (.inactive, .background), (.active, .background):
                print("App is entering background")
                Task {
                    if await Streamer.shared.isStreaming() {
                        print("Stopping stream due to background state")
                        appState.hadToStopStreaming = true
                        Streamer.shared.endStream()
                    }
                    else {
                        Streamer.shared.stopCamera()
                    }
                }
            case (.background, .inactive), (.background, .active):
                print("App is coming back from background")
                appState.justCameFromBackground = true
                // Refresh the camera view
                appState.refreshCameraView()
            default: break
            }
        }
    }
    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        print("Starting Tubeist")
    }
}



 
 
