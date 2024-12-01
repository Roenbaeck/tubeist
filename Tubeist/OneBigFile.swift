import SwiftUI
import AVFoundation
import Foundation
import VideoToolbox
import WebKit

let FRAMERATE: Int = 30

let CAPTURE_WIDTH: Int = 3840
let CAPTURE_HEIGHT: Int = 2160

let COMPRESSED_WIDTH: Int = 1920
let COMPRESSED_HEIGHT: Int = 1080
let SEGMENT_DURATION: Int = 2 // seconds

let TIMESCALE: Int = 60000 // something divisible with FRAMERATE

struct SettingsView: View {
    @AppStorage("HLSServer") private var hlsServer: String = ""
    @AppStorage("Username") private var username: String = ""
    @AppStorage("Password") private var password: String = ""
    @AppStorage("SaveFragmentsLocally") private var saveFragmentsLocally: Bool = false
    @AppStorage("SelectedBitrate") private var selectedBitrate: Int = 1_000_000
    @AppStorage("OverlayURL") private var overlayURL: String = ""
    @Environment(\.presentationMode) private var presentationMode

    var bitrates: [Int] = [1_000_000, 2_000_000, 3_000_000, 4_000_000, 6_000_000, 10_000_000, 20_000_000]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("HLS Server")) {
                    TextField("HLS Server URI", text: $hlsServer)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("Authentication")) {
                    TextField("Username", text: $username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    SecureField("Password", text: $password)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("Bitrate")) {
                    Picker("Select Bitrate", selection: $selectedBitrate) {
                        ForEach(bitrates, id: \.self) { bitrate in
                            Text("\(bitrate / 1_000_000) Mbit").tag(bitrate)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }
                
                Section(header: Text("Overlay")) {
                    TextField("Web Overlay URL", text: $overlayURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section {
                    Toggle("Save fragments locally", isOn: $saveFragmentsLocally)
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Save") {
                // Dismiss the settings view when saving
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

func savePixelBufferAsPNG(pixelBuffer: CVPixelBuffer, to url: URL) {
    do {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        let uiImage = UIImage(cgImage: cgImage!)
        let pngData = uiImage.pngData()! // Force-unwrap, assuming pngData will always be non-nil
        try pngData.write(to: url)
        print("Saved image to \(url)")
    } catch {
        print("Error saving image: \(error)")
    }
}

@Observable
final class SharedImageState {
    var capturedOverlay: CIImage?
    static let shared = SharedImageState()
    
    private init() {}
}


class WebOverlayViewController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name
            == "domChanged" {
            // print("Capturing web view due to DOM change")
            self.captureWebViewImage()
        }
    }
    
    private var webView: WKWebView?
    let urlString: String
    let sharedState = SharedImageState.shared
    
    init(urlString: String) {
        self.urlString = urlString
        super.init()
    }

    func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: CAPTURE_WIDTH, height: CAPTURE_HEIGHT), configuration: config)
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.zoomScale = 1.0
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.contentScaleFactor = 1.0
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.contentInset = UIEdgeInsets.zero
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        
        self.webView = webView
        return webView
    }
    
    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("Web view finished loading")
        let script = """
            (function() {
                // Create a MutationObserver to watch for DOM changes
                const observer = new MutationObserver(mutationsList => {
                    // Trigger a Swift callback when a change is detected
                    window.webkit.messageHandlers.domChanged.postMessage('DOM changed');
                });

                // Start observing the entire document
                observer.observe(document, { subtree: true, childList: true, characterData: true });
            })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                print("Error injecting JavaScript: \(error)")
            }
        }

        webView.configuration.userContentController.add(self, name: "domChanged")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.captureWebViewImage()
        }
    }
    
    func captureWebViewImage() {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: CAPTURE_WIDTH / Int(UIScreen.main.scale))
        
        webView?.takeSnapshot(with: config) { [weak self] (image, error) in
            guard let uiImage = image else {
                print("Error capturing snapshot: \(String(describing: error))")
                return
            }
            /*
            // Detailed image size logging
            print("UIImage size in points: \(uiImage.size)")
            print("UIImage scale: \(uiImage.scale)")
            print("UIImage size in pixels: \(CGSize(width: uiImage.size.width * uiImage.scale, height: uiImage.size.height * uiImage.scale))")
                        
            // Save the UIImage to a file for checking
            if let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let fileURL = documentDirectory.appendingPathComponent("capturedImage.png")
                if let pngData = uiImage.pngData() {
                    do {
                        try pngData.write(to: fileURL)
                        print("Saved UIImage to \(fileURL)")
                    } catch {
                        print("Error: Could not save UIImage to \(fileURL): \(error)")
                    }
                } else {
                    print("Error: Could not convert UIImage to PNG data")
                }
            }
            */

            if let ciImage = CIImage(image: uiImage) {
                /*
                print("Valid image captured with size: \(uiImage.size)")
                print("CIImage extent: \(ciImage.extent)")
                */
                self?.sharedState.capturedOverlay = ciImage
                
            } else {
                print("Error: Captured image could not be converted to CIImage")
            }
        }
    }
}

struct WebOverlayView: UIViewRepresentable {
    let urlString: String
    
    func makeCoordinator() -> WebOverlayViewController {
        WebOverlayViewController(urlString: urlString)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.createWebView()
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Handle updates if needed
    }
}

struct ContentView: View {
    @State private var session: AVCaptureSession?
    @State private var audioLevel: Float = 0.0
    @State private var audioDelegate: AudioLevelDelegate?
    @State private var isRecording = false
    @State private var showSettings = false

    @StateObject private var recordingManager: RecordingManager = RecordingManager(hlsServer: UserDefaults.standard.string(forKey: "HLSServer") ?? "")

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = height * (16.0/9.0)
            
            ZStack {
                // Camera, web overlay, and controls contained within 16:9 area
                ZStack {
                    CameraViewControllerRepresentable(session: $session,
                                                    audioLevel: $audioLevel)
                        .onAppear {
                            setupCamera()
                        }
                    
                    WebOverlayView(urlString: UserDefaults.standard.string(forKey: "OverlayURL") ?? "")
                    
                    // Controls now positioned relative to 16:9 frame
                    HStack {
                        Spacer()
                        VStack {
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
                            }
                            .padding(.top)

                            Spacer()
                            
                            AudioLevelMeter(audioLevel: $audioLevel)
                                .frame(width: 30)
                            
                            Spacer()

                            Button(action: {
                                isRecording.toggle()
                                if isRecording {
                                    recordingManager.startRecording()
                                } else {
                                    recordingManager.stopRecording {
                                        print("Recording finished")
                                    }
                                }
                            }) {
                                Image(systemName: isRecording ? "record.circle.fill" : "record.circle")
                                    .font(.system(size: 24))
                                    .foregroundColor(isRecording ? .red : .white)
                                    .frame(width: 50, height: 50)
                            }
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(25)
                            
                            Spacer()
                        }
                        .padding()
                        .offset(x: -10)
                    }
                }
                .frame(width: width, height: height)
                .position(x: geometry.size.width/2, y: geometry.size.height/2)
            }
        }
        .edgesIgnoringSafeArea(.all)
    }

    // MARK: setupCamera
    private func setupCamera() {
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let audioDevice = AVCaptureDevice.default(for: .audio) else {
            print("No camera or microphone found")
            return
        }
        
        do {
            let session = AVCaptureSession()
            session.beginConfiguration()

            // Set session preset before adding inputs/outputs
            switch CAPTURE_WIDTH {
            case 1280: session.sessionPreset = .hd1280x720
            case 1920: session.sessionPreset = .hd1920x1080
            case 3840: session.sessionPreset = .hd4K3840x2160
            default: break
            }
            
            // videoDevice.listFormats()
            
            guard let format = videoDevice.findFormat() else {
                print("Desired format not found")
                return
            }
            
            videoDevice.printFormatDetails(captureFormat: format)

            // Apply the format to the video device
            try videoDevice.lockForConfiguration()
            videoDevice.activeFormat = format
            let frameDurationParts = Int64(TIMESCALE / FRAMERATE)
            videoDevice.activeVideoMinFrameDuration = CMTimeMake(value: frameDurationParts, timescale: Int32(TIMESCALE))
            videoDevice.activeVideoMaxFrameDuration = CMTimeMake(value: frameDurationParts, timescale: Int32(TIMESCALE))
            videoDevice.activeColorSpace = .HLG_BT2020

            videoDevice.unlockForConfiguration()

            // Add video input to the session
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                print("Cannot add video input")
                return
            }
            
            // Add audio input to the session
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
            } else {
                print("Cannot add audio input")
                return
            }

            // Add video output to the session
            let videoOutput = AVCaptureVideoDataOutput()
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            } else {
                print("Cannot add video output")
                return
            }
            
            // Add audio output to the session
            let audioOutput = AVCaptureAudioDataOutput()
            // Create and retain the audio delegate
            let level = { level in
                DispatchQueue.main.async {
                    self.audioLevel = level
                }
            }
            self.audioDelegate = AudioLevelDelegate(onAudioLevelUpdate: level, recordingManager: recordingManager)
            
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                audioOutput.setSampleBufferDelegate(self.audioDelegate, queue: DispatchQueue(label: "audioQueue"))
            } else {
                print("Cannot add audio output")
                return
            }

            videoOutput.setSampleBufferDelegate(recordingManager, queue: DispatchQueue(label: "recordingQueue"))

            /*
            // Find the video connection and enable stabilization
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .standard
                    print("Video stabilization enabled: Standard")
                } else {
                    print("Video stabilization is not supported for this connection.")
                }
            } else {
                print("Failed to get video connection.")
            }
             */
            
            session.commitConfiguration()

            // Start the session on a background thread
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                
                // Update UI on main thread
                DispatchQueue.main.async {
                    self.session = session
                }
            }

        } catch {
            print("Error setting up camera: \(error)")
        }
    }
}

// Extend AVCaptureDevice to include findFormat method
extension AVCaptureDevice {
    func printFormatDetails(captureFormat: AVCaptureDevice.Format) {
        print("----------============ \(captureFormat.formatDescription.mediaSubType.rawValue) ============----------")
        print("Supports \(captureFormat.formatDescription)")
        print("HDR: \(captureFormat.isVideoHDRSupported)")
        print("Frame range: \(captureFormat.videoSupportedFrameRateRanges)")
        print("Spatial video: \(captureFormat.isSpatialVideoCaptureSupported)")
        print("Background replacement: \(captureFormat.isBackgroundReplacementSupported)")
        print("Binned: \(captureFormat.isVideoBinned)")
        print("Multi-cam: \(captureFormat.isMultiCamSupported)")
        print("FOV: \(captureFormat.videoFieldOfView)")
        print("Color spaces: \(captureFormat.supportedColorSpaces)")
        print("ISO: \(captureFormat.minISO) - \(captureFormat.maxISO)")
        print("Exposure: \(captureFormat.minExposureDuration) - \(captureFormat.maxExposureDuration)")
        print("Max zoom: \(captureFormat.videoMaxZoomFactor) (native zoom: \(captureFormat.secondaryNativeResolutionZoomFactors))")
        print("AF: \(captureFormat.autoFocusSystem)")
    }
    func listFormats() {
        for captureFormat in formats {
            printFormatDetails(captureFormat: captureFormat)
        }
    }
    func findFormat() -> AVCaptureDevice.Format? {
        for captureFormat in formats {
            if captureFormat.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange {
                let description = captureFormat.formatDescription as CMFormatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                
                if dimensions.width == CAPTURE_WIDTH && dimensions.height == CAPTURE_HEIGHT,
                   let frameRateRange = captureFormat.videoSupportedFrameRateRanges.first,
                   frameRateRange.maxFrameRate >= Float64(FRAMERATE),
                   captureFormat.isVideoHDRSupported,
                   !captureFormat.isMultiCamSupported, // avoid this to get a different 4:2:2 with higher refresh rates
                   captureFormat.maxISO >= 5184.0 {
                    print("Desired format found")
                    return captureFormat
                }
            }
        }
        return nil
    }
}

struct CameraViewControllerRepresentable: UIViewControllerRepresentable {
    @Binding var session: AVCaptureSession?
    @Binding var audioLevel: Float
    
    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        // Ensure view is loaded before configurations
        viewController.loadViewIfNeeded()
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let session = session else { return }
        
        // Remove existing preview layer if any
        uiViewController.view.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        
        // Create and configure preview layer
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        
        // Configure connection rotation
        if let connection = previewLayer.connection {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        }
        
        // Add preview layer
        uiViewController.view.layer.addSublayer(previewLayer)
        
        // Update frame using proper animation configuration
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0)
            previewLayer.frame = uiViewController.view.bounds
            CATransaction.commit()
        }
    }
}

struct AudioLevelMeter: View {
    @Binding var audioLevel: Float
    
    // Constants for customization
    private let numberOfSegments = 20
    private let spacing: CGFloat = 2
    private let cornerRadius: CGFloat = 4
    private let minWidthFactor: CGFloat = 0.3
    private let animationDuration = 0.1
    private let verticalPadding: CGFloat = 20  // Added padding constant
    
    // Colors for different levels
    private let lowColor = Color.green
    private let midColor = Color.yellow
    private let highColor = Color.red
    
    private func colorForSegment(_ index: Int) -> Color {
        let segmentPercent = Double(index) / Double(numberOfSegments)
        switch segmentPercent {
        case 0.0..<0.6: return lowColor
        case 0.6..<0.8: return midColor
        default: return highColor
        }
    }
    
    private func segmentWidth(_ geometry: GeometryProxy, index: Int) -> CGFloat {
        let baseWidth = geometry.size.width
        let widthIncrease = (1 - minWidthFactor) * Double(index) / Double(numberOfSegments)
        return baseWidth * (minWidthFactor + widthIncrease)
    }
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: spacing) {
                Spacer(minLength: verticalPadding)  // Top padding
                
                ForEach((0..<numberOfSegments).reversed(), id: \.self) { index in
                    let isActive = Float(index) / Float(numberOfSegments) <= audioLevel
                    
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(colorForSegment(index))
                        .frame(width: segmentWidth(geometry, index: index))
                        .opacity(isActive ? 1.0 : 0.1)
                        .animation(.easeOut(duration: animationDuration), value: isActive)
                        .shadow(color: isActive ? colorForSegment(index).opacity(0.5) : .clear,
                               radius: isActive ? 2 : 0)
                }
                
                Spacer(minLength: verticalPadding)  // Bottom padding
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}


class AudioLevelDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var onAudioLevelUpdate: (Float) -> Void
    private var peakHoldLevel: Float = 0
    private let decayRate: Float = 0.2
    private var recordingManager: RecordingManager
    
    init(onAudioLevelUpdate: @escaping (Float) -> Void, recordingManager: RecordingManager) {
        self.onAudioLevelUpdate = onAudioLevelUpdate
        self.recordingManager = recordingManager
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let channel = connection.audioChannels.first else { return }
        
        let power = channel.averagePowerLevel
        let normalizedPower = pow(10, power / 20)
        
        // Implement peak holding with decay
        if normalizedPower > peakHoldLevel {
            peakHoldLevel = normalizedPower
        } else {
            peakHoldLevel = max(0, peakHoldLevel - decayRate)
        }
        
        // Normalize and smooth the level
        let normalizedLevel = normalizeAudioLevel(peakHoldLevel)
        
        DispatchQueue.main.async {
            self.onAudioLevelUpdate(normalizedLevel)
        }
        
        // forward
        recordingManager.captureOutput(output, didOutput: sampleBuffer, from: connection)
    }
    
    private func normalizeAudioLevel(_ level: Float) -> Float {
        let minDb: Float = -60
        let maxDb: Float = 0
        let db = 20 * log10(level)
        let normalizedDb = (db - minDb) / (maxDb - minDb)
        return min(max(normalizedDb, 0), 1)
    }
}



extension RecordingManager: AVAssetWriterDelegate {
     func assetWriter(_ writer: AVAssetWriter,
                      didOutputSegmentData segmentData: Data,
                      segmentType: AVAssetSegmentType,
                      segmentReport: AVAssetSegmentReport?) {
         print("A segment has been produced")

         guard isRecording else { return }
         
         let ext = switch segmentType {
             case .initialization: "mp4"
             case .separable: "m4s"
             @unknown default: "unknown"
         }

         let duration = (segmentReport?.trackReports.first?.duration.seconds ?? 2.0)
         // Use the serial queue to ensure atomic update of segmentCounter
         segmentCounterQueue.sync {
             // Append segment to buffer with the current sequence number
             segmentBuffer.append((sequence: segmentCounter, segment: segmentData, ext: ext, duration: duration))
             
             // Increment the segmentCounter for the next segment
             self.segmentCounter += 1
         }

         self.uploadSegment(attempt: 1)

         // MARK: save files
         let saveFragmentsLocally = UserDefaults.standard.bool(forKey: "SaveFragmentsLocally")
         if saveFragmentsLocally {
             let outputDirectory = containerURL.appendingPathComponent("DataFiles")
             let filename = "segment_\(segmentCounter).\(ext)"
             let fileURL = outputDirectory.appendingPathComponent(filename)
             
             do {
                 try segmentData.write(to: fileURL)
             }
             catch {
                 print("Error writing files: \(error)")
             }
             print("Wrote file: \(fileURL)")
             
         }
     }
}




// Manages the recording and streaming of HLS segments
class RecordingManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var segmentDuration: CMTime
    private var isRecording = false
    private var isSessionStarted = false
    private var segmentCounter = 0
    private var segmentBuffer: [(sequence: Int, segment: Data, ext: String, duration: Double)] = []
    private var hlsServer: String
    // file storage
    private let fileManager: FileManager
    private let containerURL: URL
    
    // Upload queue and retry configuration
    private let uploadQueue: OperationQueue
    private let maxRetryAttempts = 3
    private let baseRetryDelay: TimeInterval = 1.0  // Initial retry delay in seconds
    private var completionHandler: (() -> Void)?
    // Create a serial queue for synchronization
    private let segmentCounterQueue = DispatchQueue(label: "segmentCounterQueue")
    // A set to keep track of sequences currently being uploaded
    private var uploadingSequences: Set<Int> = []
    private let sharedState = SharedImageState.shared
    
    private let context: CIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_2020)!
    ])
    private let sourceOverKernel = CIBlendKernel.sourceOver
    
    
    init(hlsServer: String) {
        print("The HLS server is: ", hlsServer)
        self.hlsServer = hlsServer
        let segmentDurationParts = Int64(SEGMENT_DURATION * TIMESCALE)
        self.segmentDuration = CMTimeMake(value: segmentDurationParts, timescale: Int32(TIMESCALE))
        
        // Initialize upload queue with concurrent operations
        self.uploadQueue = OperationQueue()
        self.uploadQueue.maxConcurrentOperationCount = 3
        
        // MARK: FileManager stuff
        fileManager = FileManager.default
        
        // Use a shared container that's accessible in Files app
        guard let containerURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Could not access shared container directory")
        }
        self.containerURL = containerURL
        
        // Create output directory in the shared container
        let outputDirectory = containerURL.appendingPathComponent("DataFiles")
        
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Error creating output directory: \(error)")
        }
                
        super.init()
        setupAssetWriter()
    }
    
    // MARK: setupAssetWriter
    func setupAssetWriter() {
        // Create a UTType for the MP4 file type.
        guard let contentType = UTType(AVFileType.mp4.rawValue) else { return }
        assetWriter = AVAssetWriter(contentType: contentType)
        assetWriter?.shouldOptimizeForNetworkUse = true
        assetWriter?.outputFileTypeProfile = .mpeg4AppleHLS
        assetWriter?.preferredOutputSegmentInterval = segmentDuration
        assetWriter?.initialSegmentStartTime = .zero
        assetWriter?.delegate = self

        let selectedBitrate = UserDefaults.standard.integer(forKey: "SelectedBitrate")

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: COMPRESSED_WIDTH,
            AVVideoHeightKey: COMPRESSED_HEIGHT,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoAverageBitRateKey: selectedBitrate,
                AVVideoExpectedSourceFrameRateKey: FRAMERATE,
                AVVideoMaxKeyFrameIntervalKey: SEGMENT_DURATION * FRAMERATE,  // One keyframe per 2-second segment
                AVVideoAllowFrameReorderingKey: true,
                // Leaving the following three out defaults to Rec.709
                // YouTube needs these for HDR: https://developers.google.com/youtube/v3/live/guides/hls-ingestion
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true

                
        // Configure audio input
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput?.expectsMediaDataInRealTime = true
        
        if let videoInput = videoInput, let audioInput = audioInput {
            assetWriter?.add(videoInput)
            assetWriter?.add(audioInput)
        }
    }
    
    func startRecording() {
        assetWriter?.startWriting()
        isRecording = true // this has to be after startWriting, otherwise captureOutput will start processing "too soon"
        print("Recording has started")
    }
    
    func stopRecording(completion: @escaping () -> Void) {
        isRecording = false
        isSessionStarted = false
        segmentCounter = 0
        completionHandler = completion
        
        // Properly handle async finish writing
        if let writer = assetWriter {
            writer.finishWriting { [weak self] in
                DispatchQueue.main.async {
                    self?.completionHandler?()
                    self?.completionHandler = nil
                    // Set up a new asset writer for the next recording
                    self?.setupAssetWriter()
                }
            }
        }
    }

    
    // MARK: captureOutput
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording else {
            return
        }

        if !isSessionStarted {
            let startTime = sampleBuffer.presentationTimeStamp
            assetWriter?.startSession(atSourceTime: startTime)
            isSessionStarted = true
        }

        // Verify the sample buffer contains a video buffer
        if output is AVCaptureVideoDataOutput {
            
            guard let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                fatalError("Unable to get pixel buffer from sample buffer")
            }
            
            let destination = CIRenderDestination(pixelBuffer: videoPixelBuffer)
            destination.blendKernel = sourceOverKernel
            destination.blendsInDestinationColorSpace = true
            destination.alphaMode = .premultiplied
            
            do {
                let task = try context.startTask(toRender: sharedState.capturedOverlay!, to: destination)
                try task.waitUntilCompleted()
            }
            catch {
                print("Error rendering overlay: \(error)")
            }
                        
            if let input = videoInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
            
        } else if output is AVCaptureAudioDataOutput {
            // Handle audio sample buffer
            if let input = audioInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }
    
    private func uploadSegment(attempt: Int) {
        guard !segmentBuffer.isEmpty else {
            print("No segments to upload.")
            return
        }

        // Inside the task block to avoid race conditions
        uploadQueue.addOperation {
            guard self.isRecording, self.segmentBuffer.count > 0 else { return }
            let bufferedSegment = self.segmentBuffer[0]
            let sequence = bufferedSegment.sequence
            let duration = bufferedSegment.duration
            let isInit = bufferedSegment.ext == "mp4" // Simplified the logic
            let segment = bufferedSegment.segment

            guard let hlsServerURL = URL(string: self.hlsServer) else {
                print("Invalid HLS server URL: ", self.hlsServer)
                return
            }

            // Check if this sequence is already being uploaded
            guard !self.uploadingSequences.contains(sequence) else {
                print("Segment number \(sequence) is already uploading, skipping this upload.")
                return
            }
            
            // Add sequence to the set to mark it as being uploaded
            self.uploadingSequences.insert(sequence)
            
            let request = self.createUploadRequest(url: hlsServerURL, segment: segment, duration: duration, sequence: sequence, isInit: isInit)

            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }

                if let error = error {
                    print("Upload error: \(error.localizedDescription). Retrying...")
                    // Optionally retry a failed upload
                    if attempt < 3 {
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                            self.uploadSegment(attempt: attempt + 1)
                        }
                    }
                    return
                }

                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    print("Server returned an error: \(httpResponse.statusCode). Retrying...")
                    if attempt < 3 {
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                            self.uploadSegment(attempt: attempt + 1)
                        }
                    }
                    return
                }

                // Successful upload
                print("Successfully uploaded segment number \(sequence) with duration \(duration)")

                // Remove the uploaded segment from the buffer
                DispatchQueue.main.async {
                    self.segmentBuffer.removeFirst()
                    self.uploadingSequences.remove(sequence)
                }
            }

            task.resume()
        }
    }

    private func createUploadRequest(url: URL, segment: Data, duration: Double, sequence: Int, isInit: Bool) -> URLRequest {
        var request = URLRequest(url: url.appendingPathComponent("upload_segment"))
        request.httpMethod = "POST"
        
        // Boundary for multipart form data
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Add Basic Authentication header
        let username = UserDefaults.standard.string(forKey: "Username") ?? "brute"
        let password = UserDefaults.standard.string(forKey: "Password") ?? "force"

        let loginString = String(format: "%@:%@", username, password)
        let loginData = loginString.data(using: .utf8)!
        let base64LoginString = loginData.base64EncodedString()
        request.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
        
        // Create multipart form data
        var body = Data()
        
        // Add `is_init` field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"is_init\"\r\n\r\n")
        body.append("\(isInit ? "true" : "false")\r\n")
        
        // Add `duration` field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"duration\"\r\n\r\n")
        body.append("\(duration)\r\n")
        
        // Add `sequence` field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"sequence\"\r\n\r\n")
        body.append("\(sequence)\r\n")
        
        // Add the file
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"segment\"; filename=\"segment_\(sequence).mp4\"\r\n")
        body.append("Content-Type: application/mp4\r\n\r\n")
        body.append(segment)
        body.append("\r\n")
        
        // End of multipart data
        body.append("--\(boundary)--\r\n")
        
        request.httpBody = body
        return request
    }
    
}

// Helper method to append data to `Data`
private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

