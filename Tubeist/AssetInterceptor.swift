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

    func setupAssetWriter() {
        guard let contentType = UTType(AVFileType.mp4.rawValue) else {
            LOG("MP4 is not a valid type", level: .error)
            return
        }
        assetWriter = AVAssetWriter(contentType: contentType)
        guard let assetWriter else {
            LOG("Could not create asset writer", level: .error)
            return
        }
        assetWriter.shouldOptimizeForNetworkUse = true
        assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
        assetWriter.preferredOutputSegmentInterval = FRAGMENT_CM_TIME
        assetWriter.initialSegmentStartTime = .zero
        assetWriter.delegate = AssetInterceptor.shared
        
        let selectedPreset = Settings.getSelectedPreset()
        let selectedVideoBitrate = selectedPreset?.videoBitrate ?? DEFAULT_VIDEO_BITRATE
        let selectedAudioBitrate = selectedPreset?.audioBitrate ?? DEFAULT_AUDIO_BITRATE
        let selectedAudioChannels = selectedPreset?.audioChannels ?? DEFAULT_AUDIO_CHANNELS
        let selectedWidth = selectedPreset?.width ?? DEFAULT_COMPRESSED_WIDTH
        let selectedHeight = selectedPreset?.height ?? DEFAULT_COMPRESSED_HEIGHT
        let selectedKeyframeInterval = selectedPreset?.keyframeInterval ?? DEFAULT_KEYFRAME_INTERVAL
        let selectedFrameRate = selectedPreset?.frameRate ?? DEFAULT_FRAMERATE
        let frameIntervalKey = Int(ceil(selectedKeyframeInterval * Double(selectedFrameRate)))
        
        LOG("[video bitrate]: \(selectedVideoBitrate) [audio bitrate]: \(selectedAudioBitrate) [audio channels]: \(selectedAudioChannels) [width]: \(selectedWidth) [height]: \(selectedHeight) [frame rate]: \(selectedFrameRate) [key frame every frames]: \(frameIntervalKey)", level: .debug)
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: selectedWidth,
            AVVideoHeightKey: selectedHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoAverageBitRateKey: selectedVideoBitrate,
                AVVideoExpectedSourceFrameRateKey: selectedFrameRate,
                AVVideoMaxKeyFrameIntervalKey: frameIntervalKey,
                AVVideoAllowFrameReorderingKey: true,
                kVTCompressionPropertyKey_HDRMetadataInsertionMode: kVTHDRMetadataInsertionMode_Auto
            ]
        ]
        
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        guard let videoInput else {
            LOG("Could not set up video input", level: .error)
            return
        }
        videoInput.expectsMediaDataInRealTime = true
        
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: selectedAudioChannels,
            AVEncoderBitRatePerChannelKey: selectedAudioBitrate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Variable
        ]
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        guard let audioInput else {
            LOG("Could not set up audio input", level: .error)
            return
        }
        audioInput.expectsMediaDataInRealTime = true
        
        assetWriter.add(videoInput)
        assetWriter.add(audioInput)

        if assetWriter.startWriting() == false {
            LOG("Error starting writing: \(assetWriter.error?.localizedDescription ?? "Unknown error")")
            return
        }
        let currentTime = CMTime(seconds: Date().timeIntervalSince1970, preferredTimescale: Int32(TIMESCALE))
        assetWriter.startSession(atSourceTime: currentTime)
        
        LOG("Asset writer configured successfully (at source time: \(currentTime.value) | \(currentTime.timescale))", level: .info)
    }
    
     func finishWriting() async {
         await withCheckedContinuation { continuation in
             guard let assetWriter else {
                 LOG("Asset writer not active or configured", level: .error)
                 continuation.resume() // Resume immediately if there's nothing to stop
                 return
             }
             self.videoInput?.markAsFinished()
             self.audioInput?.markAsFinished()
             assetWriter.finishWriting {
                 if assetWriter.status != .completed {
                     LOG("Failed to finish writing: \(String(describing: assetWriter.error))", level: .warning)
                 } else {
                     LOG("Finished writing successfully", level: .info)
                 }
                 continuation.resume() // Resume after `finishWriting` completes
             }
             self.assetWriter = nil
             self.videoInput = nil
             self.audioInput = nil
         }
     }
     
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, inputType: String) {
        guard let assetWriter = self.assetWriter, assetWriter.status == .writing else {
            LOG("Cannot append \(inputType) buffer, writer not in writing state: \(self.assetWriter?.status.rawValue ?? -1)", level: .warning)
            return
        }
        guard let input = input, input.isReadyForMoreMediaData else {
            LOG("\(inputType) input not ready for more media data", level: .warning)
            return
        }
        if input.append(sampleBuffer) == false {
            LOG("Error appending video buffer", level: .error)
        }
    }

    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        appendSampleBuffer(sampleBuffer, to: videoInput, inputType: "Video")
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        appendSampleBuffer(sampleBuffer, to: audioInput, inputType: "Audio")
    }
}

