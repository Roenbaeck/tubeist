//
//  ContentView.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

import SwiftUI
import UserNotifications
import Intents

@Observable
class InteractionData {
    var location = CGPoint(x: 0, y: 0)
    private var hideWorkItem: DispatchWorkItem?

    func scheduleHide(action: @escaping () -> Void) {
        // Cancel any existing work item
        hideWorkItem?.cancel()
        
        // Create a new work item
        let workItem = DispatchWorkItem {
            action()
        }
        
        // Store the new work item
        hideWorkItem = workItem
        
        // Schedule the new work item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }
}

struct ContentView: View {
    @Environment(AppState.self) var appState
    @State private var showSettings = false
    @State private var showStabilizationConfirmation = false
    @State private var showBatterySavingConfirmation = false
    @State private var showFocusAndExposureControl = false
    private let interactionData = InteractionData()
    private let streamer = Streamer.shared
    private let cameraMonitor = CameraMonitor.shared
    
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = height * (16.0/9.0)
            
            HStack(spacing: 0) {
                // 16:9 Content Area
                ZStack {
                    CameraMonitorView()
                        .onAppear {
                            streamer.startCamera()
                            print("Camera started")
                            Task {
                                appState.isStabilizationOn = await cameraMonitor.getCameraStabilization()
                            }
                        }
                    
                    WebOverlayView()
                    
                    HStack {
                        VStack(alignment: .leading) {
                            Spacer()
                            
                            Button(action: {
                                showSettings = true
                            }) {
                                Image(systemName: "gear")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white)
                                    .frame(width: 50, height: 50)
                            }
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(25)
                            .sheet(isPresented: $showSettings) {
                                SettingsView()
                            }.padding()
                        }
                        Spacer()
                    }
                    
                    VStack {
                        Spacer()
                        AudioLevelView()
                        SystemMetricsView()
                    }
                    .padding(.bottom, 3)
                    
                    // Controls now positioned relative to 16:9 frame
                    HStack {
                        Spacer()
                        
                        VStack(alignment: .trailing) {
                            Spacer()
                            
                            Button(action: {
                                if appState.isStreamActive {
                                    Task {
                                        appState.isStreamActive = false
                                        streamer.endStream()
                                        print("Stopped recording")
                                    }
                                } else {
                                    Task {
                                        streamer.startStream()
                                        appState.isStreamActive = true
                                        print("Started recording")
                                    }
                                }
                            }) {
                                Image(systemName: appState.isStreamActive ? "record.circle.fill" : "record.circle")
                                    .font(.system(size: 24))
                                    .foregroundColor(appState.isStreamActive ? .red : .white)
                                    .frame(width: 50, height: 50)
                            }
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(25)
                            .padding()
                            
                        }
                    }
                }
                .frame(width: width, height: height)
                
                // Vertical Small Button Column
                VStack(spacing: 2) {
                    SmallButton(imageName: appState.isStabilizationOn ? "hand.raised.fill" : "hand.raised.slash") {
                        showStabilizationConfirmation = true
                    }
                    .confirmationDialog("Change Image Stabilization?", isPresented: $showStabilizationConfirmation) {
                        Button(appState.isStabilizationOn ? "Turn Off" : "Turn On") {
                            appState.isStabilizationOn.toggle()
                            Task {
                                await cameraMonitor.setCameraStabilization(on: appState.isStabilizationOn)
                            }
                        }
                        Button("Cancel", role: .cancel) {} // Do nothing
                    } message: {
                        Text(appState.isStabilizationOn ? "Turning off image stabilization may result in shaky video." : "Turning on image stabilization may reduce battery life.")
                    }
                    Text("STBZN")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    SmallButton(imageName: appState.isBatterySavingOn ? "bolt.slash.fill" : "bolt.fill") {
                        showBatterySavingConfirmation = true
                    }
                    .confirmationDialog("Change Battery Saving Mode?", isPresented: $showBatterySavingConfirmation) {
                        Button(appState.isBatterySavingOn ? "Turn Off" : "Turn On") {
                            appState.isBatterySavingOn.toggle()
                            appState.isAudioLevelRunning = !appState.isBatterySavingOn
                            UIScreen.main.brightness = appState.isBatterySavingOn ? 0.1 : 1.0
                            print("Battery saving is \(appState.isBatterySavingOn ? "on" : "off")")
                        }
                        Button("Cancel", role: .cancel) {} // Do nothing
                    } message: {
                        Text(appState.isBatterySavingOn ? "Turning off battery saving will enable convenience features at the cost of higher battery consumption." : "Turning on battery saving will reduce everything not necessary for the streaming to a minimum.")
                    }
                    Text("PWRSV")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    SmallButton(imageName: appState.isExposureLocked ? "sun.max.fill" : "sun.max") {
                        appState.isExposureLocked.toggle()
                    }
                    Text("EXPSR")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    SmallButton(imageName: appState.isFocusLocked ? "viewfinder.circle.fill" : "viewfinder.circle") {
                        appState.isFocusLocked.toggle()
                    }
                    Text("FOCUS")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    Spacer() // Push buttons to the top
                }
                .frame(width: 30 + 10 * 2) // Width based on button size and padding
                .padding(.trailing, 10)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onTapGesture { location in
                interactionData.location = location
                Task {
                    await cameraMonitor.configureFocus(at: location)
                    await cameraMonitor.configureExposure(at: location)
                }
                showFocusAndExposureControl = true
                // Schedule hide with a method that cancels and reschedules
                interactionData.scheduleHide {
                    showFocusAndExposureControl = false
                }
            }
            
            if showFocusAndExposureControl {
                Rectangle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 25)
                    .position(interactionData.location)
                    .frame(width: 80, height: 80)
                Text("FOCUS")
                    .fontWeight(.black)
                    .font(.system(size: 16))
                    .foregroundColor(Color.white)
                    .position(x: interactionData.location.x, y: interactionData.location.y + 40)
            }
                
                /*
                // Exposure slider
                Slider(
                    value: Binding(
                        get: {
                            1.0
                            // viewModel.exposureBias
                        },
                        set: { newValue in
                           //  viewModel.exposureBias = newValue
                           //  viewModel.configureExposure(bias: newValue)
                        }
                    ),
                    in: -1.0...1.0
                )
                .accentColor(.white)
                .frame(width: 150)
                 */
        }
        .edgesIgnoringSafeArea(.all)
        .persistentSystemOverlays(.hidden)
        .onChange(of: appState.justCameFromBackground) { oldValue, newValue in
            if newValue && appState.hadToStopStreaming {
                let content = UNMutableNotificationContent()
                content.title = "App resumed from background"
                content.body = "The stream had to be stopped because the app was put into background."
                
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
                
                appState.justCameFromBackground = false
                appState.hadToStopStreaming = false
            }
        }
    }
}

// Helper View for Small Buttons
struct SmallButton: View {
    let imageName: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: imageName)
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
        }
        .background(Color.black)
    }
}

