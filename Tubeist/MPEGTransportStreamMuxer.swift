//
//  MPEGTransportStreamMuxer.swift
//  Tubeist
//
//  A focused HEVC/AAC MPEG-2 Transport Stream muxer for Tubeist's direct HLS
//  output. Continuity counters and the timestamp epoch intentionally survive
//  across media segments.
//

import Foundation

enum MPEGTransportStreamError: Error, Equatable, CustomStringConvertible {
    case missingConfiguration(String)
    case malformedSample(String)
    case timestamp(String)

    var description: String {
        switch self {
        case .missingConfiguration(let detail): "Missing TS configuration: \(detail)"
        case .malformedSample(let detail): "Malformed TS sample: \(detail)"
        case .timestamp(let detail): "Invalid TS timestamp: \(detail)"
        }
    }
}

struct MPEGTransportStreamSegment: Sendable, Equatable {
    let data: Data
    let duration: Double
    let startsWithRandomAccess: Bool
    let firstPresentationTimestamp: UInt64
    let lastPresentationTimestamp: UInt64
}

struct MPEGTransportStreamMuxer {
    static let packetSize = 188
    static let programAssociationPID: UInt16 = 0x0000
    static let videoPID: UInt16 = 0x0100
    static let audioPID: UInt16 = 0x0101
    static let programMapPID: UInt16 = 0x1000

    private static let clockRate: Int64 = 90_000
    private static let initialTimestamp: Int64 = 90_000
    private static let timestampMask: UInt64 = (1 << 33) - 1
    private static let tableRepeatInterval: Int64 = 9_000

    private var continuityCounters: [UInt16: UInt8] = [:]
    private var timestampShift: Int64?
    private var lastDecodeTimeByTrack: [UInt32: UInt64] = [:]

    mutating func reset() {
        continuityCounters.removeAll(keepingCapacity: true)
        timestampShift = nil
        lastDecodeTimeByTrack.removeAll(keepingCapacity: true)
    }

    mutating func mux(
        _ segment: ISOBMFFMediaSegment,
        initialization: ISOBMFFInitialization
    ) throws -> MPEGTransportStreamSegment {
        var candidate = self
        let output = try candidate.makeSegment(segment, initialization: initialization)
        self = candidate
        return output
    }

