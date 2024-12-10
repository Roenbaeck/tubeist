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
}

@main
struct TubeistApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView().environment(AppState())
        }
    }
    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        print("Starting Tubeist")
    }
}



 
 
