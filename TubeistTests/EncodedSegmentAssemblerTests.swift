import Foundation
import Testing
@testable import Tubeist

struct EncodedSegmentAssemblerTests {
    private let hevc = HEVCDecoderConfiguration(nalUnitLengthSize: 4,
        videoParameterSets: [Data([0x40, 1])], sequenceParameterSets: [Data([0x42, 1])], pictureParameterSets: [Data([0x44, 1])])
    private let aac = AACDecoderConfiguration(audioSpecificConfig: Data([0x12, 0x10]), audioObjectType: 2,
        samplingFrequencyIndex: 4, sampleRate: 44_100, channelConfiguration: 2)

    private func sample(_ kind: ISOBMFFTrackKind, pts: Int64, dts: Int64? = nil,
                        duration: Int64 = 500, sync: Bool = false) -> EncodedMediaSample {
        EncodedMediaSample(trackID: kind == .video ? 1 : 2, kind: kind, timescale: 1000,
            decodeTime: dts ?? pts, presentationTime: pts, duration: duration, isRandomAccess: sync,
            data: kind == .video ? Data([0, 0, 0, 3, 0x26, 1, 0]) : Data([1, 2, 3]))
    }

    @Test func boundaryWaitsForAudioAndPreservesDecodeOrder() throws {
        var assembler = EncodedSegmentAssembler()
        assembler.hevc = hevc
        assembler.aac = aac
        let video = [
            sample(.video, pts: 0, dts: -1000, sync: true),
            sample(.video, pts: 1500, dts: -500),
            sample(.video, pts: 500, dts: 0),
            sample(.video, pts: 1000, dts: 500),
            sample(.video, pts: 2000, dts: 1000, sync: true)
        ]
        for item in video { try assembler.append(item) }
        try assembler.append(sample(.audio, pts: -40, duration: 500))
        #expect(try assembler.takeReadySegments().isEmpty)
        for pts: Int64 in [460, 960, 1460, 1960] { try assembler.append(sample(.audio, pts: pts)) }
        // The packet at 1960 overlaps the boundary but remains in segment 0.
        #expect(try assembler.takeReadySegments().isEmpty)
        try assembler.append(sample(.audio, pts: 2460))
        let segments = try assembler.takeReadySegments()
        #expect(segments.count == 1)
        #expect(segments[0].samples.filter { $0.kind == .video } == Array(video.prefix(4)))
        #expect(segments[0].presentationDuration == 2)
        var muxer = MPEGTransportStreamMuxer()
        let ts = try muxer.mux(segments[0])
        #expect(ts.duration == 2)
        #expect(ts.data.count % 188 == 0)
        let tail = try assembler.takeReadySegments(finishing: true)
        #expect(tail.count == 1)
        #expect(tail[0].samples.filter { $0.kind == .video }.count == 1)
        #expect(try muxer.mux(tail[0]).startsWithRandomAccess)
    }

    @Test(arguments: [false, true])
    func stoppingJustAfterAKeyframeKeepsTheEntireMuxedTail(drainBeforeStop: Bool) throws {
        var assembler = EncodedSegmentAssembler()
        assembler.hevc = hevc
        assembler.aac = aac
        var video: [EncodedMediaSample] = []
        for pts: Int64 in [0, 500, 1000, 1500, 2000] {
            let item = sample(.video, pts: pts, duration: pts == 2000 ? 17 : 500,
                              sync: pts == 0 || pts == 2000)
            video.append(item)
            try assembler.append(item)
        }
        let audio = [0, 500, 1000, 1500].map { sample(.audio, pts: Int64($0)) }
        for item in audio { try assembler.append(item) }
        if drainBeforeStop { #expect(try assembler.takeReadySegments().isEmpty) }
        let segments = try assembler.takeReadySegments(finishing: true)
        #expect(segments.count == 1)
        #expect(segments[0].samples == video + audio)
        #expect(segments[0].presentationDuration == 2.017)
        var muxer = MPEGTransportStreamMuxer()
        #expect(try muxer.mux(segments[0]).duration == 2.017)
        #expect(try assembler.takeReadySegments(finishing: true).isEmpty)
    }

    @Test func errorsRetainTheirDiagnosticDetailInTheUILog() {
        let error = MPEGTransportStreamError.malformedSample("unmatched encoded audio/video tail")
        #expect(error.localizedDescription == "Malformed TS sample: unmatched encoded audio/video tail")
    }

    @Test func missingAudioAndUnmatchedTailFailExplicitly() throws {
        var assembler = EncodedSegmentAssembler()
        assembler.hevc = hevc
        assembler.aac = aac
        try assembler.append(sample(.video, pts: 0, sync: true))
        #expect(throws: MPEGTransportStreamError.self) { try assembler.takeReadySegments(finishing: true) }
        #expect(throws: MPEGTransportStreamError.self) { try assembler.append(sample(.video, pts: 9000, sync: true)) }
    }

    @Test func boundsSamplesEvenIfPresentationTimeStopsAdvancing() throws {
        var assembler = EncodedSegmentAssembler()
        try assembler.append(sample(.video, pts: 0, sync: true))
        for index in 0..<2048 {
            try assembler.append(sample(.audio, pts: 0, dts: Int64(index)))
        }
        #expect(throws: MPEGTransportStreamError.self) {
            try assembler.append(sample(.audio, pts: 0, dts: 2048))
        }
    }

    @Test func rejectsDuplicateDecodeTimesBeforeSegmentAssembly() throws {
        var assembler = EncodedSegmentAssembler()
        try assembler.append(sample(.audio, pts: 0))
        #expect(throws: MPEGTransportStreamError.self) {
            try assembler.append(sample(.audio, pts: 0))
        }
        #expect(throws: MPEGTransportStreamError.self) {
            try assembler.append(sample(.audio, pts: -1))
        }
    }

    @Test func unsignedArchiveTimestampOverflowThrowsInsteadOfTrapping() throws {
        let initData = ISOBMFFInitialization(tracks: [
            1: ISOBMFFTrack(id: 1, kind: .video, timescale: 1000, defaultSampleDuration: 0, defaultSampleSize: 0,
                           defaultSampleFlags: 0, hevc: hevc, aac: nil),
            2: ISOBMFFTrack(id: 2, kind: .audio, timescale: 1000, defaultSampleDuration: 0, defaultSampleSize: 0,
                           defaultSampleFlags: 0, hevc: nil, aac: aac)
        ])
        let media = ISOBMFFMediaSegment(sequenceNumber: nil, samples: [ISOBMFFSample(trackID: 1, kind: .video,
            decodeTime: .max, presentationTime: 0, duration: 1, isRandomAccess: true, data: Data([0]))])
        var muxer = MPEGTransportStreamMuxer()
        #expect(throws: MPEGTransportStreamError.self) { try muxer.mux(media, initialization: initData) }
    }
}
