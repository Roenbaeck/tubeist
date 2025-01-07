//
//  ContentPackager.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

// @preconcurrency needed to pass CMSampleBuffer around
import AVFoundation
import VideoToolbox

@PipelineActor
private class AssetWriterActor {
    private var fragmentAssetWriter: AVAssetWriter?
    private var fileAssetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    // these are used to ensure both audio and video goes into the initialization fragment
    private var firstVideoPresentationTimestamp: CMTime?
    private var firstAudioPresentationTimestamp: CMTime?
    private var earlyAudioSamples: [CMSampleBuffer] = []

    /*
    func setupFileAssetWriter(filename: URL?) {
        guard let filename else {
            LOG("No filename provided", level: .error)
            return
        }
        fileAssetWriter = try? AVAssetWriter(outputURL: filename, fileType: .mp4)
        guard let fileAssetWriter else {
            LOG("Could not create asset writer", level: .error)
            return
        }
        let selectedPreset = Settings.selectedPreset
        let selectedVideoBitrate = selectedPreset.videoBitrate
        let selectedAudioBitrate = selectedPreset.audioBitrate
        let selectedAudioChannels = selectedPreset.audioChannels
        let selectedWidth = selectedPreset.width
        let selectedHeight = selectedPreset.height
        let selectedKeyframeInterval = selectedPreset.keyframeInterval
        let selectedFrameRate = selectedPreset.frameRate
        let frameIntervalKey = Int(ceil(selectedKeyframeInterval * selectedFrameRate))
        let adjustedFragmentDuration = selectedFrameRate / trunc(selectedFrameRate / FRAGMENT_DURATION)
        
        fileAssetWriter.shouldOptimizeForNetworkUse = false
        fileAssetWriter.movieTimeScale = CMTimeScale(selectedFrameRate)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Settings.isInputSyncedWithOutput ? selectedWidth : DEFAULT_CAPTURE_WIDTH,
            AVVideoHeightKey: Settings.isInputSyncedWithOutput ? selectedHeight : DEFAULT_CAPTURE_HEIGHT,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoAverageBitRateKey: Settings.isInputSyncedWithOutput ? selectedVideoBitrate : 20_000_000, // TODO: additional setting for file
                AVVideoExpectedSourceFrameRateKey: selectedFrameRate,
                AVVideoMaxKeyFrameIntervalKey: frameIntervalKey,
                AVVideoAllowFrameReorderingKey: true,
                kVTCompressionPropertyKey_HDRMetadataInsertionMode: kVTHDRMetadataInsertionMode_Auto
            ]
        ]
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.mediaTimeScale = CMTimeScale(selectedFrameRate)
        
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AUDIO_SAMPLE_RATE,
            AVNumberOfChannelsKey: selectedAudioChannels,
            AVEncoderBitRatePerChannelKey: selectedAudioBitrate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Variable
        ]
        
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        
        fileAssetWriter.add(videoInput)
        fileAssetWriter.add(audioInput)
        
        LOG("Asset writer configured successfully", level: .info)

    }
    */
    
    func setupFragmentAssetWriter() {
        guard let contentType = UTType(AVFileType.mp4.rawValue) else {
            LOG("MP4 is not a valid type", level: .error)
            return
        }
        fragmentAssetWriter = AVAssetWriter(contentType: contentType)
        guard let fragmentAssetWriter else {
            LOG("Could not create asset writer", level: .error)
            return
        }
        let selectedPreset = Settings.selectedPreset
        let selectedVideoBitrate = selectedPreset.videoBitrate
        let selectedAudioBitrate = selectedPreset.audioBitrate
        let selectedAudioChannels = selectedPreset.audioChannels
        let selectedWidth = selectedPreset.width
        let selectedHeight = selectedPreset.height
        let selectedKeyframeInterval = selectedPreset.keyframeInterval
        let selectedFrameRate = selectedPreset.frameRate
        let frameIntervalKey = Int(ceil(selectedKeyframeInterval * selectedFrameRate))
        let adjustedFragmentDuration = selectedFrameRate / trunc(selectedFrameRate / FRAGMENT_DURATION)

        LOG("\(selectedPreset.description)", level: .debug)
        
        fragmentAssetWriter.shouldOptimizeForNetworkUse = true
        fragmentAssetWriter.outputFileTypeProfile = .mpeg4AppleHLS
        fragmentAssetWriter.preferredOutputSegmentInterval = CMTime(seconds: adjustedFragmentDuration, preferredTimescale: CMTimeScale(selectedFrameRate))
        fragmentAssetWriter.movieTimeScale = CMTimeScale(selectedFrameRate)
        fragmentAssetWriter.initialSegmentStartTime = .zero
        fragmentAssetWriter.delegate = ContentPackager.shared
        
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
        videoInput.mediaTimeScale = CMTimeScale(selectedFrameRate)
        
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AUDIO_SAMPLE_RATE,
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
        
        fragmentAssetWriter.add(videoInput)
        fragmentAssetWriter.add(audioInput)
        
        LOG("Asset writer configured successfully", level: .info)
    }
    
