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
    private var writingFinished = false
    
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
            LOG("Could not set up video input", level: .error)
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
            LOG("Could not set up audio input", level: .error)
            return
        }
        audioInput.expectsMediaDataInRealTime = true
        
        assetWriter.add(videoInput)
        assetWriter.add(audioInput)

        writingFinished = false
        
        LOG("Asset writer configured successfully", level: .info)
    }
    
     func finishWriting() async {
         await withCheckedContinuation { continuation in
             guard let assetWriter else {
                 LOG("Asset writer not active or configured", level: .error)
                 continuation.resume() // Resume immediately if there's nothing to stop
                 return
             }
             self.writingFinished = true
             assetWriter.finishWriting {
                 if assetWriter.status == .failed {
                     LOG("Failed to finish writing: \(String(describing: assetWriter.error))", level: .warning)
                 } else {
                     LOG("Finished writing successfully", level: .info)
                 }
                 continuation.resume() // Resume after `finishWriting` completes
             }
         }
     }
     
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, inputType: String) {
        guard let input = input, !writingFinished else {
            LOG("\(inputType) input not configured or writing has finished", level: .warning)
            return
        }
        guard let assetWriter else {
            LOG("Asset writer not configured", level: .error)
            return
        }
        // Check and handle writer state
        if assetWriter.status == .unknown {
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        } else if assetWriter.status == .writing {
            // Already started, continue
        } else {
            LOG("AssetWriter in unexpected state: \(assetWriter.status.rawValue)", level: .error)
            return
        }

        // Append sample buffer
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        } else {
            LOG("\(inputType) input not ready for more media data", level: .warning)
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
        guard let ext = {
            switch segmentType {
            case .initialization: "mp4"
            case .separable: "m4s"
            @unknown default: nil
            }
        }() else {
            LOG("Unknown segment type", level: .error)
            return
        }
        let duration = (segmentReport?.trackReports.first?.duration.seconds ?? 2.0)
        if duration >= FRAGMENT_MINIMUM_DURATION {
            Task.detached { [self] in
                let sequenceNumber = await fragmentSequenceNumber.next()
                let fragment = Fragment(sequence: sequenceNumber, segment: segmentData, ext: ext, duration: duration)
                LOG("A fragment has been produced: \(fragment.sequence).\(fragment.ext) with duration \(fragment.duration)s", level: .debug)
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
            let ext = fragment.ext
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
