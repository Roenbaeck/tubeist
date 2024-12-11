//
//  AssetInterceptor.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

// @preconcurrency needed to pass CMSampleBuffer around
@preconcurrency import AVFoundation
import VideoToolbox

actor AssetWriterActor {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var _isSessionActive = false
    private var _isWriterActive = false

    func setupAssetWriter() {
        STREAMING_QUEUE_SERIAL.sync {            
            guard let contentType = UTType(AVFileType.mp4.rawValue) else {
                print("MP4 is not a valid type")
                return
            }
            assetWriter = AVAssetWriter(contentType: contentType)
            guard let assetWriter else {
                print("Could not create asset writer")
                return
            }
            assetWriter.shouldOptimizeForNetworkUse = true
            assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
            assetWriter.preferredOutputSegmentInterval = FRAGMENT_CM_TIME
            assetWriter.initialSegmentStartTime = .zero
            assetWriter.delegate = AssetInterceptor.shared
            
            let selectedBitrate = UserDefaults.standard.integer(forKey: "SelectedBitrate")
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: COMPRESSED_WIDTH,
                AVVideoHeightKey: COMPRESSED_HEIGHT,
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                    AVVideoAverageBitRateKey: selectedBitrate,
                    AVVideoExpectedSourceFrameRateKey: FRAMERATE,
                    AVVideoMaxKeyFrameIntervalKey: FRAGMENT_DURATION * FRAMERATE,
                    AVVideoAllowFrameReorderingKey: true,
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                ]
            ]
            
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            guard let videoInput else {
                print("Could not set up video input")
                return
            }
            videoInput.expectsMediaDataInRealTime = true
            
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            guard let audioInput else {
                print("Could not set up audio input")
                return
            }
            audioInput.expectsMediaDataInRealTime = true
            
            assetWriter.add(videoInput)
            assetWriter.add(audioInput)
        }
    }

    func finishWriting() {
        guard let assetWriter else {
            print("Asset writer not configured")
            return
        }
        STREAMING_QUEUE_SERIAL.sync {
            if _isWriterActive {
                _isWriterActive = false
                _isSessionActive = false
                Task {
                    await withCheckedContinuation { continuation in
                        assetWriter.finishWriting {
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let videoInput = videoInput else {
            print("Video input not configured")
            return
        }
        STREAMING_QUEUE_SERIAL.sync {
            if !_isSessionActive {
                guard let assetWriter else {
                    print("Asset writer not configured")
                    return
                }
                if !_isWriterActive {
                    assetWriter.startWriting()
                    _isWriterActive = true
                }
                assetWriter.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                _isSessionActive = true
            }
            if _isWriterActive && videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        }
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput = audioInput else {
            print("Audio input not configured")
            return
        }
        STREAMING_QUEUE_SERIAL.sync {
            if !_isSessionActive {
                guard let assetWriter else {
                    print("Asset writer not configured")
                    return
                }
                if !_isWriterActive {
                    assetWriter.startWriting()
                    _isWriterActive = true
                }
                assetWriter.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                _isSessionActive = true
            }
            if _isWriterActive && audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        }
    }
}

actor fragmentSequenceNumberActor {
    private var fragmentSequenceNumber: Int = 0
    func next() -> Int {
        fragmentSequenceNumber += 1
        return fragmentSequenceNumber
    }
    func reset() {
        fragmentSequenceNumber = 0
    }
}

final class AssetInterceptor: NSObject, AVAssetWriterDelegate, Sendable {
    public static let shared = AssetInterceptor()
    private let assetWriter = AssetWriterActor()
    private let fragmentSequenceNumber = fragmentSequenceNumberActor()
    private let fragmentPusher = FragmentPusher.shared
    private let fragmentFolderURL: URL
    override init() {
        let fileManager = FileManager.default
        
        // Use a shared container that's accessible in Files app
        guard let fragmentFolderURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Could not access directory where fragments are stored")
        }
        self.fragmentFolderURL = fragmentFolderURL
        
        // Create output directory in the shared container
        let outputDirectory = fragmentFolderURL.appendingPathComponent("DataFiles")
        
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Error creating output directory: \(error)")
        }
                
        super.init()
    }
    func beginIntercepting() async {
        await self.assetWriter.setupAssetWriter()
    }
    func endIntercepting() async {
        await self.assetWriter.finishWriting()
        await self.fragmentSequenceNumber.reset()
    }

    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        STREAMING_QUEUE_CONCURRENT.async {
            Task {
                await self.assetWriter.appendVideoSampleBuffer(sampleBuffer)
            }
        }
    }
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        STREAMING_QUEUE_CONCURRENT.async {
            Task {
                await self.assetWriter.appendAudioSampleBuffer(sampleBuffer)
            }
        }
    }
    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        guard let ext = {
            switch segmentType {
            case .initialization: "mp4"
            case .separable: "m4s"
            @unknown default: nil
            }
        }() else {
            print("Unknown segment type")
            return
        }
        let duration = (segmentReport?.trackReports.first?.duration.seconds ?? 2.0)
        Task.detached { [self] in
            let sequenceNumber = await fragmentSequenceNumber.next()
            let fragment = Fragment(sequence: sequenceNumber, segment: segmentData, ext: ext, duration: duration)
            print("A fragment has been produced: \(fragment.sequence).\(fragment.ext) [ \(fragment.duration) ]")
            fragmentPusher.addFragment(fragment)
            fragmentPusher.uploadFragment(attempt: 1)
            saveFragmentToFile(fragment)
        }
    }
    func saveFragmentToFile(_ fragment: Fragment) {
        let saveFragmentsLocally = UserDefaults.standard.bool(forKey: "SaveFragmentsLocally")
        if saveFragmentsLocally {
            let outputDirectory = fragmentFolderURL.appendingPathComponent("DataFiles")
            let sequenceNumber = fragment.sequence
            let ext = fragment.ext
            let filename = "segment_\(sequenceNumber).\(ext)"
            let fileURL = outputDirectory.appendingPathComponent(filename)
            let segmentData = fragment.segment
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
