//
//  TubeistView.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

import SwiftUI
import UserNotifications
import Intents

@Observable @MainActor
class Interaction {
    var location = CGPoint(x: 0, y: 0)
    private var actionTask: Task<Void, Never>?
    
    func scheduleAction(seconds: Double = 3.0, action: @escaping () -> Void) {
        actionTask?.cancel()
        actionTask = Task(priority: .utility) { @MainActor in
            do {
                try await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled {
                    action()
                }
            } catch {
                // this is where we end up when actionTask?.cancel() actually cancels a Task
            }
        }
    }
}

// different views for the iPhone display
enum Monitor {
    case camera
    case output
}

struct TubeistView: View {
    @Environment(AppState.self) var appState
    @State private var overlayManager = OverlaySettingsManager()
    @State private var showSettings = false
    @State private var showStabilizationConfirmation = false
    @State private var showBatterySavingConfirmation = false
    @State private var showFocusAndExposureArea = false
    @State private var showCameraPicker = false
    @State private var showStylingPicker = false
    @State private var showStabilizationPicker = false
    @State private var showJournal = false
    @State private var enableFocusAndExposureTap = false
    @State private var isSettingsPresented = false
    @State private var currentZoom = 0.0
    @State private var totalZoom = 1.0
    @State private var minZoom = 1.0
    @State private var maxZoom = 1.0
    @State private var opticalZoom = 1.0
    @State private var exposureBias: Float = 0.0
    @State private var lensPosition: Float = 1.0
    @State private var selectedCamera = DEFAULT_CAMERA
    @State private var selectedStabilization = "Off"
    @State private var cameras: [String] = []
    @State private var stabilizations: [String] = []
    @State private var style: String = Settings.style ?? NO_STYLE
    @State private var styleStrength: Float = 1.0
    @State private var effect: String = Settings.effect ?? NO_EFFECT
    @State private var effectStrength: Float = 1.0
    
    @State private var interaction = Interaction()
    @State private var isCameraReady = false
    @State private var showSplashScreen = true
    @State private var splashOpacity: Double = 1.0
    @State private var fadeMessage: String?
    @State private var fading: Bool = false
    