    private mutating func makeSegment(
        _ segment: ISOBMFFMediaSegment,
        initialization: ISOBMFFInitialization
    ) throws -> MPEGTransportStreamSegment {
        guard let videoTrack = initialization.videoTrack,
              let hevc = videoTrack.hevc else {
            throw MPEGTransportStreamError.missingConfiguration("HEVC track and hvcC")
        }
        guard let audioTrack = initialization.audioTrack,
              let aac = audioTrack.aac else {
            throw MPEGTransportStreamError.missingConfiguration("AAC track and AudioSpecificConfig")
        }
        guard !segment.samples.isEmpty else {
            throw MPEGTransportStreamError.malformedSample("empty media segment")
        }
        guard segment.samples.contains(where: { $0.kind == .video }),
              segment.samples.contains(where: { $0.kind == .audio }) else {
            throw MPEGTransportStreamError.malformedSample(
                "media segment must contain muxed video and audio"
            )
        }

        try validateMonotonicDecodeTimes(segment.samples)
        var encoded = try segment.samples.enumerated().map { order, sample in
            guard let track = initialization.tracks[sample.trackID] else {
                throw MPEGTransportStreamError.missingConfiguration("track \(sample.trackID)")
            }
            let decodeTime = try rescale(Int64(sample.decodeTime), from: track.timescale)
            let presentationTime = try rescale(sample.presentationTime, from: track.timescale)
            let duration = try rescale(Int64(sample.duration), from: track.timescale)
            guard duration > 0 else {
                throw MPEGTransportStreamError.timestamp("sample duration rounded to zero")
            }
            return EncodedSample(
                order: order,
                source: sample,
                decodeTime: decodeTime,
                presentationTime: presentationTime,
                duration: duration
            )
        }

        if timestampShift == nil {
            let firstTimestamp = encoded.reduce(Int64.max) {
                min($0, $1.decodeTime, $1.presentationTime)
            }
            let (shift, overflow) = Self.initialTimestamp.subtractingReportingOverflow(firstTimestamp)
            guard !overflow else {
                throw MPEGTransportStreamError.timestamp("initial epoch overflow")
            }
            timestampShift = shift
        }
        guard let timestampShift else {
            throw MPEGTransportStreamError.timestamp("missing timestamp epoch")
        }

        encoded = try encoded.map { sample in
            let decodeTime = try shifted(sample.decodeTime, by: timestampShift)
            let presentationTime = try shifted(sample.presentationTime, by: timestampShift)
            return EncodedSample(
                order: sample.order,
                source: sample.source,
                decodeTime: decodeTime,
                presentationTime: presentationTime,
                duration: sample.duration
            )
        }
        encoded.sort {
            if $0.decodeTime != $1.decodeTime { return $0.decodeTime < $1.decodeTime }
            if $0.source.kind != $1.source.kind { return $0.source.kind == .video }
            return $0.order < $1.order
        }
        guard let firstVideo = encoded.first(where: { $0.source.kind == .video }),
              firstVideo.source.isRandomAccess else {
            throw MPEGTransportStreamError.malformedSample(
                "segment does not begin with a random-access video sample"
            )
        }

        var output = Data()
        output.reserveCapacity(max(Self.packetSize * 2, segment.samples.reduce(0) { $0 + $1.data.count }))
        appendProgramTables(to: &output)
        var nextTableTimestamp = encoded[0].decodeTime + Self.tableRepeatInterval

        for sample in encoded {
            if sample.decodeTime >= nextTableTimestamp {
                appendProgramTables(to: &output)
                nextTableTimestamp = sample.decodeTime + Self.tableRepeatInterval
            }

            switch sample.source.kind {
            case .video:
                let elementaryStream = try annexB(
                    sample.source.data,
                    configuration: hevc,
                    prependParameterSets: sample.source.isRandomAccess
                )
                let pes = makePES(
                    streamID: 0xe0,
                    payload: elementaryStream,
                    presentationTime: UInt64(sample.presentationTime),
                    decodeTime: UInt64(sample.decodeTime),
                    unboundedLength: true
                )
                packetizePES(
                    pes,
                    pid: Self.videoPID,
                    randomAccess: sample.source.isRandomAccess,
                    pcr: UInt64(sample.decodeTime),
                    into: &output
                )

            case .audio:
                let elementaryStream = try adtsFrame(sample.source.data, configuration: aac)
                let pes = makePES(
                    streamID: 0xc0,
                    payload: elementaryStream,
                    presentationTime: UInt64(sample.presentationTime),
                    decodeTime: nil,
                    unboundedLength: false
                )
                packetizePES(
                    pes,
                    pid: Self.audioPID,
                    randomAccess: false,
                    pcr: nil,
                    into: &output
                )
            }
        }

        guard let firstPresentation = encoded.map(\.presentationTime).min(),
              let lastPresentation = encoded.map({ $0.presentationTime + $0.duration }).max() else {
            throw MPEGTransportStreamError.malformedSample("empty encoded timeline")
        }
        return MPEGTransportStreamSegment(
            data: output,
            duration: Double(lastPresentation - firstPresentation) / Double(Self.clockRate),
            startsWithRandomAccess: true,
            firstPresentationTimestamp: UInt64(firstPresentation),
            lastPresentationTimestamp: UInt64(lastPresentation)
        )
    }
}

// MARK: - Elementary streams

private struct EncodedSample {
    let order: Int
    let source: ISOBMFFSample
    let decodeTime: Int64
    let presentationTime: Int64
    let duration: Int64
}

