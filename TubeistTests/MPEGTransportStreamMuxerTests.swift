//
//  MPEGTransportStreamMuxerTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct MPEGTransportStreamMuxerTests {
    @Test(arguments: [false, true])
    func startsEveryHEVCAccessUnitWithExactlyOneDelimiter(existingDelimiter: Bool) throws {
        let initialization = try ISOBMFFReader().parseInitializationSegment(FMP4Fixture.initialization())
        let aud: [UInt8] = [0x46, 0x01, existingDelimiter ? 0x10 : 0x50]
        let video: [ISOBMFFSample] = (0..<2).map { index in
            let picture: [UInt8] = [index == 0 ? 0x26 : 0x02, 0x01]
            let prefix = existingDelimiter ? lengthPrefixedNAL(aud) : Data()
            let data = prefix + lengthPrefixedNAL(picture)
            return sample(trackID: 1, kind: .video, decodeTime: UInt64(index * 3_000),
                          presentationTime: Int64(index * 3_000), duration: 3_000,
                          randomAccess: index == 0, data: data)
        }
        var muxer = MPEGTransportStreamMuxer()
        let output = try muxer.mux(
            ISOBMFFMediaSegment(sequenceNumber: 1, samples: video + [defaultAudioSample()]),
            initialization: initialization
        )
        let starts = transportPackets(output.data).filter {
            pid(of: $0) == MPEGTransportStreamMuxer.videoPID && hasPayloadUnitStart($0)
        }
        #expect(starts.count == 2)
        for (index, packet) in starts.enumerated() {
            let pesStart = payloadStart(of: packet)
            let elementaryStart = pesStart + 9 + Int(packet[pesStart + 8])
            #expect(Array(packet[elementaryStart..<(elementaryStart + 7)]) == [0, 0, 0, 1] + aud)
            // Parameter sets follow the delimiter on keyframes; other frames
            // immediately retain their original coded picture NAL.
            #expect(Array(packet[(elementaryStart + 7)..<(elementaryStart + 13)])
                    == [0, 0, 0, 1, index == 0 ? 0x40 : 0x02, 0x01])
        }
        #expect(occurrences(of: [0, 0, 0, 1] + aud, in: output.data) == 2)
        #expect(occurrences(of: [0, 0, 0, 1, 0x26, 0x01], in: output.data) == 1)
        #expect(occurrences(of: [0, 0, 0, 1, 0x02, 0x01], in: output.data) == 1)
    }

    @Test func discontinuityPreservesElementaryPayloadAndProgramTables() throws {
        let reader = ISOBMFFReader()
        let initialization = try reader.parseInitializationSegment(FMP4Fixture.initialization())
        let media = try reader.parseMediaSegment(FMP4Fixture.mediaSegment(), initialization: initialization)
        var muxer = MPEGTransportStreamMuxer()
        let original = try muxer.mux(media, initialization: initialization).data
        let marked = try MPEGTransportStreamMuxer.markingDiscontinuity(original)
        let before = transportPackets(original)
        let after = transportPackets(marked)
        #expect(pid(of: after[0]) == MPEGTransportStreamMuxer.programAssociationPID)
        #expect(pid(of: after[1]) == MPEGTransportStreamMuxer.programMapPID)
        #expect(sectionHasValidCRC(after[0]))
        #expect(sectionHasValidCRC(after[1]))
        for track in [MPEGTransportStreamMuxer.videoPID, MPEGTransportStreamMuxer.audioPID] {
            let first = try #require(after.first { pid(of: $0) == track })
            #expect(first[3] & 0x20 != 0)
            #expect(first[5] & 0x80 != 0)
            func payload(_ packets: [[UInt8]]) -> [UInt8] {
                packets.filter { pid(of: $0) == track && $0[3] & 0x10 != 0 }
                    .flatMap { Array($0[payloadStart(of: $0)...]) }
            }
            #expect(payload(before) == payload(after))
        }
        #expect(try MPEGTransportStreamMuxer.markingDiscontinuity(marked) == marked)
    }

    @Test func emitsConformantTablesElementaryStreamsAndTimestamps() throws {
        let reader = ISOBMFFReader()
        let initialization = try reader.parseInitializationSegment(FMP4Fixture.initialization())
        let media = try reader.parseMediaSegment(
            FMP4Fixture.mediaSegment(),
            initialization: initialization
        )
        var muxer = MPEGTransportStreamMuxer()
        let segment = try muxer.mux(media, initialization: initialization)
        let packets = transportPackets(segment.data)

        #expect(!packets.isEmpty)
        #expect(packets.allSatisfy { $0.count == 188 && $0[0] == 0x47 })
        #expect(pid(of: packets[0]) == MPEGTransportStreamMuxer.programAssociationPID)
        #expect(pid(of: packets[1]) == MPEGTransportStreamMuxer.programMapPID)
        #expect(hasPayloadUnitStart(packets[0]))
        #expect(hasPayloadUnitStart(packets[1]))
        #expect(sectionHasValidCRC(packets[0]))
        #expect(sectionHasValidCRC(packets[1]))

        let pmt = packets[1]
        #expect(pmt[17] == 0x24)
        #expect(UInt16(pmt[18] & 0x1f) << 8 | UInt16(pmt[19]) == MPEGTransportStreamMuxer.videoPID)
        #expect(pmt[22] == 0x0f)
        #expect(UInt16(pmt[23] & 0x1f) << 8 | UInt16(pmt[24]) == MPEGTransportStreamMuxer.audioPID)

        #expect(contains([0, 0, 0, 1, 0x40, 0x01], in: segment.data))
        #expect(contains([0, 0, 0, 1, 0x42, 0x01], in: segment.data))
        #expect(contains([0, 0, 0, 1, 0x44, 0x01], in: segment.data))
        #expect(contains([0, 0, 0, 1, 0x26, 0x01], in: segment.data))
        #expect(contains([0xff, 0xf1, 0x4c, 0x80, 0x01, 0x5f, 0xfc, 0xaa], in: segment.data))

        let videoPacket = try #require(packets.first {
            pid(of: $0) == MPEGTransportStreamMuxer.videoPID && hasPayloadUnitStart($0)
        })
        let audioPacket = try #require(packets.first {
            pid(of: $0) == MPEGTransportStreamMuxer.audioPID && hasPayloadUnitStart($0)
        })
        let videoPES = payloadStart(of: videoPacket)
        let audioPES = payloadStart(of: audioPacket)
        #expect(Array(videoPacket[videoPES..<(videoPES + 4)]) == [0, 0, 1, 0xe0])
        #expect(Array(audioPacket[audioPES..<(audioPES + 4)]) == [0, 0, 1, 0xc0])
        #expect(videoPacket[videoPES + 4] == 0 && videoPacket[videoPES + 5] == 0)
        #expect(audioPacket[audioPES + 4] != 0 || audioPacket[audioPES + 5] != 0)
        #expect(decodeTimestamp(videoPacket, at: videoPES + 9) == 90_070)
        #expect(decodeTimestamp(videoPacket, at: videoPES + 14) == 90_100)
        #expect(decodeTimestamp(audioPacket, at: audioPES + 9) == 90_000)

        #expect(videoPacket[3] & 0x30 == 0x30)
        #expect(videoPacket[5] & 0x50 == 0x50) // random_access_indicator and PCR_flag
        #expect(decodePCR(videoPacket) == 27_100)
        #expect(segment.startsWithRandomAccess)
        #expect(segment.firstPresentationTimestamp == 90_000)
        #expect(segment.lastPresentationTimestamp == 93_070)
    }

    @Test func preservesContinuityCountersAndTimestampEpochAcrossSegments() throws {
        let reader = ISOBMFFReader()
        let initialization = try reader.parseInitializationSegment(FMP4Fixture.initialization())
        let firstMedia = try reader.parseMediaSegment(
            FMP4Fixture.mediaSegment(),
            initialization: initialization
        )
        let secondMedia = try reader.parseMediaSegment(
            FMP4Fixture.mediaSegment(
                sequence: 8,
                videoDecodeTime: 4_000,
                audioDecodeTime: 2_080
            ),
            initialization: initialization
        )
        var muxer = MPEGTransportStreamMuxer()
        let first = try muxer.mux(firstMedia, initialization: initialization)
        let second = try muxer.mux(secondMedia, initialization: initialization)

        let packets = transportPackets(first.data) + transportPackets(second.data)
        for packetPID in [
            MPEGTransportStreamMuxer.programAssociationPID,
            MPEGTransportStreamMuxer.programMapPID,
            MPEGTransportStreamMuxer.videoPID,
            MPEGTransportStreamMuxer.audioPID,
        ] {
            let counters = packets.filter { pid(of: $0) == packetPID }.map { $0[3] & 0x0f }
            #expect(zip(counters, counters.dropFirst()).allSatisfy { (($0 + 1) & 0x0f) == $1 })
        }

        let secondVideo = try #require(transportPackets(second.data).first {
            pid(of: $0) == MPEGTransportStreamMuxer.videoPID && hasPayloadUnitStart($0)
        })
        let secondVideoPES = payloadStart(of: secondVideo)
        #expect(decodeTimestamp(secondVideo, at: secondVideoPES + 9) == 93_070)
        #expect(decodeTimestamp(secondVideo, at: secondVideoPES + 14) == 93_100)
        #expect(decodePCR(secondVideo) == 30_100)
        #expect(secondVideo[5] & 0x40 == 0x40)
        #expect(second.startsWithRandomAccess)
    }

    @Test func refusesAFragmentThatDoesNotBeginAtRandomAccess() throws {
        let reader = ISOBMFFReader()
        let initialization = try reader.parseInitializationSegment(FMP4Fixture.initialization())
        let media = try reader.parseMediaSegment(
            FMP4Fixture.mediaSegment(videoIsRandomAccess: false),
            initialization: initialization
        )
        var muxer = MPEGTransportStreamMuxer()
        do {
            _ = try muxer.mux(media, initialization: initialization)
            Issue.record("Expected non-random-access fragment to be rejected")
        } catch let error as MPEGTransportStreamError {
            #expect(error == .malformedSample("segment does not begin with a random-access video sample"))
        }
    }

    @Test func repeatsProgramTablesAndHandlesPacketStuffingBoundaries() throws {
        let initialization = try ISOBMFFReader().parseInitializationSegment(FMP4Fixture.initialization())
        for audioSize in 1...184 {
            let video = sample(
                trackID: 1,
                kind: .video,
                decodeTime: 0,
                presentationTime: 0,
                duration: 3_000,
                randomAccess: true,
                data: lengthPrefixedNAL([0x26, 0x01])
            )
            let audio = sample(
                trackID: 2,
                kind: .audio,
                decodeTime: 0,
                presentationTime: 0,
                duration: 1_024,
                randomAccess: true,
                data: Data(repeating: 0xaa, count: audioSize)
            )
            var muxer = MPEGTransportStreamMuxer()
            let output = try muxer.mux(
                ISOBMFFMediaSegment(sequenceNumber: 1, samples: [video, audio]),
                initialization: initialization
            )
            let packets = transportPackets(output.data)
            #expect(packets.allSatisfy { packet in
                guard packet.count == 188, packet[0] == 0x47 else { return false }
                let control = (packet[3] >> 4) & 0x03
                guard control == 1 || control == 3 else { return false }
                return control != 3 || Int(packet[4]) <= 183
            })
        }

        let spacedVideo = [0, 9_000, 18_000].enumerated().map { index, time in
            sample(
                trackID: 1,
                kind: .video,
                decodeTime: UInt64(time),
                presentationTime: Int64(time),
                duration: 3_000,
                randomAccess: index == 0,
                data: lengthPrefixedNAL([index == 0 ? 0x26 : 0x02, 0x01])
            )
        }
        var muxer = MPEGTransportStreamMuxer()
        let output = try muxer.mux(
            ISOBMFFMediaSegment(
                sequenceNumber: 2,
                samples: spacedVideo + [defaultAudioSample()]
            ),
            initialization: initialization
        )
        let tablePIDs = transportPackets(output.data).map(pid(of:))
        #expect(tablePIDs.filter { $0 == MPEGTransportStreamMuxer.programAssociationPID }.count == 3)
        #expect(tablePIDs.filter { $0 == MPEGTransportStreamMuxer.programMapPID }.count == 3)
    }

    @Test func wrapsThirtyThreeBitTimestampsWithoutResettingTheSessionEpoch() throws {
        let initialization = try ISOBMFFReader().parseInitializationSegment(FMP4Fixture.initialization())
        var muxer = MPEGTransportStreamMuxer()
        let first = sample(
            trackID: 1,
            kind: .video,
            decodeTime: 0,
            presentationTime: 0,
            duration: 3_000,
            randomAccess: true,
            data: lengthPrefixedNAL([0x26, 0x01])
        )
        _ = try muxer.mux(
            ISOBMFFMediaSegment(sequenceNumber: 1, samples: [first, defaultAudioSample()]),
            initialization: initialization
        )

        let nearWrap = (UInt64(1) << 33) - 45_000
        let wrapped = sample(
            trackID: 1,
            kind: .video,
            decodeTime: nearWrap,
            presentationTime: Int64(nearWrap),
            duration: 3_000,
            randomAccess: true,
            data: lengthPrefixedNAL([0x26, 0x01])
        )
        let output = try muxer.mux(
            ISOBMFFMediaSegment(
                sequenceNumber: 2,
                samples: [
                    wrapped,
                    defaultAudioSample(decodeTime: nearWrap * 48_000 / 90_000),
                ]
            ),
            initialization: initialization
        )
        let videoPacket = try #require(transportPackets(output.data).first {
            pid(of: $0) == MPEGTransportStreamMuxer.videoPID && hasPayloadUnitStart($0)
        })
        let pes = payloadStart(of: videoPacket)
        #expect(decodeTimestamp(videoPacket, at: pes + 9) == 45_000)
        // DTS has wrapped, but its earlier PCR has not yet wrapped.
        #expect(decodePCR(videoPacket) == (UInt64(1) << 33) - 18_000)
    }

    @Test func decoderMarginPreservesReorderedMediaTimingAndResetsWithTheSession() throws {
        let initialization = try ISOBMFFReader().parseInitializationSegment(FMP4Fixture.initialization())
        let hevc = try #require(initialization.videoTrack?.hevc)
        let aac = try #require(initialization.audioTrack?.aac)
        let video = [Int64(0), 6_000, 3_000].enumerated().map { index, pts in
            EncodedMediaSample(trackID: 1, kind: .video, timescale: 90_000,
                decodeTime: -12_000 + Int64(index) * 3_000, presentationTime: pts,
                duration: 3_000, isRandomAccess: index == 0,
                data: lengthPrefixedNAL([index == 0 ? 0x26 : 0x02, 0x01]))
        }
        let audio = EncodedMediaSample(trackID: 2, kind: .audio, timescale: 48_000,
            decodeTime: 0, presentationTime: 0, duration: 1_024,
            isRandomAccess: true, data: Data([0xaa, 0xbb, 0xcc]))
        let source = EncodedMediaSegment(samples: video + [audio], hevc: hevc, aac: aac,
                                         presentationDuration: 0.1)
        var muxer = MPEGTransportStreamMuxer()
        let output = try muxer.mux(source)
        let packets = transportPackets(output.data)
        let pictures = packets.filter { pid(of: $0) == MPEGTransportStreamMuxer.videoPID && hasPayloadUnitStart($0) }
        #expect(pictures.map { decodeTimestamp($0, at: payloadStart(of: $0) + 9) } == [102_000, 108_000, 105_000])
        #expect(pictures.map { decodeTimestamp($0, at: payloadStart(of: $0) + 14) } == [90_000, 93_000, 96_000])
        #expect(pictures.compactMap(decodePCR) == [27_000, 30_000, 33_000])
        let audioPacket = try #require(packets.first { pid(of: $0) == MPEGTransportStreamMuxer.audioPID })
        #expect(decodeTimestamp(audioPacket, at: payloadStart(of: audioPacket) + 9) == 102_000)
        #expect(output.duration == 0.1)
        muxer.reset()
        #expect(try muxer.mux(source) == output)
    }

    @Test func convertsEveryConfiguredHEVCNALLengthSizeToAnnexB() throws {
        for lengthSize in 1...4 {
            let initialization = try ISOBMFFReader().parseInitializationSegment(
                FMP4Fixture.initialization(nalUnitLengthSize: lengthSize)
            )
            let video = sample(
                trackID: 1,
                kind: .video,
                decodeTime: 0,
                presentationTime: 0,
                duration: 3_000,
                randomAccess: true,
                data: lengthPrefixedNAL([0x26, 0x01], lengthSize: lengthSize)
            )
            var muxer = MPEGTransportStreamMuxer()
            let output = try muxer.mux(
                ISOBMFFMediaSegment(sequenceNumber: 1, samples: [video, defaultAudioSample()]),
                initialization: initialization
            )
            #expect(contains([0, 0, 0, 1, 0x26, 0x01], in: output.data))
        }
    }

    @Test func doesNotDuplicateInBandHEVCParameterSets() throws {
        let initialization = try ISOBMFFReader().parseInitializationSegment(FMP4Fixture.initialization())
        let accessUnit = lengthPrefixedNAL([0x40, 0x01]) +
            lengthPrefixedNAL([0x42, 0x01]) +
            lengthPrefixedNAL([0x44, 0x01]) +
            lengthPrefixedNAL([0x26, 0x01])
        let video = sample(
            trackID: 1,
            kind: .video,
            decodeTime: 0,
            presentationTime: 0,
            duration: 3_000,
            randomAccess: true,
            data: accessUnit
        )
        var muxer = MPEGTransportStreamMuxer()
        let output = try muxer.mux(
            ISOBMFFMediaSegment(sequenceNumber: 1, samples: [video, defaultAudioSample()]),
            initialization: initialization
        )
        #expect(occurrences(of: [0, 0, 0, 1, 0x40, 0x01], in: output.data) == 1)
        #expect(occurrences(of: [0, 0, 0, 1, 0x42, 0x01], in: output.data) == 1)
        #expect(occurrences(of: [0, 0, 0, 1, 0x44, 0x01], in: output.data) == 1)
    }

    @Test func repeatsConfiguredPrefixSEIBeforeEveryRandomAccessPicture() throws {
        // Annex B has no hvcC, so the ambient viewing environment SEI that
        // VideoToolbox keeps there must travel with each IRAP, as with FFmpeg.
        let ambientViewing: [UInt8] = [0x4e, 0x01, 0x94, 0x08, 0x00, 0x2f, 0xe9, 0xa0, 0x3d, 0x13, 0x40, 0x42, 0x80]
        let userData: [UInt8] = [0x4e, 0x01, 0x05, 0x01, 0xaa, 0x80]
        let initialization = try ISOBMFFReader().parseInitializationSegment(
            FMP4Fixture.initialization(prefixSEI: ambientViewing)
        )
        let keyframe = sample(trackID: 1, kind: .video, decodeTime: 0, presentationTime: 0,
            duration: 3_000, randomAccess: true,
            data: lengthPrefixedNAL(userData) + lengthPrefixedNAL([0x28, 0x01]))
        let picture = sample(trackID: 1, kind: .video, decodeTime: 3_000, presentationTime: 3_000,
            duration: 3_000, randomAccess: false,
            data: lengthPrefixedNAL(userData) + lengthPrefixedNAL([0x02, 0x01]))
        var muxer = MPEGTransportStreamMuxer()
        let output = try muxer.mux(
            ISOBMFFMediaSegment(sequenceNumber: 1, samples: [keyframe, picture, defaultAudioSample()]),
            initialization: initialization
        )
        let startCode: [UInt8] = [0, 0, 0, 1]
        let expectedKeyframe = startCode + [0x46, 0x01, 0x50] +
            startCode + [0x40, 0x01] + startCode + [0x42, 0x01] + startCode + [0x44, 0x01] +
            startCode + ambientViewing + startCode + userData + startCode + [0x28, 0x01]
        #expect(contains(expectedKeyframe, in: output.data))
        #expect(occurrences(of: startCode + ambientViewing, in: output.data) == 1)
        #expect(occurrences(of: startCode + userData, in: output.data) == 2)
    }

    @Test func placesConfiguredSEIAfterInBandParameterSetsWithoutDuplicates() throws {
        let ambientViewing: [UInt8] = [0x4e, 0x01, 0x94, 0x08, 0x00, 0x2f, 0xe9, 0xa0, 0x3d, 0x13, 0x40, 0x42, 0x80]
        let initialization = try ISOBMFFReader().parseInitializationSegment(
            FMP4Fixture.initialization(prefixSEI: ambientViewing)
        )
        let startCode: [UInt8] = [0, 0, 0, 1]
        let inBandSets = lengthPrefixedNAL([0x40, 0x01]) + lengthPrefixedNAL([0x42, 0x01]) +
            lengthPrefixedNAL([0x44, 0x01])
        for (accessUnit, expected) in [
            (inBandSets + lengthPrefixedNAL([0x28, 0x01]),
             startCode + [0x44, 0x01] + startCode + ambientViewing + startCode + [0x28, 0x01]),
            (inBandSets + lengthPrefixedNAL(ambientViewing) + lengthPrefixedNAL([0x28, 0x01]),
             startCode + ambientViewing + startCode + [0x28, 0x01]),
        ] {
            let keyframe = sample(trackID: 1, kind: .video, decodeTime: 0, presentationTime: 0,
                duration: 3_000, randomAccess: true, data: accessUnit)
            var muxer = MPEGTransportStreamMuxer()
            let output = try muxer.mux(
                ISOBMFFMediaSegment(sequenceNumber: 1, samples: [keyframe, defaultAudioSample()]),
                initialization: initialization
            )
            #expect(contains(expected, in: output.data))
            #expect(occurrences(of: startCode + ambientViewing, in: output.data) == 1)
            #expect(occurrences(of: startCode + [0x44, 0x01], in: output.data) == 1)
        }
    }

    @Test func toleratesSEIOnlyConfigurationChanges() {
        let base = HEVCDecoderConfiguration(nalUnitLengthSize: 4, videoParameterSets: [Data([0x40, 1])],
            sequenceParameterSets: [Data([0x42, 1])], pictureParameterSets: [Data([0x44, 1])])
        let withSEI = HEVCDecoderConfiguration(nalUnitLengthSize: 4, videoParameterSets: [Data([0x40, 1])],
            sequenceParameterSets: [Data([0x42, 1])], pictureParameterSets: [Data([0x44, 1])],
            prefixSEIUnits: [Data([0x4e, 0x01, 0x94])])
        let newSPS = HEVCDecoderConfiguration(nalUnitLengthSize: 4, videoParameterSets: [Data([0x40, 1])],
            sequenceParameterSets: [Data([0x42, 2])], pictureParameterSets: [Data([0x44, 1])])
        #expect(base != withSEI)
        #expect(base.hasSameParameterSets(as: withSEI))
        #expect(!base.hasSameParameterSets(as: newSPS))
    }

    @Test func derivesADTSFromMonoStereoAndExplicitAACConfiguration() throws {
        let configurations: [(Data, [UInt8])] = [
            (Data([0x12, 0x08]), [0xff, 0xf1, 0x50, 0x40]), // 44.1 kHz mono
            (Data([0x12, 0x10]), [0xff, 0xf1, 0x50, 0x80]), // 44.1 kHz stereo
            (
                audioSpecificConfig(
                    objectType: 2,
                    frequencyIndex: 15,
                    explicitSampleRate: 48_000,
                    channels: 2
                ),
                [0xff, 0xf1, 0x4c, 0x80]
            ),
        ]
        for (audioSpecificConfig, expectedHeaderPrefix) in configurations {
            let initialization = try ISOBMFFReader().parseInitializationSegment(
                FMP4Fixture.initialization(audioSpecificConfig: audioSpecificConfig)
            )
            let video = sample(
                trackID: 1,
                kind: .video,
                decodeTime: 0,
                presentationTime: 0,
                duration: 3_000,
                randomAccess: true,
                data: lengthPrefixedNAL([0x26, 0x01])
            )
            var muxer = MPEGTransportStreamMuxer()
            let output = try muxer.mux(
                ISOBMFFMediaSegment(sequenceNumber: 1, samples: [video, defaultAudioSample()]),
                initialization: initialization
            )
            #expect(contains(expectedHeaderPrefix, in: output.data))
        }
    }
}