     func finishWriting() async {
         await withCheckedContinuation { continuation in
             guard let fragmentAssetWriter else {
                 LOG("Asset writer not active or configured", level: .error)
                 continuation.resume() // Resume immediately if there's nothing to stop
                 return
             }
             self.videoInput?.markAsFinished()
             self.audioInput?.markAsFinished()
             nonisolated(unsafe) let sendableAssetWriter = fragmentAssetWriter
             fragmentAssetWriter.finishWriting {
                 if sendableAssetWriter.status != .completed {
                     LOG("Failed to finish writing: \(String(describing: sendableAssetWriter.error))", level: .warning)
                 } else {
                     LOG("Finished writing successfully", level: .info)
                 }
                 continuation.resume() // Resume after `finishWriting` completes
             }
             self.fragmentAssetWriter = nil
             self.videoInput = nil
             self.audioInput = nil
             self.firstVideoPresentationTimestamp = nil
             self.sessionStarted = false
         }
     }
     
    private let startSessionOnceLock = NSLock()
    private var sessionStarted: Bool = false
    
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, inputType: String) {
        guard let input = input, input.isReadyForMoreMediaData else {
            LOG("\(inputType) input not ready for more media data", level: .warning)
            return
        }
        guard input.append(sampleBuffer) else {
            LOG("Error appending \(inputType.lowercased()) buffer", level: .error)
            return
        }
    }
    
    func analyzeVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            var formatName = "Unknown"
            
            switch format {
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: formatName = "420YpCbCr10BiPlanarVideoRange (x420)"
            case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: formatName = "422YpCbCr10BiPlanarVideoRange (x422)"
            default: formatName = String(format: "0x%08x", format)
            }
            
            var isHDR = false
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
               let attachments = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any] {
                // Check for HDR metadata
                if let colorPrimaries = attachments[kCVImageBufferColorPrimariesKey as String] as? String,
                   let transferFunction = attachments[kCVImageBufferTransferFunctionKey as String] as? String,
                   let yCbCrMatrix = attachments[kCVImageBufferYCbCrMatrixKey as String] as? String {
                    
                    isHDR = (colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String) &&
                            (transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) &&
                            (yCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_2020 as String)
                }
            }
            LOG("Video format of first frame: \(formatName), HDR: \(isHDR)", level: .info)
        }
    }
    
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let fragmentAssetWriter else {
            LOG("Cannot append video frame, asset writer not initialized", level: .warning)
            return
        }
        guard firstAudioPresentationTimestamp != nil else {
            LOG("Waiting for first audio to arrive before capturing video", level: .debug)
            return
        }
        if !sessionStarted { // more than one thread might enter here
            startSessionOnceLock.lock() // first thread to reach this point aquires the lock and the rest are blocked
            defer { startSessionOnceLock.unlock() } // ensure unlock, releasing any other threads
            if !sessionStarted { // check again, first thread will enter and set sessionStarted to true, so released threads won't execute this code
                guard fragmentAssetWriter.startWriting() else {
                    LOG("Error starting writing: \(fragmentAssetWriter.error?.localizedDescription ?? "Unknown error")")
                    return
                }
                analyzeVideoSampleBuffer(sampleBuffer)
                let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                fragmentAssetWriter.startSession(atSourceTime: presentationTimeStamp)
                LOG("Asset writing session started at time of first video frame: \(presentationTimeStamp)")
                firstVideoPresentationTimestamp = presentationTimeStamp
                sessionStarted = true
            }
        }
        appendSampleBuffer(sampleBuffer, to: videoInput, inputType: "Video")
    }
    
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if firstVideoPresentationTimestamp != nil {
            if !earlyAudioSamples.isEmpty { // prune buffer from unusable samples once a video frame has arrived
                LOG("Releasing \(earlyAudioSamples.count) audio samples that came in earlier than any video frames", level: .debug)
                earlyAudioSamples.removeAll(where: { CMSampleBufferGetPresentationTimeStamp($0) < firstVideoPresentationTimestamp! })
                for sampleBuffer in earlyAudioSamples {
                    appendSampleBuffer(sampleBuffer, to: audioInput, inputType: "Audio")
                }
                earlyAudioSamples.removeAll()
            }
            appendSampleBuffer(sampleBuffer, to: audioInput, inputType: "Audio")
        }
        else {
            let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            firstAudioPresentationTimestamp = presentationTimeStamp
            earlyAudioSamples.append(sampleBuffer) // buffer samples coming in before video
        }
    }
    
    func status() -> AVAssetWriter.Status? {
        fragmentAssetWriter?.status
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

final class ContentPackager: NSObject, AVAssetWriterDelegate, Sendable {
    @PipelineActor public static let shared = ContentPackager()
    @PipelineActor private static let assetWriter = AssetWriterActor()
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
    func beginPackaging() async {
        guard await ContentPackager.assetWriter.status() != .writing else {
            LOG("Asset writer had already started intercepting sample buffers", level: .debug)
            return
        }
        await ContentPackager.assetWriter.setupFragmentAssetWriter()
        /*
        let filename = fragmentFolderURL?.appendingPathComponent("DataFiles").appendingPathComponent("movie.mp4")
        await ContentPackager.assetWriter.setupFileAssetWriter(filename: filename)
        */
        LOG("Asset writer is now intercepting sample buffers", level: .debug)
    }
    func endPackaging() async {
        guard await ContentPackager.assetWriter.status() == .writing else {
            LOG("Asset writer had already stopped intercepting sample buffers", level: .debug)
            return
        }
        await ContentPackager.assetWriter.finishWriting()
        await self.fragmentSequenceNumber.reset()
        LOG("Asset writer is no longer intercepting sample buffers", level: .debug)
    }

    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer
        await ContentPackager.assetWriter.appendVideoSampleBuffer(sendableSampleBuffer)
    }
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer
        await ContentPackager.assetWriter.appendAudioSampleBuffer(sendableSampleBuffer)
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
