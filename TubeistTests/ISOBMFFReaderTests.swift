//
//  ISOBMFFReaderTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct ISOBMFFReaderTests {
    @Test func parsesTubeistInitializationMetadata() throws {
        let initialization = try ISOBMFFReader().parseInitializationSegment(FMP4Fixture.initialization())

        let video = try #require(initialization.videoTrack)
        #expect(video.id == 1)
        #expect(video.timescale == 90_000)
        #expect(video.defaultSampleDuration == 3_000)
        #expect(video.hevc?.nalUnitLengthSize == 4)
        #expect(video.hevc?.videoParameterSets == [Data([0x40, 0x01])])
        #expect(video.hevc?.sequenceParameterSets == [Data([0x42, 0x01])])
        #expect(video.hevc?.pictureParameterSets == [Data([0x44, 0x01])])

        let audio = try #require(initialization.audioTrack)
        #expect(audio.id == 2)
        #expect(audio.timescale == 48_000)
        #expect(audio.defaultSampleDuration == 1_024)
        #expect(audio.aac?.audioObjectType == 2)
        #expect(audio.aac?.samplingFrequencyIndex == 3)
        #expect(audio.aac?.sampleRate == 48_000)
        #expect(audio.aac?.channelConfiguration == 2)
    }

    @Test func resolvesFragmentDefaultsOffsetsAndSignedCompositionTime() throws {
        let reader = ISOBMFFReader()
        let initialization = try reader.parseInitializationSegment(FMP4Fixture.initialization())
        let segment = try reader.parseMediaSegment(
            FMP4Fixture.mediaSegment(),
            initialization: initialization
        )

        #expect(segment.sequenceNumber == 7)
        #expect(segment.samples.count == 2)

        let video = try #require(segment.samples.first { $0.kind == .video })
        #expect(video.decodeTime == 1_000)
        #expect(video.presentationTime == 970)
        #expect(video.duration == 3_000) // tfhd overrides trex
        #expect(video.isRandomAccess)
        #expect(video.data == Data([0, 0, 0, 2, 0x26, 0x01]))

        let audio = try #require(segment.samples.first { $0.kind == .audio })
        #expect(audio.decodeTime == 480)
        #expect(audio.presentationTime == 480)
        #expect(audio.duration == 1_024) // resolved from trex
        #expect(audio.isRandomAccess)
        #expect(audio.data == Data([0xaa, 0xbb, 0xcc]))
    }

    @Test func rejectsSampleDataOutsideMdat() throws {
        let reader = ISOBMFFReader()
        let initialization = try reader.parseInitializationSegment(FMP4Fixture.initialization())
        var truncated = FMP4Fixture.mediaSegment()
        truncated.removeLast()

        do {
            _ = try reader.parseMediaSegment(truncated, initialization: initialization)
            Issue.record("Expected malformed media segment to be rejected")
        } catch let error as ISOBMFFError {
            guard case .malformed = error else {
                Issue.record("Expected malformed error, got \(error)")
                return
            }
        }
    }

    @Test func rejectsTruncatedBoxHeader() {
        do {
            _ = try ISOBMFFReader().parseInitializationSegment(Data([0, 0, 0]))
            Issue.record("Expected truncated box to be rejected")
        } catch let error as ISOBMFFError {
            #expect(error == .malformed("truncated box header"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func parsesExplicitAACSampleRate() throws {
        let explicitConfig = audioSpecificConfig(
            objectType: 2,
            frequencyIndex: 15,
            explicitSampleRate: 48_000,
            channels: 2
        )
        let initialization = try ISOBMFFReader().parseInitializationSegment(
            FMP4Fixture.initialization(audioSpecificConfig: explicitConfig)
        )
        #expect(initialization.audioTrack?.aac?.samplingFrequencyIndex == 15)
        #expect(initialization.audioTrack?.aac?.sampleRate == 48_000)
        #expect(initialization.audioTrack?.aac?.channelConfiguration == 2)
    }

    @Test func rejectsAllTruncatedFixturePrefixesWithoutTrapping() {
        let reader = ISOBMFFReader()
        let initializationData = FMP4Fixture.initialization()
        for length in 0..<initializationData.count {
            do {
                _ = try reader.parseInitializationSegment(initializationData.prefix(length))
                Issue.record("Unexpectedly accepted initialization prefix of \(length) bytes")
            } catch {
                // Every proper prefix is incomplete; the important invariant is
                // a typed failure rather than an unchecked read or trap.
            }
        }

        do {
            let initialization = try reader.parseInitializationSegment(initializationData)
            let mediaData = FMP4Fixture.mediaSegment()
            for length in 0..<mediaData.count {
                do {
                    _ = try reader.parseMediaSegment(
                        mediaData.prefix(length),
                        initialization: initialization
                    )
                    Issue.record("Unexpectedly accepted media prefix of \(length) bytes")
                } catch {
                    // Expected for every proper prefix.
                }
            }
        } catch {
            Issue.record("Fixture initialization unexpectedly failed: \(error)")
        }
    }

    @Test func rejectsInputDisproportionateSampleCountBeforeAllocating() throws {
        let reader = ISOBMFFReader()
        let initialization = try reader.parseInitializationSegment(FMP4Fixture.initialization())

        do {
            _ = try reader.parseMediaSegment(
                FMP4Fixture.mediaSegmentWithImpossibleSampleCount(),
                initialization: initialization
            )
            Issue.record("Expected impossible trun sample count to be rejected")
        } catch let error as ISOBMFFError {
            #expect(error == .malformed("trun sample count exceeds input size"))
        }
    }

    @Test func parsesEveryHEVCNALLengthFieldSize() throws {
        for lengthSize in 1...4 {
            let initialization = try ISOBMFFReader().parseInitializationSegment(
                FMP4Fixture.initialization(nalUnitLengthSize: lengthSize)
            )
            #expect(initialization.videoTrack?.hevc?.nalUnitLengthSize == lengthSize)
        }
    }

    @Test func parsesMultipleRunsAndExplicitBaseDataOffset() throws {
        let reader = ISOBMFFReader()
        let initialization = try reader.parseInitializationSegment(FMP4Fixture.initialization())
        let media = try reader.parseMediaSegment(
            FMP4Fixture.mediaSegmentWithMultipleVideoRuns(),
            initialization: initialization
        )
        let video = media.samples.filter { $0.kind == .video }
        #expect(video.count == 2)
        #expect(video.map(\.decodeTime) == [1_000, 4_000])
        #expect(video.map(\.presentationTime) == [970, 4_060])
        #expect(video.map(\.data) == [
            Data([0, 0, 0, 2, 0x26, 0x01]),
            Data([0, 0, 0, 2, 0x02, 0x01]),
        ])
    }

    @Test func acceptsExtendedAndToEndBoxSizes() throws {
        let initialization = try ISOBMFFReader().parseInitializationSegment(
            FMP4Fixture.initializationWithBoxSizeVariants()
        )
        #expect(initialization.videoTrack?.id == 1)
        #expect(initialization.audioTrack?.id == 2)
    }
}