private extension MPEGTransportStreamMuxer {
    func annexB(
        _ sample: Data,
        configuration: HEVCDecoderConfiguration,
        prependParameterSets: Bool
    ) throws -> Data {
        let lengthSize = configuration.nalUnitLengthSize
        guard (1...4).contains(lengthSize) else {
            throw MPEGTransportStreamError.malformedSample("invalid HEVC NAL length size")
        }
        var units: [(type: UInt8, data: Data)] = []
        var cursor = 0
        while cursor < sample.count {
            guard lengthSize <= sample.count - cursor else {
                throw MPEGTransportStreamError.malformedSample("truncated HEVC NAL length")
            }
            var length = 0
            for byte in sample[cursor..<(cursor + lengthSize)] {
                guard length <= (Int.max >> 8) else {
                    throw MPEGTransportStreamError.malformedSample("HEVC NAL length overflow")
                }
                length = (length << 8) | Int(byte)
            }
            cursor += lengthSize
            guard length > 0, length <= sample.count - cursor else {
                throw MPEGTransportStreamError.malformedSample("HEVC NAL exceeds sample")
            }
            let unit = sample.subdata(in: cursor..<(cursor + length))
            guard let firstByte = unit.first else {
                throw MPEGTransportStreamError.malformedSample("empty HEVC NAL unit")
            }
            units.append(((firstByte >> 1) & 0x3f, unit))
            cursor += length
        }
        guard !units.isEmpty else {
            throw MPEGTransportStreamError.malformedSample("HEVC access unit has no NAL units")
        }

        var output = Data()
        if prependParameterSets {
            let inBandTypes = Set(units.map(\.type))
            let configuredSets: [(UInt8, [Data])] = [
                (32, configuration.videoParameterSets),
                (33, configuration.sequenceParameterSets),
                (34, configuration.pictureParameterSets),
            ]
            for (type, parameterSets) in configuredSets where !inBandTypes.contains(type) {
                for unit in parameterSets {
                    output.append(contentsOf: [0, 0, 0, 1])
                    output.append(unit)
                }
            }
        }
        for unit in units {
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(unit.data)
        }
        return output
    }

    func adtsFrame(_ sample: Data, configuration: AACDecoderConfiguration) throws -> Data {
        guard !sample.isEmpty else {
            throw MPEGTransportStreamError.malformedSample("empty AAC access unit")
        }
        guard (1...4).contains(configuration.audioObjectType) else {
            throw MPEGTransportStreamError.malformedSample("AAC object type cannot be represented by ADTS")
        }
        let adtsSampleRates: [UInt32] = [
            96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
            22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
        ]
        let frequency: UInt8
        if configuration.samplingFrequencyIndex < 13 {
            frequency = configuration.samplingFrequencyIndex
        } else if let index = adtsSampleRates.firstIndex(of: configuration.sampleRate) {
            frequency = UInt8(index)
        } else {
            throw MPEGTransportStreamError.malformedSample("AAC frequency cannot be represented by ADTS")
        }
        guard (1...7).contains(configuration.channelConfiguration) else {
            throw MPEGTransportStreamError.malformedSample("AAC channel layout cannot be represented by ADTS")
        }
        let frameLength = sample.count + 7
        guard frameLength <= 0x1fff else {
            throw MPEGTransportStreamError.malformedSample("AAC frame is too large for ADTS")
        }

        let profile = configuration.audioObjectType - 1
        let channels = configuration.channelConfiguration
        var output = Data([
            0xff,
            0xf1,
            (profile << 6) | (frequency << 2) | (channels >> 2),
            ((channels & 0x03) << 6) | UInt8((frameLength >> 11) & 0x03),
            UInt8((frameLength >> 3) & 0xff),
            UInt8((frameLength & 0x07) << 5) | 0x1f,
            0xfc,
        ])
        output.append(sample)
        return output
    }
}

// MARK: - Program tables

private extension MPEGTransportStreamMuxer {
    mutating func appendProgramTables(to output: inout Data) {
        output.append(psiPacket(pid: Self.programAssociationPID, section: programAssociationTable()))
        output.append(psiPacket(pid: Self.programMapPID, section: programMapTable()))
    }

    func programAssociationTable() -> Data {
        var section = Data([
            0x00,       // table_id
            0xb0, 0x0d, // section_syntax_indicator and section_length
            0x00, 0x01, // transport_stream_id
            0xc1,       // version 0, current_next_indicator
            0x00, 0x00, // section numbers
            0x00, 0x01, // program_number
            0xf0 | UInt8((Self.programMapPID >> 8) & 0x1f),
            UInt8(Self.programMapPID & 0xff),
        ])
        appendCRC(to: &section)
        return section
    }

