//
// Produces Apple AVAssetWriter segmented-HLS fixtures from synthetic source media.
// Development tool only; it is not part of the Tubeist app target.
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

private enum AppleFixtureError: Error, CustomStringConvertible {
    case invalidArguments
    case missingTrack(String)
    case cannotConfigure(String)
    case readerFailed(String)
    case writerFailed(String)
    case noSegments

    var description: String {
        switch self {
        case .invalidArguments:
            "Usage: apple-fmp4-fixture <source.mp4> <output-directory> <frame-rate> <channels>"
        case .missingTrack(let media):
            "The source has no \(media) track"
        case .cannotConfigure(let detail):
            "Could not configure Apple media I/O: \(detail)"
        case .readerFailed(let detail):
            "AVAssetReader failed: \(detail)"
        case .writerFailed(let detail):
            "AVAssetWriter failed: \(detail)"
        case .noSegments:
            "AVAssetWriter did not emit initialization and media segments"
        }
    }
}

private final class SegmentCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let outputDirectory: URL
    private let lock = NSLock()
    private var mediaSequence = 0
    private var initializationCount = 0
    private var mediaCount = 0
    private var collectionError: Error?

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        lock.withLock {
            guard collectionError == nil else { return }
            let filename: String
            switch segmentType {
            case .initialization:
                initializationCount += 1
                filename = "initialization.mp4"
            case .separable:
                filename = String(format: "fragment_%03d.m4s", mediaSequence)
                mediaSequence += 1
                mediaCount += 1
            @unknown default:
                collectionError = AppleFixtureError.cannotConfigure("unknown AVAssetSegmentType")
                return
            }
            do {
                try segmentData.write(
                    to: outputDirectory.appendingPathComponent(filename),
                    options: .atomic
                )
            } catch {
                collectionError = error
            }
        }
    }

    func validate() throws {
        try lock.withLock {
            if let collectionError { throw collectionError }
            guard initializationCount == 1, mediaCount >= 3 else {
                throw AppleFixtureError.noSegments
            }
        }
    }
}

@main
private struct AppleFMP4FixtureTool {
    static func main() async throws {
        guard CommandLine.arguments.count == 5,
              let frameRate = Double(CommandLine.arguments[3]),
              let channels = Int(CommandLine.arguments[4]),
              frameRate > 0,
              channels == 1 || channels == 2 else {
            throw AppleFixtureError.invalidArguments
        }
        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppleFixtureError.missingTrack("video")
        }
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AppleFixtureError.missingTrack("audio")
        }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: nil
        )
        let audioOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: nil
        )
        guard reader.canAdd(videoOutput), reader.canAdd(audioOutput) else {
            throw AppleFixtureError.cannotConfigure("reader outputs")
        }
        reader.add(videoOutput)
        reader.add(audioOutput)

        guard let contentType = UTType(AVFileType.mp4.rawValue) else {
            throw AppleFixtureError.cannotConfigure("MPEG-4 content type")
        }
        let writer = AVAssetWriter(contentType: contentType)
        writer.shouldOptimizeForNetworkUse = true
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        // macOS does not permit two passthrough tracks with automatic segment
        // intervals. Manual keyframe-aligned flushes still exercise the same
        // Apple HLS fragment writer without invoking a host encoder.
        writer.preferredOutputSegmentInterval = .indefinite
        writer.movieTimeScale = 90_000
        writer.initialSegmentStartTime = .zero

        guard let videoFormatDescription = try await videoTrack.load(.formatDescriptions).first else {
            throw AppleFixtureError.cannotConfigure("HEVC source format description")
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormatDescription
        )
        guard let audioFormatDescription = try await audioTrack.load(.formatDescriptions).first else {
            throw AppleFixtureError.cannotConfigure("AAC source format description")
        }
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: audioFormatDescription
        )
        videoInput.expectsMediaDataInRealTime = false
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw AppleFixtureError.cannotConfigure("HEVC passthrough writer input")
        }
        writer.add(videoInput)
        guard writer.canAdd(audioInput) else {
            throw AppleFixtureError.cannotConfigure("AAC passthrough writer input")
        }
        writer.add(audioInput)

        let collector = SegmentCollector(outputDirectory: outputDirectory)
        writer.delegate = collector
        guard writer.startWriting() else {
            throw AppleFixtureError.writerFailed(String(describing: writer.error))
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw AppleFixtureError.readerFailed(reader.error?.localizedDescription ?? "startReading")
        }

        var videoSample = videoOutput.copyNextSampleBuffer()
        var audioSample = audioOutput.copyNextSampleBuffer()
        var nextSegmentBoundary = 1.0
        while videoSample != nil || audioSample != nil {
            let takeVideo: Bool
            if let videoSample, let audioSample {
                takeVideo = CMTimeCompare(
                    CMSampleBufferGetPresentationTimeStamp(videoSample),
                    CMSampleBufferGetPresentationTimeStamp(audioSample)
                ) <= 0
            } else {
                takeVideo = videoSample != nil
            }

            if takeVideo, let sample = videoSample {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if isRandomAccess(sample), presentationTime + 0.000_001 >= nextSegmentBoundary {
                    writer.flushSegment()
                    nextSegmentBoundary += 1
                }
                try await append(sample, to: videoInput, writer: writer)
                videoSample = videoOutput.copyNextSampleBuffer()
            } else if let sample = audioSample {
                try await append(sample, to: audioInput, writer: writer)
                audioSample = audioOutput.copyNextSampleBuffer()
            }
        }

        guard reader.status == .completed else {
            throw AppleFixtureError.readerFailed(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")
        }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw AppleFixtureError.writerFailed(String(describing: writer.error))
        }
        try collector.validate()
        print("Apple segmented fMP4 fixture created: \(outputDirectory.path)")
    }

    private static func isRandomAccess(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: false
        ) as? [[CFString: Any]],
        let first = attachments.first else {
            return true
        }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    @MainActor
    private static func append(
        _ sample: CMSampleBuffer,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw AppleFixtureError.writerFailed(
                    writer.error?.localizedDescription ?? "status \(writer.status.rawValue)"
                )
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard input.append(sample) else {
            throw AppleFixtureError.writerFailed(writer.error?.localizedDescription ?? "append")
        }
    }
}
