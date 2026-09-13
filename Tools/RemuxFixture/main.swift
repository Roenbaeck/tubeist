// Development-only fixture remuxer.
//
// Build from the repository root:
//   xcrun swiftc -parse-as-library Tubeist/ISOBMFFReader.swift \
//     Tubeist/MPEGTransportStreamMuxer.swift Tools/RemuxFixture/main.swift \
//     -o /tmp/tubeist-remux-fixture
//
// Run with an initialization segment, an output directory, and ordered media
// fragments. FFmpeg/ffprobe remain external validation oracles, not app deps.

import Foundation

@main
enum RemuxFixture {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4 else {
            throw FixtureToolError.usage
        }

        let initializationURL = URL(fileURLWithPath: arguments[1])
        let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let fragmentURLs = arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let reader = ISOBMFFReader()
        let initialization = try reader.parseInitializationSegment(Data(contentsOf: initializationURL))
        guard let hevc = initialization.videoTrack?.hevc else {
            throw FixtureToolError.missingHEVCConfiguration
        }
        var muxer = MPEGTransportStreamMuxer()
        for (index, fragmentURL) in fragmentURLs.enumerated() {
            let media = try reader.parseMediaSegment(
                Data(contentsOf: fragmentURL),
                initialization: initialization
            )
            let segment = try muxer.mux(media, initialization: initialization)
            let outputURL = outputDirectory.appendingPathComponent(
                String(format: "segment_%04d.ts", index)
            )
            try segment.data.write(to: outputURL, options: .atomic)
            let videoSamples = media.samples.filter { $0.kind == .video }
            let audioSamples = media.samples.filter { $0.kind == .audio }
            let firstNALTypes = try videoSamples.first.map {
                try hevcNALUnitTypes(in: $0.data, lengthSize: hevc.nalUnitLengthSize)
            } ?? []
            print(
                "\(outputURL.lastPathComponent)\t\(segment.data.count) bytes\t\(segment.duration)s" +
                    "\tvideo=\(videoSamples.count) audio=\(audioSamples.count)" +
                    " first_nal_types=\(firstNALTypes.map(String.init).joined(separator: ","))"
            )
        }
    }

    private static func hevcNALUnitTypes(in data: Data, lengthSize: Int) throws -> [Int] {
        var offset = 0
        var result: [Int] = []
        while offset < data.count {
            guard offset + lengthSize <= data.count else {
                throw FixtureToolError.invalidHEVCSample
            }
            var nalSize = 0
            for byte in data[offset..<(offset + lengthSize)] {
                nalSize = (nalSize << 8) | Int(byte)
            }
            offset += lengthSize
            guard nalSize > 0, offset + nalSize <= data.count else {
                throw FixtureToolError.invalidHEVCSample
            }
            result.append(Int((data[offset] >> 1) & 0x3f))
            offset += nalSize
        }
        return result
    }
}

private enum FixtureToolError: LocalizedError {
    case usage
    case missingHEVCConfiguration
    case invalidHEVCSample

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: remux-fixture <initialization.mp4> <output-directory> <ordered.m4s> [...]"
        case .missingHEVCConfiguration:
            "The fixture initialization has no HEVC configuration"
        case .invalidHEVCSample:
            "A fixture contains a malformed length-prefixed HEVC sample"
        }
    }
}
