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
    var areOverlaysHidden = Settings.hideOverlays
    var isAppInitialization = true
    var soonGoingToBackground = false
    var justCameFromBackground = false
    var hadToStopStreaming = false
    var streamHealth = StreamHealth.silenced
    var cameraMonitorId = UUID()
    var availableProducts: [String: Product] = [:]
    var lastKnownBrightness: CGFloat = UIScreen.main.brightness

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
                    Task {
                        if await Streamer.shared.isStreaming() {
                            LOG("Stopping stream due to background state", level: .warning)
                            appState.hadToStopStreaming = true
                            await Streamer.shared.endStream()
                        }
                    }
                }
            case (.background, .inactive), (.background, .active):
                if !appState.justCameFromBackground, !appState.isAppInitialization {
                    appState.justCameFromBackground = true
                    appState.soonGoingToBackground = false
                    appState.isBatterySavingOn = false
                    LOG("App is coming back from background", level: .debug)
                }
            default: break
            }
        }
    }
    
    init() {
        appState.isAppInitialization = true
        LOG("Starting Tubeist version \(VERSION_BUILD)", level: .info)
        UIApplication.shared.isIdleTimerDisabled = true
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



 
 
