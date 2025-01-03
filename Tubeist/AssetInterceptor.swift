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
    private var frameRate: Double = DEFAULT_FRAMERATE

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
        let selectedPreset = Settings.selectedPreset
        let selectedVideoBitrate = selectedPreset?.videoBitrate ?? DEFAULT_VIDEO_BITRATE
        let selectedAudioBitrate = selectedPreset?.audioBitrate ?? DEFAULT_AUDIO_BITRATE
        let selectedAudioChannels = selectedPreset?.audioChannels ?? DEFAULT_AUDIO_CHANNELS
        let selectedWidth = selectedPreset?.width ?? DEFAULT_COMPRESSED_WIDTH
        let selectedHeight = selectedPreset?.height ?? DEFAULT_COMPRESSED_HEIGHT
        let selectedKeyframeInterval = selectedPreset?.keyframeInterval ?? DEFAULT_KEYFRAME_INTERVAL
        let selectedFrameRate = selectedPreset?.frameRate ?? DEFAULT_FRAMERATE
        let frameIntervalKey = Int(ceil(selectedKeyframeInterval * selectedFrameRate))
        let adjustedFragmentDuration = selectedFrameRate / trunc(selectedFrameRate / FRAGMENT_DURATION)

        frameRate = selectedFrameRate
        
        LOG("[video bitrate]: \(selectedVideoBitrate) [audio bitrate]: \(selectedAudioBitrate) [audio channels]: \(selectedAudioChannels) [width]: \(selectedWidth) [height]: \(selectedHeight) [frame rate]: \(selectedFrameRate) [key frame every frames]: \(frameIntervalKey)", level: .debug)
        
        assetWriter.shouldOptimizeForNetworkUse = true
        assetWriter.outputFileTypeProfile = .mpeg4AppleHLS
        assetWriter.preferredOutputSegmentInterval = CMTime(seconds: adjustedFragmentDuration, preferredTimescale: CMTimeScale(selectedFrameRate))
        assetWriter.initialSegmentStartTime = .zero
        Task { @PipelineActor in
            assetWriter.delegate = AssetInterceptor.shared
        }
        
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
        
        LOG("Asset writer configured successfully", level: .info)
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
     
    let startSessionOnceLock = NSLock()
    var sessionStarted: Bool = false
    
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, inputType: String) {
        guard let assetWriter = self.assetWriter, assetWriter.status == .writing else {
            LOG("Cannot append \(inputType) buffer, writer not in writing state: \(self.assetWriter?.status.rawValue ?? -1)", level: .warning)
            return
        }
        guard let input = input, input.isReadyForMoreMediaData else {
            LOG("\(inputType) input not ready for more media data", level: .warning)
            return
        }
        if !sessionStarted { // more than one thread might enter here
            startSessionOnceLock.lock() // first thread to reach this point aquires the lock and the rest are blocked
            defer { startSessionOnceLock.unlock() } // ensure unlock, releasing any other threads
            if !sessionStarted { // check again, first thread will enter and set sessionStarted to true, so released threads won't execute this code
                let currentTime = CMTime(seconds: Date().timeIntervalSince(REFERENCE_TIMEPOINT), preferredTimescale: CMTimeScale(frameRate))
                assetWriter.startSession(atSourceTime: currentTime)
                LOG("Asset writing session started at source time: \(currentTime.value) | \(currentTime.timescale)")
                sessionStarted = true
            }
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
    func status() -> AVAssetWriter.Status? {
        assetWriter?.status
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
    @PipelineActor public static let shared = AssetInterceptor()
    private let assetWriter = AssetWriterActor()
    private let fragmentSequenceNumber = fragmentSequenceNumberActor()
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
        guard await assetWriter.status() != .writing else {
            LOG("Asset writer had already started intercepting sample buffers", level: .debug)
            return
        }
        await self.assetWriter.setupAssetWriter()
        LOG("Asset writer is now intercepting sample buffers", level: .debug)
    }
    func endIntercepting() async {
        guard await assetWriter.status() == .writing else {
            LOG("Asset writer had already stopped intercepting sample buffers", level: .debug)
            return
        }
        await self.assetWriter.finishWriting()
        await self.fragmentSequenceNumber.reset()
        LOG("Asset writer is no longer intercepting sample buffers", level: .debug)
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
            Task { [self] in
                let sequenceNumber = await fragmentSequenceNumber.next()
                let fragment = Fragment(sequence: sequenceNumber, segment: segmentData, duration: duration, type: fragmentType)
                LOG("Produced \(fragment)", level: .debug)
                await FragmentPusher.shared.addFragment(fragment)
                await FragmentPusher.shared.uploadFragment(attempt: 1)
                saveFragmentToFile(fragment)
            }
        }
    }
    func saveFragmentToFile(_ fragment: Fragment) {
        let saveFragmentsLocally = Settings.saveFragmentsLocally
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
