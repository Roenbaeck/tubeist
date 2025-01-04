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
class Interaction {
    var location = CGPoint(x: 0, y: 0)
    private var actionWorkItem: DispatchWorkItem?

    func scheduleAction(seconds: Double = 3.0, action: @escaping () -> Void) {
        actionWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            action()
        }
        actionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
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
    @State private var exposureBias: Float = 0.0
    @State private var lensPosition: Float = 1.0
    @State private var selectedCamera = DEFAULT_CAMERA
    @State private var selectedStabilization = "Off"
    @State private var cameras: [String] = []
    @State private var stabilizations: [String] = []

    @State private var interaction = Interaction()
    @State private var isCameraReady = false
    @State private var showSplashScreen = true
    @State private var splashOpacity: Double = 1.0
    
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
    
    func updateCameraProperties() {
        Task {
            // Passing Binding<variable> to a singleton is fine
            await CaptureDirector.shared.bind(
                totalZoom: $totalZoom,
                currentZoom: $currentZoom,
                exposureBias: $exposureBias
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
                                await Streamer.shared.startSessions()
                                appState.refreshCameraView()
                                updateCameraProperties()
                                isCameraReady = true
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
                                interaction.location = location
                                Task {
                                    let normalizedLocation = CGPoint(
                                        x: location.x / width,
                                        y: location.y / height
                                    )
                                    if appState.isExposureLocked {
                                        await CaptureDirector.shared.setExposure(at: normalizedLocation)
                                        LOG("Probing exposure at \(location)")
                                    }
                                    if appState.isFocusLocked {
                                        await CaptureDirector.shared.setFocus(at: normalizedLocation)
                                        LOG("Probing focus at \(location)")
                                    }
                                }
                                showFocusAndExposureArea = true
                                // Schedule hide with a method that cancels and reschedules
                                interaction.scheduleAction {
                                    showFocusAndExposureArea = false
                                }
                            }
                        }

                    if showSplashScreen {
                        ZStack {
                            Rectangle()
                                .frame(width: width, height: height)
                                .foregroundColor(Color.black)
                            Text("This is the Tubeist splash screen placeholder")
                                .font(.system(size: 24))
                                .fontWeight(.bold)
                        }
                        .opacity(splashOpacity) // Apply the opacity
                        .onChange(of: isCameraReady) { _, newValue in
                            if newValue {
                                withAnimation(.easeInOut(duration: 1.0)) {
                                    splashOpacity = 0.0
                                } completion: {
                                    showSplashScreen = false // Hide the splash screen after animation
                                }
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
                            .onAppear {
                                LOG("Viewing output monitor", level: .info)
                            }
                    }
                                        
                    if showJournal {
                        JournalView()
                    }
                    
                    VStack {
                        Spacer()
                        if appState.isBatterySavingOn {
                            Text("BATTERY SAVING MODE")
                                .font(.system(size: 30))
                                .foregroundColor(Color.yellow)
                                .fontWeight(.black)
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
                                        await CaptureDirector.shared.setCameraStabilization(to: newStabilization)
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
                            
                            Text(String(format: zoom == 1 || zoom > 10 ? "%.0f" : "%.1f", zoom) + "×")
                                .font(.system(size: 17))
                                .fontWeight(.semibold)
                                .foregroundColor(zoom > opticalZoom ? .yellow : zoom > 1 ? .white : .white.opacity(0.5))
                            
                            Spacer()
                            if appState.activeMonitor == .output {
                                Text("OUTPUT MONITORING")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.white)
                                    .fontWeight(.black)
                                    .rotationEffect(.degrees(90))
                                    .fixedSize()
                                    .frame(width: 15)
                            }
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

                    SmallButton(imageName: appState.isBatterySavingOn ? "sunrise.fill" : "sunset",
                                foregroundColor: appState.isBatterySavingOn ? .yellow : .white) {
                        showBatterySavingConfirmation = true
                    }
                    .confirmationDialog("Change Battery Saving Mode?", isPresented: $showBatterySavingConfirmation) {
                        Button(appState.isBatterySavingOn ? "Turn Off" : "Turn On") {
                            appState.isBatterySavingOn.toggle()
                        }
                        Button("Cancel", role: .cancel) {} // Do nothing
                    } message: {
                        Text(appState.isBatterySavingOn ? "Turning off battery saving will enable convenience features at the cost of higher battery consumption." : "Turning on battery saving will reduce everything not necessary for the streaming to a minimum.")
                    }
                    Text("PWRSV")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)
                    
                    SmallButton(imageName: appState.isStreamActive ? "camera.fill" : "camera",
                                foregroundColor: appState.isStreamActive || showCameraPicker ? .yellow : .white) {
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
                    Text("STBZN")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    SmallButton(imageName: appState.isFocusLocked ? "viewfinder.circle.fill" : "viewfinder.circle",
                                foregroundColor: appState.isFocusLocked ? .yellow : .white) {
                        appState.isFocusLocked.toggle()
                        enableFocusAndExposureTap = appState.isExposureLocked || appState.isFocusLocked
                        if appState.isFocusLocked {
                            Task {
                                await CaptureDirector.shared.lockFocus()
                            }
                        }
                        else {
                            Task {
                                await CaptureDirector.shared.autoFocus()
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
                        if appState.isExposureLocked {
                            Task {
                                await CaptureDirector.shared.lockExposure()
                            }
                        }
                        else {
                            Task {
                                await CaptureDirector.shared.autoExposure()
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
                                await CaptureDirector.shared.lockWhiteBalance()
                            }
                        }
                        else {
                            Task {
                                await CaptureDirector.shared.autoWhiteBalance()
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

                    SmallButton(imageName: "text.quote",
                                foregroundColor: showJournal ? .yellow : .white) {
                        showJournal.toggle()
                    }
                    Text("JORNL")
                        .font(.system(size: 8))
                        .padding(.bottom, 3)

                    Spacer()
                }
                .frame(width: 30) // Width based on button size and padding
                .padding(.leading, 10)
                    
                Spacer().overlay {
                    if appState.isExposureLocked {
                        CameraControlSlider(
                            value: $exposureBias,
                            range: -2.0...2.0,
                            step: 0.1,
                            format: "%.1f EV"
                        )
                            .frame(height: geometry.size.height * 0.50)
                            .padding(.leading, 10)
                            .onChange(of: exposureBias) { oldValue, newValue in
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
                            format: "%.2f"
                        )
                        .frame(height: geometry.size.height * 0.50)
                        .padding(.leading, 10)
                        .onChange(of: lensPosition) { oldValue, newValue in
                            Task {
                                await CaptureDirector.shared.setLensPosition(to: newValue)
                            }
                        }
                    }
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
        .persistentSystemOverlays(.hidden)
        .onChange(of: appState.isBatterySavingOn) { oldValue, newValue in
            appState.isAudioLevelRunning = !appState.isBatterySavingOn
            UIScreen.main.brightness = appState.isBatterySavingOn ? 0.1 : 1.0
            LOG("Battery saving is \(appState.isBatterySavingOn ? "on" : "off")", level: .info)
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
    var format: String

    var body: some View {
        VStack {
            HStack {
                Text("\(String(format: format, value))")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
                Spacer()
            }
            
            GeometryReader { geometry in
                let stepSize = geometry.size.height / Double(range.upperBound - range.lowerBound)
                let zero = geometry.size.height / Double(range.upperBound)
                
                ZStack(alignment: .leading) { // Align ZStack to the leading edge
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 10))
                        .foregroundColor(.yellow)
                        .offset(x: 14, y: zero - CGFloat(value) * stepSize - 0.5)
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
                .frame(maxWidth: .infinity, alignment: .leading) // Ensure the ZStack takes full width and aligns content to leading
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