enum FMP4Fixture {
    static func initialization(
        audioSpecificConfig: Data = Data([0x11, 0x90]),
        nalUnitLengthSize: Int = 4
    ) -> Data {
        let videoTrack = track(
            id: 1,
            timescale: 90_000,
            handler: "vide",
            sampleEntry: hevcSampleEntry(nalUnitLengthSize: nalUnitLengthSize)
        )
        let audioTrack = track(
            id: 2,
            timescale: 48_000,
            handler: "soun",
            sampleEntry: aacSampleEntry(audioSpecificConfig: audioSpecificConfig)
        )
        let movieExtends = box("mvex", box("trex", fullBoxPayload() +
            be32(1) + be32(1) + be32(3_000) + be32(0) + be32(0)) +
            box("trex", fullBoxPayload() +
                be32(2) + be32(1) + be32(1_024) + be32(0) + be32(0)))
        return box("ftyp", Data("iso6".utf8) + be32(0) + Data("iso6mp41".utf8)) +
            box("moov", videoTrack + audioTrack + movieExtends)
    }

    static func initializationWithBoxSizeVariants() -> Data {
        let extendedPayload = Data([1, 2, 3, 4])
        let extended = be32(1) + Data("free".utf8) +
            be64(UInt64(16 + extendedPayload.count)) + extendedPayload
        let toEnd = be32(0) + Data("free".utf8) + Data([5, 6, 7])
        return extended + initialization() + toEnd
    }