private func sample(
    trackID: UInt32,
    kind: ISOBMFFTrackKind,
    decodeTime: UInt64,
    presentationTime: Int64,
    duration: UInt32,
    randomAccess: Bool,
    data: Data
) -> ISOBMFFSample {
    ISOBMFFSample(
        trackID: trackID,
        kind: kind,
        decodeTime: decodeTime,
        presentationTime: presentationTime,
        duration: duration,
        isRandomAccess: randomAccess,
        data: data
    )
}

private func defaultAudioSample(decodeTime: UInt64 = 0) -> ISOBMFFSample {
    sample(
        trackID: 2,
        kind: .audio,
        decodeTime: decodeTime,
        presentationTime: Int64(decodeTime),
        duration: 1_024,
        randomAccess: true,
        data: Data([0xaa, 0xbb, 0xcc])
    )
}

private func lengthPrefixedNAL(_ bytes: [UInt8], lengthSize: Int = 4) -> Data {
    var length = Data(repeating: 0, count: lengthSize)
    var value = bytes.count
    for index in (0..<lengthSize).reversed() {
        length[index] = UInt8(value & 0xff)
        value >>= 8
    }
    precondition(value == 0)
    return length + Data(bytes)
}

private func transportPackets(_ data: Data) -> [[UInt8]] {
    let bytes = [UInt8](data)
    guard bytes.count.isMultiple(of: 188) else { return [] }
    return stride(from: 0, to: bytes.count, by: 188).map {
        Array(bytes[$0..<($0 + 188)])
    }
}

