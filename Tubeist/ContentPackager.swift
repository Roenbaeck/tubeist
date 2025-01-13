//
//  ContentPackager.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

// @preconcurrency needed to pass CMSampleBuffer around
import AVFoundation
import VideoToolbox

enum MediaType {
    case audio
    case video
}

@PipelineActor
private class AssetWriterActor {
    private var fragmentAssetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var stream: Bool = Settings.stream
    private var record: Bool = Settings.record
    private var finalizing: Bool = false
    
    func setupFragmentAssetWriter() async {
        finalizing = false
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
        fragmentAssetWriter.preferredOutputSegmentInterval = CMTime(seconds: adjustedFragmentDuration, preferredTimescale: FRAGMENT_TIMESCALE)
        fragmentAssetWriter.movieTimeScale = FRAGMENT_TIMESCALE
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
        videoInput.mediaTimeScale = FRAGMENT_TIMESCALE
        
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

        guard fragmentAssetWriter.startWriting() else {
            LOG("Error starting writing: \(fragmentAssetWriter.error?.localizedDescription ?? "Unknown error")", level: .error)
            return
        }
        
        // fetch whether to stream or record or both
        stream = Settings.stream
        record = Settings.record

        guard let sessionTime = await CaptureDirector.shared.getSessionTime() else {
            LOG("Error getting session time", level: .error)
            return
        }

        let sessionTimeInFragmentTimescale = CMTimeConvertScale(sessionTime, timescale: FRAGMENT_TIMESCALE, method: .roundTowardZero)
        
        // starting the asset writer here seems to give it enough spin up time to avoid issues like no audio in the first fragment
        fragmentAssetWriter.startSession(atSourceTime: sessionTimeInFragmentTimescale)
        LOG("Asset writing started at time: \(sessionTime.value) | \(sessionTime.timescale) ticks")
    }
    
    func finishWriting() async {
        finalizing = true
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
        }
    }
    
    // this can be used to ensure that tampering with the contents of the sample buffer has not affected HDR
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
    
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input = input, input.isReadyForMoreMediaData else {
            LOG("Asset writer input not ready for more media data", level: .warning)
            return
        }
        if !input.append(sampleBuffer) {
            LOG("Failed to append sample buffer", level: .error)
        }
    }
        
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        appendSampleBuffer(sampleBuffer, to: videoInput)
    }
    
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        appendSampleBuffer(sampleBuffer, to: audioInput)
    }

    /*
    var interleaveTo: MediaType = .audio
        
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        while interleaveTo != .video && !finalizing {
            await Task.yield()
        }
        appendSampleBuffer(sampleBuffer, to: videoInput)
        interleaveTo = .audio
    }
    
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        while interleaveTo != .audio && !finalizing {
            await Task.yield()
        }
        appendSampleBuffer(sampleBuffer, to: audioInput)
        interleaveTo = .video
    }
     */

    func status() -> AVAssetWriter.Status? {
        fragmentAssetWriter?.status
    }

    func shouldStream() -> Bool {
        stream
    }
    
    func shouldRecord() -> Bool {
        record
    }
    
    func isFinalizing() -> Bool {
        finalizing
    }
}

actor FragmentSequenceNumberActor {
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
        fragmentSequenceNumber = -1
    }
}

actor RecordingActor {
    private var filename: String?
    private var fileHandle: FileHandle?
    private let recordingFolder: URL?
    init() {
        // Use a shared container that's accessible in Files app
        if let recordingFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            self.recordingFolder = recordingFolder
        }
        else {
            LOG("Could not access directory where fragments are stored", level: .error)
            self.recordingFolder = nil
        }
    }
    func new() {
        guard let recordingFolder else {
            LOG("The folder where recordings are supposed to be stored is not available", level: .error)
            return
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        filename = "recording_\(timestamp).mp4"
        let fileURL = recordingFolder.appendingPathComponent(filename!)
        do {
            try? FileManager.default.removeItem(at: fileURL)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
            fileHandle = try FileHandle(forWritingTo: fileURL)
        } catch {
            LOG("Error creating output file: \(error)", level: .error)
            fileHandle = nil
        }
    }
    func writeFragment(_ fragment: Fragment) {
        Task {
            if fragment.type == .initialization {
                LOG("Starting recording", level: .debug)
                new()
            }
            guard let fileHandle else {
                LOG("File handle is not initialized", level: .error)
                return
            }
            do {
                try fileHandle.write(contentsOf: fragment.segment)
                LOG("Appended fragment \(fragment.sequence) to file: \(filename ?? "<none>")", level: .debug)
            }
            catch {
                LOG("Recording error: \(error)", level: .error)
            }
            if fragment.type == .finalization {
                LOG("Stopping recording", level: .debug)
                try? fileHandle.close()
            }
        }
    }
    deinit {
        try? fileHandle?.close()
    }
}

final class ContentPackager: NSObject, AVAssetWriterDelegate, Sendable {
    @PipelineActor public static let shared = ContentPackager()
    @PipelineActor private static let assetWriter = AssetWriterActor()
    private let fragmentSequenceNumber = FragmentSequenceNumberActor()
    private let recording = RecordingActor()

    func beginPackaging() async {
        guard await ContentPackager.assetWriter.status() != .writing else {
            LOG("Asset writer had already started intercepting sample buffers", level: .debug)
            return
        }
        await ContentPackager.assetWriter.setupFragmentAssetWriter()
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
        Task { @PipelineActor in
            guard let fragmentType: Fragment.SegmentType = {
                switch (segmentType, ContentPackager.assetWriter.isFinalizing()) {
                case (.separable, false): .separable
                case (.initialization, _): .initialization
                case (.separable, true): .finalization
                @unknown default: nil
                }
            }() else {
                LOG("Unknown segment type", level: .error)
                return
            }
            let duration = segmentReport?.trackReports.first?.duration.seconds ?? 0
            let sequenceNumber = await fragmentSequenceNumber.next()
            let fragment = Fragment(sequence: sequenceNumber, segment: segmentData, duration: duration, type: fragmentType)
            LOG("Produced \(fragment)", level: .debug)
            
            if ContentPackager.assetWriter.shouldStream() {
                await FragmentPusher.shared.addFragment(fragment)
                await FragmentPusher.shared.uploadFragment(attempt: 1)
            }
            if ContentPackager.assetWriter.shouldRecord() {
                await recording.writeFragment(fragment)
            }
        }
    }
}