    static func mediaSegment(
        sequence: UInt32 = 7,
        videoDecodeTime: UInt64 = 1_000,
        audioDecodeTime: UInt64 = 480,
        videoIsRandomAccess: Bool = true
    ) -> Data {
        let videoData = Data([0, 0, 0, 2, 0x26, 0x01])
        let audioData = Data([0xaa, 0xbb, 0xcc])

        func movieFragment(videoOffset: Int32, audioOffset: Int32) -> Data {
            let videoHeader = box("tfhd", fullBoxPayload(flags: 0x020008) +
                be32(1) + be32(3_000))
            let videoDecodeTimeBox = box("tfdt", fullBoxPayload(version: 1) + be64(videoDecodeTime))
            let videoRun = box("trun", fullBoxPayload(version: 1, flags: 0x000f01) +
                be32(1) + be32(videoOffset) + be32(3_000) + be32(videoData.count) +
                be32(videoIsRandomAccess ? 0 : 0x0001_0000) + be32(Int32(-30)))

            let audioHeader = box("tfhd", fullBoxPayload(flags: 0x020000) + be32(2))
            let audioDecodeTimeBox = box("tfdt", fullBoxPayload(version: 1) + be64(audioDecodeTime))
            let audioRun = box("trun", fullBoxPayload(flags: 0x000201) +
                be32(1) + be32(audioOffset) + be32(audioData.count))

            return box("moof", box("mfhd", fullBoxPayload() + be32(sequence)) +
                box("traf", videoHeader + videoDecodeTimeBox + videoRun) +
                box("traf", audioHeader + audioDecodeTimeBox + audioRun))
        }

        let placeholder = movieFragment(videoOffset: 0, audioOffset: 0)
        let videoOffset = Int32(placeholder.count + 8)
        let audioOffset = videoOffset + Int32(videoData.count)
        let moof = movieFragment(videoOffset: videoOffset, audioOffset: audioOffset)
        return moof + box("mdat", videoData + audioData)
    }

    static func mediaSegmentWithMultipleVideoRuns() -> Data {
        let firstVideo = Data([0, 0, 0, 2, 0x26, 0x01])
        let secondVideo = Data([0, 0, 0, 2, 0x02, 0x01])
        let audio = Data([0xaa, 0xbb, 0xcc])

        func movieFragment(videoOffset: Int32, audioOffset: Int32) -> Data {
            let videoHeader = box("tfhd", fullBoxPayload(flags: 0x000009) +
                be32(1) + be64(0) + be32(3_000))
            let videoDecodeTime = box("tfdt", fullBoxPayload(version: 1) + be64(1_000))
            let firstRun = box("trun", fullBoxPayload(version: 1, flags: 0x000f01) +
                be32(1) + be32(videoOffset) + be32(3_000) + be32(firstVideo.count) +
                be32(0) + be32(Int32(-30)))
            let secondRun = box("trun", fullBoxPayload(version: 1, flags: 0x000f00) +
                be32(1) + be32(3_000) + be32(secondVideo.count) +
                be32(0x0001_0000) + be32(Int32(60)))

            let audioHeader = box("tfhd", fullBoxPayload(flags: 0x020000) + be32(2))
            let audioDecodeTime = box("tfdt", fullBoxPayload(version: 1) + be64(480))
            let audioRun = box("trun", fullBoxPayload(flags: 0x000201) +
                be32(1) + be32(audioOffset) + be32(audio.count))
            return box("moof", box("mfhd", fullBoxPayload() + be32(9)) +
                box("traf", videoHeader + videoDecodeTime + firstRun + secondRun) +
                box("traf", audioHeader + audioDecodeTime + audioRun))
        }

        let placeholder = movieFragment(videoOffset: 0, audioOffset: 0)
        let videoOffset = Int32(placeholder.count + 8)
        let audioOffset = videoOffset + Int32(firstVideo.count + secondVideo.count)
        return movieFragment(videoOffset: videoOffset, audioOffset: audioOffset) +
            box("mdat", firstVideo + secondVideo + audio)
    }