private func pid(of packet: [UInt8]) -> UInt16 {
    (UInt16(packet[1] & 0x1f) << 8) | UInt16(packet[2])
}

private func hasPayloadUnitStart(_ packet: [UInt8]) -> Bool {
    packet[1] & 0x40 != 0
}

private func payloadStart(of packet: [UInt8]) -> Int {
    switch (packet[3] >> 4) & 0x03 {
    case 1: 4
    case 3: 5 + Int(packet[4])
    default: packet.count
    }
}

private func sectionHasValidCRC(_ packet: [UInt8]) -> Bool {
    let payload = payloadStart(of: packet)
    let sectionStart = payload + 1 + Int(packet[payload])
    let sectionLength = (Int(packet[sectionStart + 1] & 0x0f) << 8) |
        Int(packet[sectionStart + 2])
    let sectionEnd = sectionStart + 3 + sectionLength
    guard sectionEnd <= packet.count else { return false }
    var crc: UInt32 = 0xffff_ffff
    for byte in packet[sectionStart..<sectionEnd] {
        crc ^= UInt32(byte) << 24
        for _ in 0..<8 {
            crc = crc & 0x8000_0000 != 0
                ? (crc << 1) ^ 0x04c1_1db7
                : crc << 1
        }
    }
    return crc == 0
}