    @State private var startMagnification: CGFloat?
    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if startMagnification == nil {
                    startMagnification = value.magnification
                }
                currentZoom = value.magnification - (startMagnification ?? 1.0)
                let zoomDelta = totalZoom * currentZoom
                let safeZoom = max(minZoom, min(zoomDelta + totalZoom, maxZoom))
                Task {
                    await CaptureDirector.shared.setZoomFactor(safeZoom)
                }
                currentZoom = safeZoom - totalZoom
            }
            .onEnded { value in
                totalZoom += currentZoom
                totalZoom = max(minZoom, min(totalZoom, maxZoom))
                Task {
                    await CaptureDirector.shared.setZoomFactor(totalZoom)
                }
                currentZoom = 0
                startMagnification = nil
            }
    }
    
    func fade(_ message: String) {
        LOG(message, level: .debug)
        fading = false
        fadeMessage = message
        var transaction = Transaction(animation: .easeInOut(duration: 2.0).delay(1.0))
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            fading = true
            fadeMessage = nil
        }
    }
    
    func updateCameraProperties() {
        Task {
            // Passing Binding<variable> to a singleton is fine
            await CaptureDirector.shared.bind(
                totalZoom: $totalZoom,
                currentZoom: $currentZoom,
                exposureBias: $exposureBias,
                style: $style,
                effect: $effect
            )
            selectedStabilization = Settings.cameraStabilization ?? "Off"
            appState.isStabilizationOn = selectedStabilization != "Off"
            minZoom = await CaptureDirector.shared.getMinZoomFactor()
            maxZoom = await min(CaptureDirector.shared.getMaxZoomFactor(), ZOOM_LIMIT)
            opticalZoom = await CaptureDirector.shared.getOpticalZoomFactor()
            let safeZoom = max(minZoom, min(totalZoom, maxZoom))
            await CaptureDirector.shared.setZoomFactor(safeZoom)
        }
    }
    
    func focusAndExposureTap(_ location: CGPoint) {
        interaction.location = location
        Task {
            guard let previewLayer = CameraMonitorView.previewLayer else {
                LOG("Cannot determine tap location because the preview layer is unavailable", level: .debug)
                return
            }
            let normalizedLocation = previewLayer.captureDevicePointConverted(fromLayerPoint: location)
            if appState.isExposureLocked {
                await CaptureDirector.shared.setExposure(at: normalizedLocation)
                LOG("Probing exposure at \(location)", level: .debug)
            }
            if appState.isFocusLocked {
                await CaptureDirector.shared.setFocus(at: normalizedLocation)
                LOG("Probing focus at \(location)", level: .debug)
            }
        }
        showFocusAndExposureArea = true
        // Schedule hide with a method that cancels and reschedules
        interaction.scheduleAction {
            showFocusAndExposureArea = false
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = height * (16.0/9.0)
            
            HStack(spacing: 0) {
                Spacer()
                // 16:9 Content Area
                ZStack {
                    CameraMonitorView()
                        .id(appState.cameraMonitorId)
                        .gesture(magnification)
                        .frame(width: width, height: height)
                        .onAppear {
                            Task {
                                await CameraMonitorView.createPreviewLayer()
                                await Streamer.shared.startSessions()
                                appState.refreshCameraView()
                                updateCameraProperties()
                                isCameraReady = true
                                LOG("Viewing camera monitor", level: .debug)
                            }
                        }
                        .onDisappear {
                            Task {
                                await Streamer.shared.stopSessions()
                            }
                        }
                        .onChange(of: appState.cameraMonitorId) {
                            updateCameraProperties()
                        }
                        .onCameraCaptureEvent() { event in
                            if event.phase == .ended {
                                Task {
                                    await Streamer.shared.toggleBatterySaving()
                                }
                            }
                        }
                        .onTapGesture { location in
                            if enableFocusAndExposureTap {
                                focusAndExposureTap(location)
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
                    
                    if showSplashScreen {
                        ZStack {
                            Image("SplashScreen")
                                .resizable()
                                .frame(width: width, height: height)
                                .scaledToFill()
                            Text("Hiding some ugly looking device setup...")
                                .font(.system(size: 12))
                                .offset(y: 30)
                        }
                        .opacity(splashOpacity) // Apply the opacity
                        .onChange(of: isCameraReady) { _, newValue in
                            if newValue {
                                withAnimation(.easeInOut(duration: 2.0)) {
                                    splashOpacity = 0.0
                                } completion: {
                                    showSplashScreen = false // Hide the splash screen after animation
                                }
                            }
                        }
                    }
                    
                    if appState.activeMonitor == .output {
                        OutputMonitorView()
                            .id(appState.outputMonitorId)
                            .gesture(magnification)
                            .frame(width: width, height: height)
                            .onAppear {
                                Task {
                                    OutputMonitorView.createDisplayLayer()
                                    appState.refreshOutputView()
                                    LOG("Viewing output monitor", level: .debug)
                                }
                            }
                            .onTapGesture { location in
                                if enableFocusAndExposureTap {
                                    focusAndExposureTap(location)
                                }
                            }
                    }
                    
                    if showFocusAndExposureArea {
                        FocusExposureIndicator(
                            position: interaction.location,
                            isExposureLocked: appState.isExposureLocked,
                            isFocusLocked: appState.isFocusLocked
                        )
                    }
                    
                    if showJournal {
                        JournalView()
                            .frame(width: width, height: height)
                            .fixedSize()
                    }
                    
                    VStack {
                        Spacer()
                        if appState.isBatterySavingOn {
                            Text("BATTERY SAVING MODE")
                                .font(.system(size: 30))
                                .foregroundColor(Color.yellow)
                                .fontWeight(.black)
                        }
                        if let message = fadeMessage {
                            Text(message)
                                .fontWeight(.bold)
                                .font(.system(size: 24))
                                .foregroundColor(ULTRAYELLOW)
                                .opacity(fading ? 0 : 1)
                                .animation(.easeInOut(duration: 0.5), value: message)
                        }
                        SystemMetricsView()
                            .offset(y: 3)
                            .opacity(showJournal ? 0 : 1)
                        AudioMonitorView(width: width, height: AUDIO_METER_HEIGHT)
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
                                        .fill(Color.black.opacity(0.6))
                                )
                                .onChange(of: selectedCamera) { _, newCamera in
                                    LOG("Seletected camera: \(newCamera)", level: .debug)
                                    Settings.selectedCamera = newCamera
                                    Task {
                                        await Streamer.shared.cycleSessions()
                                    }
                                }
                            }
                            .padding(5)
                            .background(
                                Rectangle()
                                    .fill(Color.black.opacity(0.4))
                            )
                            
                            HStack(alignment: .center, spacing: 10) {
                                Spacer()
                                
                                Text("Select Monitor")
                                Picker("Monitor Selection", selection: Binding(
                                    get: { appState.activeMonitor },
                                    set: { appState.activeMonitor = $0 }
                                )) {
                                    Text("Camera (view without delay, not styled)").tag(Monitor.camera)
                                    Text("Output (viewing is delayed, but styled)").tag(Monitor.output)
                                }
                                .pickerStyle(MenuPickerStyle())
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.black.opacity(0.6))
                                )
                            }
                            .padding(5)
                            .background(
                                Rectangle()
                                    .fill(Color.black.opacity(0.4))
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
                                        .fill(Color.black.opacity(0.6))
                                )
                                .onChange(of: selectedStabilization) { _, newStabilization in
                                    Task {
                                        await CaptureDirector.shared.setCameraStabilization(to: newStabilization)
                                        appState.refreshCameraView()
                                        appState.isStabilizationOn = newStabilization != "Off"
                                    }
                                }
                            }
                            .padding(5)
                            .background(
                                Rectangle()
                                    .fill(Color.black.opacity(0.4))
                            )
                        }
                        if showStylingPicker {
                            HStack(alignment: .center, spacing: 10) {
                                Spacer()
                                
                                Text("Select Style")
                                Picker("Style Selection", selection: $style) {
                                    ForEach(AVAILABLE_STYLES, id: \.self) { style in
                                        Text(style)
                                            .tag(style)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.black.opacity(0.6))
                                )
                                .onAppear {
                                    style = Settings.style ?? NO_STYLE
                                    if appState.activeMonitor == .camera {
                                        fade("Switch to output viev to preview styling")
                                    }
                                }
                                .onChange(of: style) { _, newStyle in
                                    LOG("Seletected style: \(newStyle)", level: .debug)
                                    Settings.style = newStyle
                                    Task {
                                        await FrameGrabber.shared.refreshStyle()
                                    }
                                }
                            }
                            .padding(5)
                            .background(
                                Rectangle()
                                    .fill(Color.black.opacity(0.4))
                            )
                            
                            HStack(alignment: .center, spacing: 10) {
                                Spacer()
                                
                                Text("Select Effect")
                                Picker("Effect Selection", selection: $effect) {
                                    ForEach(AVAILABLE_EFFECTS, id: \.self) { effect in
                                        Text(effect)
                                            .tag(effect)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.black.opacity(0.6))
                                )
                                .onAppear {
                                    effect = Settings.effect ?? NO_EFFECT
                                }
                                .onChange(of: effect) { _, newEffect in
                                    LOG("Seletected effect: \(newEffect)", level: .debug)
                                    Settings.effect = newEffect
                                    Task {
                                        await FrameGrabber.shared.refreshEffect()
                                    }
                                }
                            }
                            .padding(5)
                            .background(
                                Rectangle()
                                    .fill(Color.black.opacity(0.4))
                            )
                        }
                        
                        Spacer()
                    }
                    
                    if appState.activeMonitor == .output {
                        HStack {
                            VStack {
                                Spacer()
                                Text("OUTPUT MONITORING")
                                    .font(.system(size: 10))
                                    .foregroundColor(BRIGHTER_THAN_WHITE)
                                    .fontWeight(.black)
                                    .rotationEffect(.degrees(-90))
                                    .fixedSize()
                                    .frame(width: 15)
                                    .padding(3)
                                Spacer()
                            }
                            Spacer()
                        }
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
                            
                            Text(String(format: zoom == 1 || zoom > 10 ? "%.0f" : "%.1f", zoom) + "×")
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
                                        LOG("Stopped streaming engine", level: .info)
                                    }
                                } else {
                                    if Settings.hasCameraPermission() && Settings.hasMicrophonePermission() {
                                        Task {
                                            showCameraPicker = false
                                            await Streamer.shared.startStream()
                                            LOG("Started streaming engine", level: .info)
                                        }
                                    }
                                    else {
                                        Settings.openSystemSettings()
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
                    .opacity(1 - splashOpacity) // Invert opacity of the splash screen
                    .disabled(showSplashScreen)
                }
                .frame(width: width, height: height)
                
                // Vertical Small Button Column
                VStack {
                    
                    SmallButton(imageName: appState.isBatterySavingOn ? "sunrise.fill" : "sunset",
                                foregroundColor: appState.isBatterySavingOn ? .yellow : .white) {
                        showBatterySavingConfirmation = true
                    }
                                .confirmationDialog("Change Battery Saving Mode?", isPresented: $showBatterySavingConfirmation) {
                                    Button(appState.isBatterySavingOn ? "Turn Off" : "Turn On") {
                                        Task {
                                            await Streamer.shared.toggleBatterySaving()
                                        }
                                    }
                                    Button("Cancel", role: .cancel) {} // Do nothing
                                } message: {
                                    Text(appState.isBatterySavingOn ? "Turning off battery saving will enable convenience features at the cost of higher battery consumption." : "Turning on battery saving will reduce everything not necessary for the streaming to a minimum.")
                                }
                    
                    SmallButton(imageName: appState.isStreamActive ? "camera.fill" : "camera",
                                foregroundColor: appState.isStreamActive || showCameraPicker ? .yellow : .white) {
                        if !appState.isStreamActive {
                            showCameraPicker.toggle()
                            if showCameraPicker && showStabilizationPicker {
                                showStabilizationPicker = false
                            }
                        }
                    }
                    
                    SmallButton(imageName: appState.isStabilizationOn ? "hand.raised.fill" : "hand.raised.slash",
                                foregroundColor: showStabilizationPicker ? .yellow : .white) {
                        Task {
                            stabilizations = await CaptureDirector.shared.getStabilizations()
                            showStabilizationPicker.toggle()
                            if showStabilizationPicker && showCameraPicker {
                                showCameraPicker = false
                            }
                        }
                    }
                    
                    SmallButton(imageName: appState.activeMonitor == .output ? "square.and.line.vertical.and.square.filled" : "square.filled.and.line.vertical.and.square",
                                foregroundColor: appState.activeMonitor == .output ? .yellow : .white) {
                        appState.activeMonitor = switch appState.activeMonitor {
                        case .output: .camera
                        case .camera: .output
                        }
                        fade("Switching to \(appState.activeMonitor) monitor")
                    }
                    
                    SmallButton(imageName: "camera.filters",
                                foregroundColor: Purchaser.shared.isProductPurchased("tubeist_lifetime_styling") ? showStylingPicker ? .yellow : .white : .red) {
                        if Purchaser.shared.isProductPurchased("tubeist_lifetime_styling") {
                            showStylingPicker.toggle()
                        }
                    }
                    
                    SmallButton(imageName: appState.isFocusLocked ? "viewfinder.circle.fill" : "viewfinder.circle",
                                foregroundColor: appState.isFocusLocked ? .yellow : .white) {
                        appState.isFocusLocked.toggle()
                        enableFocusAndExposureTap = appState.isExposureLocked || appState.isFocusLocked
                        if appState.isFocusLocked {
                            fade("Focus locked: tap to set focus")
                            Task {
                                await CaptureDirector.shared.lockFocus()
                            }
                        }
                        else {
                            fade("Focus unlocked: autofocusing")
                            Task {
                                await CaptureDirector.shared.autoFocus()
                            }
                        }
                    }
                    
                    SmallButton(imageName: appState.isExposureLocked ? "sun.max.fill" : "sun.max",
                                foregroundColor: appState.isExposureLocked ? .yellow : .white) {
                        appState.isExposureLocked.toggle()
                        enableFocusAndExposureTap = appState.isExposureLocked || appState.isFocusLocked
                        if appState.isExposureLocked {
                            fade("Exposure locked: tap to set exposure")
                            Task {
                                await CaptureDirector.shared.lockExposure()
                            }
                        }
                        else {
                            fade("Exposure unlocked: automatic exposure")
                            Task {
                                await CaptureDirector.shared.autoExposure()
                            }
                        }
                    }
                    
                    SmallButton(imageName: appState.isWhiteBalanceLocked ? "lightbulb.fill" : "lightbulb",
                                foregroundColor: appState.isWhiteBalanceLocked ? .yellow : .white) {
                        appState.isWhiteBalanceLocked.toggle()
                        if appState.isWhiteBalanceLocked {
                            fade("White balance locked at current value")
                            Task {
                                await CaptureDirector.shared.lockWhiteBalance()
                            }
                        }
                        else {
                            fade("Automatically adjusted white balance")
                            Task {
                                await CaptureDirector.shared.autoWhiteBalance()
                            }
                        }
                    }
                    
                    SmallButton(imageName: appState.areOverlaysHidden ? "rectangle.on.rectangle" : "rectangle.on.rectangle.fill",
                                foregroundColor: appState.areOverlaysHidden ? .yellow : .white) {
                        appState.areOverlaysHidden.toggle()
                        fade(appState.areOverlaysHidden ? "Overlays are now hidden" : "Overlays are now visible")
                        Settings.hideOverlays = appState.areOverlaysHidden
                        OverlayBundler.shared.refreshCombinedImage()
                    }
                    
                    SmallButton(imageName: "text.quote",
                                foregroundColor: showJournal ? .yellow : Journal.publisher.hasErrors ? .red : .white) {
                        showJournal.toggle()
                    }
                }
                .frame(width: 30) // Width based on button size and padding
                .padding(.leading, 10)
                .opacity(1 - splashOpacity) // Invert opacity of the splash screen
                .disabled(showSplashScreen)

                VStack {
                    if appState.isExposureLocked {
                        CameraControlSlider(
                            value: $exposureBias,
                            range: -2.0...2.0,
                            step: 0.1,
                            format: "%+.1f\u{202F}EV"
                        )
                        .frame(height: geometry.size.height * 0.50)
                        .padding(.leading, 10)
                        .onChange(of: exposureBias) { _, newValue in
                            Task {
                                await CaptureDirector.shared.setExposureBias(to: newValue)
                            }
                        }
                    }
                    else if appState.isFocusLocked {
                        CameraControlSlider(
                            value: $lensPosition,
                            range: 0...1.0,
                            step: 0.02,
                            format: "%+.2f"
                        )
                        .frame(height: geometry.size.height * 0.50)
                        .padding(.leading, 10)
                        .onChange(of: lensPosition) { _, newValue in
                            Task {
                                await CaptureDirector.shared.setLensPosition(to: newValue)
                            }
                        }
                    }
                    else if style != NO_STYLE || effect != NO_EFFECT {
                        VStack {
                            HStack {
                                Image(systemName: "camera.filters")
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                    .padding(.leading, 15)
                                    .foregroundColor(.yellow)
                                Spacer()
                            }
                            if style != NO_STYLE {
                                CameraControlSlider(
                                    value: $styleStrength,
                                    range: -1.0...1.0,
                                    step: 0.1,
                                    format: "%+.1f\u{202F}ST"
                                )
                                .frame(height: geometry.size.height * 0.33)
                                .padding(.leading, 10)
                                .padding(.bottom, 15)
                                .onChange(of: styleStrength) { _, newValue in
                                    Task {
                                        await FrameGrabber.shared.setStyleStrength(to: newValue)
                                    }
                                }
                            }
                            if effect != NO_EFFECT {
                                CameraControlSlider(
                                    value: $effectStrength,
                                    range: -1.0...1.0,
                                    step: 0.1,
                                    format: "%+.1f\u{202F}EF"
                                )
                                .frame(height: geometry.size.height * 0.33)
                                .padding(.leading, 10)
                                .padding(.bottom, 15)
                                .onChange(of: effectStrength) { _, newValue in
                                    Task {
                                        await FrameGrabber.shared.setEffectStrength(to: newValue)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(width: 64) // Must be 64 or larger to register drag gesture
                .opacity(1 - splashOpacity) // Invert opacity of the splash screen
                .disabled(showSplashScreen)
            }
        }
        .edgesIgnoringSafeArea(.all)
        .persistentSystemOverlays(.hidden)
        .onChange(of: appState.isBatterySavingOn) { oldValue, newValue in
            appState.isAudioLevelRunning = !appState.isBatterySavingOn
            if newValue {
                appState.lastKnownBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = BATTERY_SAVING_BRIGHTNESS
            }
            else {
                UIScreen.main.brightness = appState.lastKnownBrightness
            }
            LOG("Battery saving is \(appState.isBatterySavingOn ? "on" : "off")", level: .debug)
        }
        .onChange(of: appState.justCameFromBackground) { oldValue, newValue in
            if newValue && appState.hadToStopStreaming {
                let content = UNMutableNotificationContent()
                content.title = "App resumed from background"
                content.body = "The stream had to be stopped because the app was put into background."
                
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
                
                appState.hadToStopStreaming = false
            }
        }
        .onChange(of: appState.activeMonitor) { _, newMonitor in
            Task {
                await Streamer.shared.setMonitor(newMonitor)
            }
        }
        .onAppear {
            selectedCamera = Settings.selectedCamera
            selectedStabilization = Settings.cameraStabilization ?? "Off"
            Task {
                cameras = await CaptureDirector.shared.getCameras()
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

struct FocusExposureIndicator: View {
    let position: CGPoint
    let isExposureLocked: Bool
    let isFocusLocked: Bool
    
    @State private var scale: CGFloat = 1.2
    @State private var opacity: Double = 1.0
    
    var body: some View {
        ZStack {
            // Corner elements
            ForEach(0..<4) { index in
                Path { path in
                    let isTop = index < 2
                    let isLeft = index % 2 == 0
                    let x = isLeft ? 0 : 80
                    let y = isTop ? 0 : 80
                    
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(
                        x: x + (isLeft ? 20 : -20),
                        y: y
                    ))
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(
                        x: x,
                        y: y + (isTop ? 20 : -20)
                    ))
                }
                .stroke(Color.yellow, lineWidth: 2)
            }
            
            // Center crosshair
            Circle()
                .fill(Color.yellow)
                .frame(width: 4, height: 4)
            
            // Labels
            if isExposureLocked {
                Text("EXPSR")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .offset(y: -54)
            }
            
            if isFocusLocked {
                Text("FOCUS")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .offset(y: 54)
            }
        }
        .frame(width: 80, height: 80)
        .position(position)
        .scaleEffect(scale)
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.3)) {
                scale = 1.0
            }
        }
        .onDisappear {
            withAnimation(.easeOut.delay(1.5)) {
                opacity = 0
            }
        }
    }
}

struct CameraControlSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Double>
    var step: Double
    var format: String?
    
    var body: some View {
        VStack(spacing: 0) {
            if format != nil {
                HStack {
                    Text("\(String(format: format!, value))")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundColor(.yellow)
                    Spacer()
                }
            }
            
            GeometryReader { geometry in
                let stepSize = geometry.size.height / Double(range.upperBound - range.lowerBound)
                let zero = geometry.size.height * (range.upperBound / (range.upperBound - range.lowerBound))
                
                ZStack(alignment: .leading) { // Align ZStack to the leading edge
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 16))
                        .fontWeight(.bold)
                        .foregroundColor(.yellow)
                        .offset(x: 15, y: zero - CGFloat(value) * stepSize - 0.5)
                        .padding(2)
                    
                    // Scale Markers
                    ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: step)), id: \.self) { position in
                        let atValue = Int((position * 100).rounded()) == Int((value * 100).rounded())
                        let width: CGFloat = {
                            switch Int((position * 100).rounded()) % 100 {
                            case 0:
                                return 8
                            case -50, 50:
                                return 5
                            default:
                                return 2
                            }
                        }()
                        HStack {
                            Rectangle()
                                .fill(atValue ? Color.yellow : Color.gray)
                                .frame(width: atValue ? 5 : width, height: atValue ? 2 : 1)
                        }
                        .offset(y: zero - CGFloat(position) * stepSize)
                    }
                }
                .frame(alignment: .leading) // Ensure the ZStack takes full width and aligns content to leading
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let y = gesture.location.y
                            let draggedValue = range.upperBound - (y / geometry.size.height) * (range.upperBound - range.lowerBound)
                            let roundedDraggedValue = (draggedValue / step).rounded() * step
                            value = Float(min(range.upperBound, max(range.lowerBound, roundedDraggedValue)))
                        }
                )
            }
        }
    }
}