    static func mediaSegmentWithImpossibleSampleCount() -> Data {
        var segment = mediaSegment()
        let trun = segment.range(of: Data("trun".utf8))!
        let sampleCount = trun.upperBound + 4
        segment.replaceSubrange(sampleCount..<(sampleCount + 4), with: be32(UInt32.max))
        return segment
    }

    private static func track(id: UInt32, timescale: UInt32, handler: String, sampleEntry: Data) -> Data {
        let trackHeader = box("tkhd", fullBoxPayload() +
            be32(0) + be32(0) + be32(id) + be32(0) + be32(0))
        let mediaHeader = box("mdhd", fullBoxPayload() +
            be32(0) + be32(0) + be32(timescale) + be32(0))
        let handlerBox = box("hdlr", fullBoxPayload() + be32(0) + Data(handler.utf8))
        let sampleDescriptions = box("stsd", fullBoxPayload() + be32(1) + sampleEntry)
        let sampleTable = box("stbl", sampleDescriptions)
        return box("trak", trackHeader +
            box("mdia", mediaHeader + handlerBox + box("minf", sampleTable)))
    }

    private static func hevcSampleEntry(nalUnitLengthSize: Int) -> Data {
        precondition((1...4).contains(nalUnitLengthSize))
        var configuration = Data(repeating: 0, count: 23)
        configuration[0] = 1
        configuration[21] = UInt8(nalUnitLengthSize - 1)
        configuration[22] = 3
        configuration += nalArray(type: 32, bytes: [0x40, 0x01])
        configuration += nalArray(type: 33, bytes: [0x42, 0x01])
        configuration += nalArray(type: 34, bytes: [0x44, 0x01])
        return box("hvc1", Data(repeating: 0, count: 78) + box("hvcC", configuration))
    }

    private static func nalArray(type: UInt8, bytes: [UInt8]) -> Data {
        Data([type]) + be16(1) + be16(bytes.count) + Data(bytes)
    }

    private static func aacSampleEntry(audioSpecificConfig: Data) -> Data {
        let audioSpecificConfig = descriptor(tag: 0x05, payload: audioSpecificConfig)
        let decoderConfig = descriptor(
            tag: 0x04,
            payload: Data(repeating: 0, count: 13) + audioSpecificConfig
        )
        let elementaryStream = descriptor(
            tag: 0x03,
            payload: be16(1) + Data([0]) + decoderConfig
        )
        return box("mp4a", Data(repeating: 0, count: 28) +
            box("esds", fullBoxPayload() + elementaryStream))
    }

    private static func descriptor(tag: UInt8, payload: Data) -> Data {
        precondition(payload.count < 128)
        return Data([tag, UInt8(payload.count)]) + payload
    }

    private static func fullBoxPayload(version: UInt8 = 0, flags: UInt32 = 0) -> Data {
        Data([
            version,
            UInt8((flags >> 16) & 0xff),
            UInt8((flags >> 8) & 0xff),
            UInt8(flags & 0xff),
        ])
    }

    private static func box(_ type: String, _ payload: Data) -> Data {
        be32(payload.count + 8) + Data(type.utf8) + payload
    }

    private static func be16(_ value: Int) -> Data {
        Data([UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    private static func be32(_ value: Int) -> Data {
        be32(UInt32(value))
    }

    private static func be32(_ value: Int32) -> Data {
        be32(UInt32(bitPattern: value))
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    private static func be64(_ value: UInt64) -> Data {
        be32(UInt32(value >> 32)) + be32(UInt32(value & 0xffff_ffff))
    }
}

func audioSpecificConfig(
    objectType: UInt32,
    frequencyIndex: UInt32,
    explicitSampleRate: UInt32?,
    channels: UInt32
) -> Data {
    var bits: [UInt8] = []
    func append(_ value: UInt32, count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            bits.append(UInt8((value >> shift) & 1))
        }
    }
    append(objectType, count: 5)
    append(frequencyIndex, count: 4)
    if frequencyIndex == 15 {
        append(explicitSampleRate ?? 0, count: 24)
    }
    append(channels, count: 4)
    while !bits.count.isMultiple(of: 8) {
        bits.append(0)
    }
    return Data(stride(from: 0, to: bits.count, by: 8).map { start in
        bits[start..<(start + 8)].reduce(0) { ($0 << 1) | $1 }
    })
}