private func decodeTimestamp(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    (UInt64(bytes[offset] & 0x0e) << 29) |
        (UInt64(bytes[offset + 1]) << 22) |
        (UInt64(bytes[offset + 2] & 0xfe) << 14) |
        (UInt64(bytes[offset + 3]) << 7) |
        (UInt64(bytes[offset + 4]) >> 1)
}

private func decodePCR(_ packet: [UInt8]) -> UInt64? {
    guard packet[3] & 0x20 != 0, packet[4] >= 7, packet[5] & 0x10 != 0 else {
        return nil
    }
    return (UInt64(packet[6]) << 25) |
        (UInt64(packet[7]) << 17) |
        (UInt64(packet[8]) << 9) |
        (UInt64(packet[9]) << 1) |
        (UInt64(packet[10]) >> 7)
}

private func contains(_ needle: [UInt8], in haystack: Data) -> Bool {
    guard !needle.isEmpty else { return true }
    let bytes = [UInt8](haystack)
    guard needle.count <= bytes.count else { return false }
    return (0...(bytes.count - needle.count)).contains { start in
        bytes[start..<(start + needle.count)].elementsEqual(needle)
    }
}

private func occurrences(of needle: [UInt8], in haystack: Data) -> Int {
    guard !needle.isEmpty else { return 0 }
    let bytes = [UInt8](haystack)
    guard needle.count <= bytes.count else { return 0 }
    return (0...(bytes.count - needle.count)).reduce(0) { count, start in
        count + (bytes[start..<(start + needle.count)].elementsEqual(needle) ? 1 : 0)
    }
}