actor fragmentSequenceNumberActor {
    // with next() first sequence is numbered 0 (ensuring correspondence with the sequence numbers in the m4s files)
    private var fragmentSequenceNumber: Int = -1
    func next() -> Int {
        fragmentSequenceNumber += 1
        return fragmentSequenceNumber
    }
    func last() -> Int {
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
    private let fragmentFolderURL: URL?
    override init() {
        let fileManager = FileManager.default
        
        // Use a shared container that's accessible in Files app
        if let fragmentFolderURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            self.fragmentFolderURL = fragmentFolderURL
            // Create output directory in the shared container
            let outputDirectory = fragmentFolderURL.appendingPathComponent("DataFiles")
            do {
                try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                LOG("Error creating output directory: \(error)", level: .error)
            }
        }
        else {
            self.fragmentFolderURL = nil
            LOG("Could not access directory where fragments are stored", level: .error)
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

    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        await self.assetWriter.appendVideoSampleBuffer(sampleBuffer)
    }
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        await self.assetWriter.appendAudioSampleBuffer(sampleBuffer)
    }
    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        guard let fragmentType: Fragment.SegmentType = {
            switch segmentType {
            case .initialization: .initialization
            case .separable: writer.status == .writing ? .separable : .finalization
            @unknown default: nil
            }
        }() else {
            LOG("Unknown segment type", level: .error)
            return
        }
        let duration = segmentReport?.trackReports.first?.duration.seconds ?? 0
        if segmentType == .initialization || duration >= FRAGMENT_MINIMUM_DURATION {
            Task.detached { [self] in
                let sequenceNumber = await fragmentSequenceNumber.next()
                let fragment = Fragment(sequence: sequenceNumber, segment: segmentData, duration: duration, type: fragmentType)
                LOG("Produced \(fragment)", level: .debug)
                fragmentPusher.addFragment(fragment)
                fragmentPusher.uploadFragment(attempt: 1)
                saveFragmentToFile(fragment)
            }
        }
    }
    func saveFragmentToFile(_ fragment: Fragment) {
        let saveFragmentsLocally = UserDefaults.standard.bool(forKey: "SaveFragmentsLocally")
        if saveFragmentsLocally {
            guard let outputDirectory = fragmentFolderURL?.appendingPathComponent("DataFiles") else {
                LOG("Cannot write file to local storage", level: .error)
                return
            }
            let sequenceNumber = fragment.sequence
            let ext = fragment.type == .initialization ? "mp4" : "m4s"
            let filename = "segment_\(sequenceNumber).\(ext)"
            let fileURL = outputDirectory.appendingPathComponent(filename)
            let segmentData = fragment.segment
            do {
                try segmentData.write(to: fileURL)
            }
            catch {
                LOG("Error writing files: \(error)", level: .error)
            }
            LOG("Wrote file: \(fileURL)", level: .debug)
            
        }
    }
}