    func programMapTable() -> Data {
        let sectionLength = 9 + 5 + 5 + 4
        var section = Data([
            0x02, // table_id
            0xb0 | UInt8((sectionLength >> 8) & 0x0f),
            UInt8(sectionLength & 0xff),
            0x00, 0x01, // program_number
            0xc1,       // version 0, current_next_indicator
            0x00, 0x00, // section numbers
            0xe0 | UInt8((Self.videoPID >> 8) & 0x1f),
            UInt8(Self.videoPID & 0xff), // PCR_PID
            0xf0, 0x00, // program_info_length
            0x24,       // HEVC stream_type
            0xe0 | UInt8((Self.videoPID >> 8) & 0x1f),
            UInt8(Self.videoPID & 0xff),
            0xf0, 0x00,
            0x0f,       // AAC ADTS stream_type
            0xe0 | UInt8((Self.audioPID >> 8) & 0x1f),
            UInt8(Self.audioPID & 0xff),
            0xf0, 0x00,
        ])
        appendCRC(to: &section)
        return section
    }

    mutating func psiPacket(pid: UInt16, section: Data) -> Data {
        precondition(section.count + 1 <= 184)
        var packet = transportHeader(
            pid: pid,
            payloadUnitStart: true,
            adaptationFieldControl: 1
        )
        packet.append(0) // pointer_field
        packet.append(section)
        packet.append(Data(repeating: 0xff, count: Self.packetSize - packet.count))
        return packet
    }

    func appendCRC(to section: inout Data) {
        var crc: UInt32 = 0xffff_ffff
        for byte in section {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = crc & 0x8000_0000 != 0
                    ? (crc << 1) ^ 0x04c1_1db7
                    : crc << 1
            }
        }
        section.append(contentsOf: [
            UInt8((crc >> 24) & 0xff),
            UInt8((crc >> 16) & 0xff),
            UInt8((crc >> 8) & 0xff),
            UInt8(crc & 0xff),
        ])
    }
}

// MARK: - PES and TS packets

private extension MPEGTransportStreamMuxer {
    func makePES(
        streamID: UInt8,
        payload: Data,
        presentationTime: UInt64,
        decodeTime: UInt64?,
        unboundedLength: Bool
    ) -> Data {
        let hasDecodeTime = decodeTime != nil && decodeTime != presentationTime
        let timestampBytes = hasDecodeTime ? 10 : 5
        let boundedLength = 3 + timestampBytes + payload.count
        let packetLength: UInt16 = unboundedLength || boundedLength > Int(UInt16.max)
            ? 0
            : UInt16(boundedLength)

        var pes = Data([0x00, 0x00, 0x01, streamID])
        pes.append(contentsOf: [UInt8(packetLength >> 8), UInt8(packetLength & 0xff)])
        pes.append(0x80) // MPEG-2 PES, no scrambling
        pes.append(hasDecodeTime ? 0xc0 : 0x80)
        pes.append(UInt8(timestampBytes))
        pes.append(contentsOf: encodedTimestamp(presentationTime, prefix: hasDecodeTime ? 0x03 : 0x02))
        if let decodeTime, hasDecodeTime {
            pes.append(contentsOf: encodedTimestamp(decodeTime, prefix: 0x01))
        }
        pes.append(payload)
        return pes
    }

    func encodedTimestamp(_ timestamp: UInt64, prefix: UInt8) -> [UInt8] {
        let value = timestamp & Self.timestampMask
        return [
            (prefix << 4) | UInt8((value >> 29) & 0x0e) | 0x01,
            UInt8((value >> 22) & 0xff),
            UInt8((value >> 14) & 0xfe) | 0x01,
            UInt8((value >> 7) & 0xff),
            UInt8((value << 1) & 0xfe) | 0x01,
        ]
    }

