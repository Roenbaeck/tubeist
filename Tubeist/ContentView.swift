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
    @State private var overlayManager = OverlaySettingsManager()
    @State private var showSettings = false
    @State private var showStabilizationConfirmation = false
    @State private var showBatterySavingConfirmation = false
    @State private var showFocusAndExposureArea = false
    @State private var showCameraPicker = false
    @State private var showStabilizationPicker = false
    @State private var showJournal = false
    @State private var enableFocusAndExposureTap = false
    @State private var isSettingsPresented = false
    @State private var currentZoom = 0.0
    @State private var totalZoom = 1.0
    @State private var minZoom = 1.0
    @State private var maxZoom = 1.0
    @State private var opticalZoom = 1.0
    @State private var selectedCamera = DEFAULT_CAMERA
    @State private var selectedStabilization = "Off"
    @State private var cameras: [String] = []
    @State private var stabilizations: [String] = []
    private let interactionData = InteractionData()
    
    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                currentZoom = value.magnification - 1
                let zoomDelta = totalZoom * currentZoom
                let safeZoom = max(minZoom, min(zoomDelta + totalZoom, maxZoom))
                Task {
                    await CameraMonitor.shared.setZoomFactor(safeZoom)
                }
                currentZoom = safeZoom - totalZoom
            }
            .onEnded { value in
                totalZoom += currentZoom
                totalZoom = max(minZoom, min(totalZoom, maxZoom))
                Task {
                    await CameraMonitor.shared.setZoomFactor(totalZoom)
                }
                currentZoom = 0
            }
    }
    
    func getCameraProperties() {
        Task {
            selectedStabilization = await CameraMonitor.shared.getCameraStabilization()
            appState.isStabilizationOn = selectedStabilization != "Off"
            minZoom = await CameraMonitor.shared.getMinZoomFactor()
            maxZoom = await min(CameraMonitor.shared.getMaxZoomFactor(), ZOOM_LIMIT)
            opticalZoom = await CameraMonitor.shared.getOpticalZoomFactor()
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = height * (16.0/9.0)
            
            HStack(spacing: 0) {
                // 16:9 Content Area
                ZStack {
                    CameraMonitorView()
                        .id(appState.cameraMonitorId)
                        .gesture(magnification)
                        .frame(width: width, height: height)
                        .onAppear {
                            Task {
                                await Streamer.shared.startCamera()
                                appState.refreshCameraView()
                                getCameraProperties()
                            }
                        }
                        .onDisappear {
                            Task {
                                await Streamer.shared.stopCamera()
                            }
                        }

                    ForEach(overlayManager.overlays) { overlay in
                        if let url = URL(string: overlay.url) {
                            OverlayView(url: url)
                                .opacity(appState.areOverlaysHidden ? 0 : 1)
                                .onDisappear {
                                    OverlayBundler.shared.removeOverlay(url: url)
                                }
                        }
                    }

                    if appState.activeMonitor == .output {
                        OutputMonitorView()
                    }
                    
                    if showJournal {
                        JournalView()
                    }
                    
                    VStack {
                        Spacer()
                        if !showJournal {
                            SystemMetricsView()
                                .offset(y: 3)
                        }
                        CoreGraphicsAudioMeter(width: width, height: AUDIO_METER_HEIGHT)
                            .frame(width: width, height: AUDIO_METER_HEIGHT)
                    }

                    VStack(spacing: 0) {
                        Spacer()

                        if showCameraPicker {
                            HStack(alignment: .center, spacing: 10) {
                                Spacer()
                                
                                Text("Select Camera")
                                Picker("Camera Selection", selection: $selectedCamera) {
                                    ForEach(cameras, id: \.self) { camera in
                                        Text(camera)
                                            .tag(camera)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.black.opacity(0.5))
                                )
                                .onChange(of: selectedCamera) { _, newCamera in
                                    LOG("Seletected camera: \(newCamera)", level: .debug)
                                    Settings.selectedCamera = newCamera
                                    Task {
                                        await Streamer.shared.cycleCamera()
                                    }
                                }
                            }
                            .padding(5)
                            .background(
                                Rectangle()
                                    .fill(Color.black.opacity(0.2))
                            )
                        }
                        if showStabilizationPicker {
                            HStack(alignment: .center, spacing: 10) {
                                Spacer()
                                
                                Text("Select Stabilization Mode")
                                Picker("Stabilization Selection", selection: $selectedStabilization) {
                                    ForEach(stabilizations, id: \.self) { stabilization in
                                        Text(stabilization)
                                            .tag(stabilization)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.black.opacity(0.5))
                                )
                                .onChange(of: selectedStabilization) { _, newStabilization in
                                    LOG("Seletected stabilization: \(newStabilization)", level: .debug)
                                    Task {
                                        await CameraMonitor.shared.setCameraStabilization(to: newStabilization)
                                        appState.isStabilizationOn = newStabilization != "Off"
                                    }
                                }
                            }
                            .padding(5)
                            .background(
                                Rectangle()
                                    .fill(Color.black.opacity(0.2))
                            )
                        }
                        
                        Spacer()
                    }
                    
                    // Controls now positioned relative to 16:9 frame
                    HStack {
                        Spacer()
                        
                        VStack(alignment: .center, spacing: 0) {

                            Button(action: {
                                if(!appState.isStreamActive) {
                                    showSettings = true
                                }
                            }) {
                                Image(systemName: "gear")
                                    .font(.system(size: 24))
                                    .foregroundColor(appState.isStreamActive ? .yellow.opacity(0.5) : .white)
                                    .frame(width: 50, height: 50)
                            }
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(25)
                            .sheet(isPresented: $showSettings) {
                                SettingsView(overlayManager: overlayManager)
                            }
                            .padding(.bottom, 10)
                            
                            let zoom = totalZoom + currentZoom
                            
                            Text(String(format: zoom == 1 || zoom > 10 ? "%.0f" : "%.1f", zoom) + "x")
                                .font(.system(size: 17))
                                .fontWeight(.semibold)
                                .foregroundColor(zoom > opticalZoom ? .yellow : zoom > 1 ? .white : .white.opacity(0.5))
                            
                            Spacer()

                            // Computed property to determine the color based on streamHealth
                            var streamHealthColor: Color {
                                switch appState.streamHealth {
                                case .silenced:
                                    return .white.opacity(0.5)
                                case .awaiting:
                                    return .white
                                case .unusable:
                                    return .red
                                case .degraded:
                                    return .yellow
                                case .pristine:
                                    return .green
                                }
                            }
                            
                            Image(systemName: "dot.radiowaves.right")
                                .rotationEffect(.degrees(-90)) // Rotate the symbol by 90 degrees
                                .foregroundColor(streamHealthColor)
                                .font(.system(size: 25)) // Adjust the size as needed
                                .padding(.bottom, 10)
                            
                            Button(action: {
                                if appState.isStreamActive {
                                    Task {
                                        await Streamer.shared.endStream()
                                        LOG("Stopped recording", level: .info)
                                    }
                                } else {
                                    Task {
                                        await Streamer.shared.startStream()
                                        LOG("Started recording", level: .info)
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
                            
                        }
                        .padding()
                    }
                }
                .frame(width: width, height: height)
                
                // Vertical Small Button Column
                VStack(spacing: 2) {

                    Spacer()

                    SmallButton(imageName: appState.isBatterySavingOn ? "sunrise.fill" : "sunset") {
                        showBatterySavingConfirmation = true
                    }
                    .confirmationDialog("Change Battery Saving Mode?", isPresented: $showBatterySavingConfirmation) {
                        Button(appState.isBatterySavingOn ? "Turn Off" : "Turn On") {
                            appState.isBatterySavingOn.toggle()
                            appState.isAudioLevelRunning = !appState.isBatterySavingOn
                            UIScreen.main.brightness = appState.isBatterySavingOn ? 0.1 : 1.0
                            LOG("Battery saving is \(appState.isBatterySavingOn ? "on" : "off")", level: .info)
                        }
                        Button("Cancel", role: .cancel) {} // Do nothing
                    } message: {
                        Text(appState.isBatterySavingOn ? "Turning off battery saving will enable convenience features at the cost of higher battery consumption." : "Turning on battery saving will reduce everything not necessary for the streaming to a minimum.")
                    }
                    Text("PWRSV")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)
                    
                    SmallButton(imageName: "camera", foregroundColor: appState.isStreamActive ? .yellow : .white) {
                        if(!appState.isStreamActive) {
                            showCameraPicker.toggle()
                            if showCameraPicker && showStabilizationPicker {
                                showStabilizationPicker = false
                            }
                        }
                    }
                    
                    Text("CAMRA")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    SmallButton(imageName: appState.isStabilizationOn ? "hand.raised.fill" : "hand.raised.slash") {
                        Task {
                            stabilizations = await CameraMonitor.shared.getStabilizations()
                            showStabilizationPicker.toggle()
                            if showStabilizationPicker && showCameraPicker {
                                showCameraPicker = false
                            }
                        }
                    }
                    Text("STBZN")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    SmallButton(imageName: appState.isFocusLocked ? "viewfinder.circle.fill" : "viewfinder.circle",
                                foregroundColor: appState.isFocusLocked ? .yellow : .white) {
                        appState.isFocusLocked.toggle()
                        enableFocusAndExposureTap = appState.isExposureLocked || appState.isFocusLocked
                        if !appState.isFocusLocked {
                            Task {
                                await CameraMonitor.shared.setAutoFocus()
                            }
                        }
                    }
                    Text("FOCUS")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    SmallButton(imageName: appState.isExposureLocked ? "sun.max.fill" : "sun.max",
                                foregroundColor: appState.isExposureLocked ? .yellow : .white) {
                        appState.isExposureLocked.toggle()
                        enableFocusAndExposureTap = appState.isExposureLocked || appState.isFocusLocked
                        if !appState.isExposureLocked {
                            Task {
                                await CameraMonitor.shared.setAutoExposure()
                            }
                        }
                    }
                    Text("EXPSR")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    SmallButton(imageName: appState.isWhiteBalanceLocked ? "square.and.arrow.down.fill" : "square.and.arrow.down",
                                foregroundColor: appState.isWhiteBalanceLocked ? .yellow : .white) {
                        appState.isWhiteBalanceLocked.toggle()
                        if appState.isWhiteBalanceLocked {
                            Task {
                                await CameraMonitor.shared.lockWhiteBalance()
                            }
                        }
                        else {
                            Task {
                                await CameraMonitor.shared.setAutoWhiteBalance()
                            }
                        }
                        
                         
                    }
                    Text("WHITE")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    SmallButton(imageName: appState.areOverlaysHidden ? "rectangle.on.rectangle" : "rectangle.on.rectangle.fill",
                                foregroundColor: appState.areOverlaysHidden ? .yellow : .white) {
                        appState.areOverlaysHidden.toggle()
                        Settings.hideOverlays = appState.areOverlaysHidden
                        OverlayBundler.shared.refreshCombinedImage()
                    }
                    Text(appState.areOverlaysHidden ? "HIDDN" : "OVRLY")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    SmallButton(imageName: "text.quote", foregroundColor: showJournal ? .yellow : .white) {
                        showJournal.toggle()
                    }
                    Text("JORNL")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    Spacer()
                }
                .frame(width: 30) // Width based on button size and padding
                .padding(.leading, 10)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onTapGesture { location in
                if enableFocusAndExposureTap {
                    interactionData.location = location
                    Task {
                        if appState.isExposureLocked { await CameraMonitor.shared.setExposure(at: location) }
                        if appState.isFocusLocked { await CameraMonitor.shared.setFocus(at: location) }
                    }
                    showFocusAndExposureArea = true
                    // Schedule hide with a method that cancels and reschedules
                    interactionData.scheduleHide {
                        showFocusAndExposureArea = false
                    }
                }
            }
            
            if showFocusAndExposureArea {
                Rectangle()
                    .stroke(Color.white.opacity(0.5), lineWidth: 25)
                    .position(interactionData.location)
                    .frame(width: 80, height: 80)
                if appState.isExposureLocked {
                    Text("EXPOSURE")
                        .fontWeight(.black)
                        .font(.system(size: 14))
                        .foregroundColor(Color.white)
                        .position(x: interactionData.location.x, y: interactionData.location.y - 40)
                }
                if appState.isFocusLocked {
                    Text("FOCUS")
                        .fontWeight(.black)
                        .font(.system(size: 14))
                        .foregroundColor(Color.white)
                        .position(x: interactionData.location.x, y: interactionData.location.y + 40)
                }
            }
                
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
                
                appState.hadToStopStreaming = false
            }
            if newValue {
                appState.justCameFromBackground = false
            }
        }
        .onAppear {
            selectedCamera = Settings.selectedCamera
            selectedStabilization = Settings.cameraStabilization ?? "Off"
            Task {
                cameras = await CameraMonitor.shared.getCameras()
            }
        }
    }

    func loadOverlaysFromStorage() -> [OverlaySetting] {
        guard let overlaysData = Settings.overlaysData,
              let decodedOverlays = try? JSONDecoder().decode([OverlaySetting].self, from: overlaysData) else {
            return []
        }
        return decodedOverlays
    }
}

// Helper View for Small Buttons
struct SmallButton: View {
    let imageName: String
    let action: () -> Void
    let foregroundColor: Color?  // New optional parameter
    
    // Initialize with an optional color parameter that defaults to nil
    init(imageName: String, foregroundColor: Color? = nil, action: @escaping () -> Void) {
        self.imageName = imageName
        self.foregroundColor = foregroundColor
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: imageName)
                .font(.system(size: 20))
                .foregroundColor(foregroundColor ?? .white)  // Use provided color or default to white
                .frame(width: 30, height: 30)
        }
        .background(Color.black)
    }
}

