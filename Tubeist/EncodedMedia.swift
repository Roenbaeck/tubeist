import Foundation

/// Container-independent compressed samples. Signed timestamps are necessary
/// for the negative startup DTS produced by an encoder that uses B frames.
struct EncodedMediaSample: Sendable, Equatable {
    let trackID: UInt32
    let kind: ISOBMFFTrackKind
    let timescale: UInt32
    let decodeTime: Int64
    let presentationTime: Int64
    let duration: Int64
    let isRandomAccess: Bool
    let data: Data
}

struct EncodedMediaSegment: Sendable, Equatable {
    let samples: [EncodedMediaSample]
    let hevc: HEVCDecoderConfiguration
    let aac: AACDecoderConfiguration
    // Adjacent AAC packets can straddle a video boundary. EXTINF follows the
    // video boundary, not the union of packet extents (which accumulates drift).
    var presentationDuration: Double? = nil
}

/// Groups complete closed GOPs, waiting for audio to reach the next boundary.
/// Input video is in decode order; presentation order may differ inside a GOP.
struct EncodedSegmentAssembler {
    var hevc: HEVCDecoderConfiguration?
    var aac: AACDecoderConfiguration?
    private var video: [EncodedMediaSample] = []
    private var audio: [EncodedMediaSample] = []
    private var audioEnd = -Double.infinity
    private var lastDecodeTime: [UInt32: Double] = [:]
    let segmentDuration: Double

    init(segmentDuration: Double = 2) { self.segmentDuration = segmentDuration }

    mutating func append(_ sample: EncodedMediaSample) throws {
        guard sample.timescale > 0, sample.duration > 0 else {
            throw MPEGTransportStreamError.timestamp("invalid encoded sample timing")
        }
        let decodeTime = Double(sample.decodeTime) / Double(sample.timescale)
        guard lastDecodeTime[sample.trackID].map({ decodeTime > $0 }) ?? true else {
            throw MPEGTransportStreamError.timestamp("encoded decode times must increase within each track")
        }
        guard video.count < 2048, audio.count < 2048 else {
            throw MPEGTransportStreamError.malformedSample("encoded track queue exceeded its sample limit")
        }
        lastDecodeTime[sample.trackID] = decodeTime
        if sample.kind == .video {
            if video.isEmpty, !sample.isRandomAccess {
                throw MPEGTransportStreamError.malformedSample("video must start with a closed GOP")
            }
            video.append(sample)
        } else {
            audio.append(sample)
            audioEnd = max(audioEnd, seconds(sample) + Double(sample.duration) / Double(sample.timescale))
        }
        // A missing track or keyframe must fail explicitly, never grow memory
        // indefinitely or silently discard individual encoded frames.
        if let first = video.first, let last = video.last,
           seconds(last) - seconds(first) > 8 {
            throw MPEGTransportStreamError.malformedSample("encoded tracks did not reach a segment boundary")
        }
        if let first = audio.first, let last = audio.last,
           seconds(last) - seconds(first) > 8 {
            throw MPEGTransportStreamError.malformedSample("video did not catch up with encoded audio")
        }
    }

    mutating func takeReadySegments(finishing: Bool = false) throws -> [EncodedMediaSegment] {
        guard let hevc, let aac else {
            if finishing { throw MPEGTransportStreamError.missingConfiguration("encoded audio or video") }
            return []
        }
        var result: [EncodedMediaSegment] = []
        while let first = video.first {
            let tolerance = Double(first.duration) / Double(first.timescale) * 0.51
            guard let boundary = video.indices.dropFirst().first(where: {
                video[$0].isRandomAccess && seconds(video[$0]) - seconds(first) >= segmentDuration - tolerance
            }) else { break }
            let boundaryTime = seconds(video[boundary])
            guard audioEnd >= boundaryTime || finishing else { break }
            let precedingAudio = audio.prefix { seconds($0) < boundaryTime }
            guard !precedingAudio.isEmpty else {
                throw MPEGTransportStreamError.malformedSample("no audio for completed video segment")
            }
            result.append(EncodedMediaSegment(
                samples: Array(video[..<boundary]) + precedingAudio, hevc: hevc, aac: aac,
                presentationDuration: boundaryTime - seconds(first)
            ))
            video.removeFirst(boundary)
            audio.removeFirst(precedingAudio.count)
        }
        if finishing, !video.isEmpty || !audio.isEmpty {
            guard !video.isEmpty, !audio.isEmpty else {
                throw MPEGTransportStreamError.malformedSample("unmatched encoded audio/video tail")
            }
            let end = (video + audio).map { seconds($0) + Double($0.duration) / Double($0.timescale) }.max()!
            result.append(EncodedMediaSegment(samples: video + audio, hevc: hevc, aac: aac,
                                               presentationDuration: end - seconds(video[0])))
            video.removeAll()
            audio.removeAll()
        }
        return result
    }

    private func seconds(_ sample: EncodedMediaSample) -> Double {
        Double(sample.presentationTime) / Double(sample.timescale)
    }
}