    mutating func packetizePES(
        _ pes: Data,
        pid: UInt16,
        randomAccess: Bool,
        pcr: UInt64?,
        into output: inout Data
    ) {
        var cursor = 0
        var firstPacket = true
        while cursor < pes.count {
            let packetPCR = firstPacket ? pcr : nil
            let packetRandomAccess = firstPacket && randomAccess
            let minimumAdaptationSize = packetPCR != nil ? 8 : (packetRandomAccess ? 2 : 0)
            let maximumPayloadSize = 184 - minimumAdaptationSize
            let payloadSize = min(pes.count - cursor, maximumPayloadSize)
            let adaptationSize = payloadSize == 184 && minimumAdaptationSize == 0
                ? 0
                : 184 - payloadSize
            let adaptationFieldControl: UInt8 = adaptationSize == 0 ? 1 : 3
            var packet = transportHeader(
                pid: pid,
                payloadUnitStart: firstPacket,
                adaptationFieldControl: adaptationFieldControl
            )
            if adaptationSize > 0 {
                appendAdaptationField(
                    totalSize: adaptationSize,
                    randomAccess: packetRandomAccess,
                    pcr: packetPCR,
                    to: &packet
                )
            }
            packet.append(pes.subdata(in: cursor..<(cursor + payloadSize)))
            precondition(packet.count == Self.packetSize)
            output.append(packet)
            cursor += payloadSize
            firstPacket = false
        }
    }

    mutating func transportHeader(
        pid: UInt16,
        payloadUnitStart: Bool,
        adaptationFieldControl: UInt8
    ) -> Data {
        let continuityCounter = continuityCounters[pid, default: 0]
        continuityCounters[pid] = (continuityCounter + 1) & 0x0f
        return Data([
            0x47,
            (payloadUnitStart ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1f),
            UInt8(pid & 0xff),
            (adaptationFieldControl << 4) | continuityCounter,
        ])
    }

    func appendAdaptationField(
        totalSize: Int,
        randomAccess: Bool,
        pcr: UInt64?,
        to packet: inout Data
    ) {
        precondition(totalSize > 0)
        packet.append(UInt8(totalSize - 1))
        guard totalSize > 1 else { return }

        var flags: UInt8 = randomAccess ? 0x40 : 0x00
        if pcr != nil { flags |= 0x10 }
        packet.append(flags)
        var written = 2
        if let pcr {
            let base = pcr & Self.timestampMask
            packet.append(contentsOf: [
                UInt8((base >> 25) & 0xff),
                UInt8((base >> 17) & 0xff),
                UInt8((base >> 9) & 0xff),
                UInt8((base >> 1) & 0xff),
                UInt8((base & 0x01) << 7) | 0x7e,
                0x00,
            ])
            written += 6
        }
        if written < totalSize {
            packet.append(Data(repeating: 0xff, count: totalSize - written))
        }
    }
}

// MARK: - Timeline

private extension MPEGTransportStreamMuxer {
    mutating func validateMonotonicDecodeTimes(_ samples: [ISOBMFFSample]) throws {
        let grouped = Dictionary(grouping: samples, by: \.trackID)
        for (trackID, trackSamples) in grouped {
            let times = trackSamples.map(\.decodeTime).sorted()
            guard let first = times.first, let last = times.last else { continue }
            guard zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }) else {
                throw MPEGTransportStreamError.timestamp(
                    "track \(trackID) contains repeated decode times"
                )
            }
            if let previous = lastDecodeTimeByTrack[trackID], first <= previous {
                throw MPEGTransportStreamError.timestamp(
                    "track \(trackID) decode time moved backwards or repeated"
                )
            }
            lastDecodeTimeByTrack[trackID] = last
        }
    }

    func rescale(_ value: Int64, from timescale: UInt32) throws -> Int64 {
        guard timescale > 0 else {
            throw MPEGTransportStreamError.timestamp("zero source timescale")
        }
        let divisor = Int64(timescale)
        let quotient = value / divisor
        let remainder = value % divisor
        let (whole, wholeOverflow) = quotient.multipliedReportingOverflow(by: Self.clockRate)
        let (partialNumerator, partialOverflow) = remainder.multipliedReportingOverflow(by: Self.clockRate)
        guard !wholeOverflow, !partialOverflow else {
            throw MPEGTransportStreamError.timestamp("timescale conversion overflow")
        }
        let partial = partialNumerator / divisor
        let (result, resultOverflow) = whole.addingReportingOverflow(partial)
        guard !resultOverflow else {
            throw MPEGTransportStreamError.timestamp("timescale conversion overflow")
        }
        return result
    }

    func shifted(_ timestamp: Int64, by shift: Int64) throws -> Int64 {
        let (result, overflow) = timestamp.addingReportingOverflow(shift)
        guard !overflow, result >= 0 else {
            throw MPEGTransportStreamError.timestamp("normalized timestamp is negative or overflowing")
        }
        return result
    }
}
