import SwiftUI
import AVFoundation
import Foundation
import VideoToolbox

struct SettingsView: View {
    @AppStorage("HLSServer") private var hlsServer: String = ""
    @AppStorage("Username") private var username: String = ""
    @AppStorage("Password") private var password: String = ""
    @AppStorage("SaveFragmentsLocally") private var saveFragmentsLocally: Bool = false
    @AppStorage("SelectedBitrate") private var selectedBitrate: Int = 1_000_000
    @Environment(\.presentationMode) private var presentationMode

    var bitrates: [Int] = [1_000_000, 2_000_000, 3_000_000, 4_000_000, 5_000_000, 6_000_000]
    
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



struct ContentView: View {
    @State private var session: AVCaptureSession?
    @State private var audioLevel: Float = 0.0
    @State private var audioDelegate: AudioLevelDelegate?
    @State private var isRecording = false
    @State private var showSettings = false

    @StateObject private var recordingManager: RecordingManager = RecordingManager(hlsServer: UserDefaults.standard.string(forKey: "HLSServer") ?? "")

    var body: some View {
        ZStack {
            CameraViewControllerRepresentable(session: $session, audioLevel: $audioLevel)
                .onAppear {
                    setupCamera()
                }
                .edgesIgnoringSafeArea(.all)
            
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
                    
                    // Audio Level Meter
                    AudioLevelMeter(audioLevel: $audioLevel)
                        .frame(width: 30)
                    
                    Spacer()

                    // Record Button
                    Button(action: {
                        isRecording.toggle()
                        if isRecording {
                            recordingManager.startRecording()
                        } else {
                            recordingManager.stopRecording {
                                print("Recording finished")
                                // Handle post-recording tasks here
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
                .offset(x: -20) // move stack slightly left to not overlap the letterbox
            }
        }
    }

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
            session.sessionPreset = .hd1920x1080
            // After testing I think setting the camera to HD looks better
            // session.sessionPreset = .hd4K3840x2160
            
            // Find the desired format for the video device
            guard let format = videoDevice.findFormat() else {
                print("Desired format not found")
                return
            }

            // Apply the format to the video device
            try videoDevice.lockForConfiguration()
            videoDevice.activeFormat = format
            videoDevice.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: 30)
            videoDevice.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: 30)
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
                // Set up audio delegate
                // TODO: Looks like this is overwritten by the call a few lines below for the recordingManager
                audioOutput.setSampleBufferDelegate(self.audioDelegate, queue: DispatchQueue(label: "audioQueue"))
            } else {
                print("Cannot add audio output")
                return
            }

            videoOutput.setSampleBufferDelegate(recordingManager, queue: DispatchQueue(label: "recordingQueue"))
            //audioOutput.setSampleBufferDelegate(recordingManager, queue: DispatchQueue(label: "recordingQueue"))

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

// Extend AVCaptureDevice to include findFormat method
extension AVCaptureDevice {
    func findFormat() -> AVCaptureDevice.Format? {
        for captureFormat in formats {
            if captureFormat.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange {
                let description = captureFormat.formatDescription as CMFormatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                
                if dimensions.width == 1920 && dimensions.height == 1080,
                // if dimensions.width == 3840 && dimensions.height == 2160,
                   let frameRateRange = captureFormat.videoSupportedFrameRateRanges.first,
                   frameRateRange.maxFrameRate >= 30,
                   captureFormat.isVideoHDRSupported {
                    print("Desired format found")
                    return captureFormat
                }
            }
        }
        return nil
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
    
    init(hlsServer: String) {
        print("The HLS server is: ", hlsServer)
        self.hlsServer = hlsServer
        self.segmentDuration = CMTime(seconds: 2, preferredTimescale: 600)
        
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
        
        assetWriter = AVAssetWriter(contentType: .mpeg4Movie)
        assetWriter?.shouldOptimizeForNetworkUse = true
        assetWriter?.outputFileTypeProfile = .mpeg4AppleHLS
        assetWriter?.preferredOutputSegmentInterval = segmentDuration
        assetWriter?.initialSegmentStartTime = .zero
        assetWriter?.delegate = self

        let selectedBitrate = UserDefaults.standard.integer(forKey: "SelectedBitrate")

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoAverageBitRateKey: selectedBitrate,
                AVVideoMaxKeyFrameIntervalKey: 60,  // One keyframe per 2-second segment at 30fps
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
        guard isRecording else { return }

        if !isSessionStarted {
            let startTime = sampleBuffer.presentationTimeStamp
            assetWriter?.startSession(atSourceTime: startTime)
            isSessionStarted = true
        }
        
        // Write sample buffer to appropriate input
        if output is AVCaptureVideoDataOutput,
           let input = videoInput,
           input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        } else if output is AVCaptureAudioDataOutput,
                  let input = audioInput,
                  input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
    
    private func uploadSegment(attempt: Int) {
        guard !segmentBuffer.isEmpty else {
            print("No segments to upload.")
            return
        }

        // Inside the task block to avoid race conditions
        uploadQueue.addOperation {
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

