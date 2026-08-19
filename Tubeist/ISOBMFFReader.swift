//
//  ISOBMFFReader.swift
//  Tubeist
//
//  A deliberately small, bounds-checked reader for the fragmented MP4 emitted
//  by Tubeist's AVAssetWriter. It is not intended to be a general MP4 decoder.
//

import Foundation

enum ISOBMFFError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case missing(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .malformed(let detail): "Malformed ISOBMFF: \(detail)"
        case .missing(let detail): "Missing ISOBMFF data: \(detail)"
        case .unsupported(let detail): "Unsupported ISOBMFF feature: \(detail)"
        }
    }
}

enum ISOBMFFTrackKind: Sendable, Equatable {
    case video
    case audio
}

struct HEVCDecoderConfiguration: Sendable, Equatable {
    let nalUnitLengthSize: Int
    let videoParameterSets: [Data]
    let sequenceParameterSets: [Data]
    let pictureParameterSets: [Data]
}

struct AACDecoderConfiguration: Sendable, Equatable {
    let audioSpecificConfig: Data
    let audioObjectType: UInt8
    let samplingFrequencyIndex: UInt8
    let sampleRate: UInt32
    let channelConfiguration: UInt8
}

struct ISOBMFFTrack: Sendable, Equatable {
    let id: UInt32
    let kind: ISOBMFFTrackKind
    let timescale: UInt32
    let defaultSampleDuration: UInt32
    let defaultSampleSize: UInt32
    let defaultSampleFlags: UInt32
    let hevc: HEVCDecoderConfiguration?
    let aac: AACDecoderConfiguration?
}

struct ISOBMFFInitialization: Sendable, Equatable {
    let tracks: [UInt32: ISOBMFFTrack]

    var videoTrack: ISOBMFFTrack? {
        tracks.values.first { $0.kind == .video }
    }

    var audioTrack: ISOBMFFTrack? {
        tracks.values.first { $0.kind == .audio }
    }
}

struct ISOBMFFSample: Sendable, Equatable {
    let trackID: UInt32
    let kind: ISOBMFFTrackKind
    let decodeTime: UInt64
    let presentationTime: Int64
    let duration: UInt32
    let isRandomAccess: Bool
    let data: Data
}

struct ISOBMFFMediaSegment: Sendable, Equatable {
    let sequenceNumber: UInt32?
    let samples: [ISOBMFFSample]
}

struct ISOBMFFReader {
    func parseInitializationSegment(_ source: Data) throws -> ISOBMFFInitialization {
        let data = Data(source)
        let topLevel = try boxes(in: 0..<data.count, data: data)
        guard let moov = topLevel.first(where: { $0.type == .moov }) else {
            throw ISOBMFFError.missing("moov")
        }

        let moovChildren = try boxes(in: moov.payloadRange, data: data)
        let trexDefaults = try parseTrackExtends(from: moovChildren, data: data)
        var tracks: [UInt32: ISOBMFFTrack] = [:]

        for trak in moovChildren where trak.type == .trak {
            let partial = try parseTrack(trak, data: data)
            guard tracks[partial.id] == nil else {
                throw ISOBMFFError.malformed("duplicate track ID \(partial.id)")
            }
            let defaults = trexDefaults[partial.id] ?? TrackDefaults()
            tracks[partial.id] = ISOBMFFTrack(
                id: partial.id,
                kind: partial.kind,
                timescale: partial.timescale,
                defaultSampleDuration: defaults.duration,
                defaultSampleSize: defaults.size,
                defaultSampleFlags: defaults.flags,
                hevc: partial.hevc,
                aac: partial.aac
            )
        }

        guard tracks.values.contains(where: { $0.kind == .video }) else {
            throw ISOBMFFError.missing("HEVC video track")
        }
        guard tracks.values.contains(where: { $0.kind == .audio }) else {
            throw ISOBMFFError.missing("AAC audio track")
        }
        return ISOBMFFInitialization(tracks: tracks)
    }

    func parseMediaSegment(
        _ source: Data,
        initialization: ISOBMFFInitialization
    ) throws -> ISOBMFFMediaSegment {
        let data = Data(source)
        let topLevel = try boxes(in: 0..<data.count, data: data)
        let mediaDataRanges = topLevel
            .filter { $0.type == .mdat }
            .map(\.payloadRange)
        guard !mediaDataRanges.isEmpty else {
            throw ISOBMFFError.missing("mdat")
        }

        let movieFragments = topLevel.filter { $0.type == .moof }
        guard !movieFragments.isEmpty else {
            throw ISOBMFFError.missing("moof")
        }

        var sequenceNumber: UInt32?
        var samples: [ISOBMFFSample] = []
        for moof in movieFragments {
            let children = try boxes(in: moof.payloadRange, data: data)
            if let mfhd = children.first(where: { $0.type == .mfhd }) {
                let reader = try ByteReader(data: data, range: mfhd.payloadRange)
                try reader.require(8, context: "mfhd")
                let parsedSequence = reader.uint32(at: 4)
                if sequenceNumber == nil {
                    sequenceNumber = parsedSequence
                }
            }

            var previousTrackFragmentDataEnd: Int?
            for traf in children where traf.type == .traf {
                let parsed = try parseTrackFragment(
                    traf,
                    moof: moof,
                    data: data,
                    mediaDataRanges: mediaDataRanges,
                    initialization: initialization,
                    implicitBaseDataOffset: previousTrackFragmentDataEnd
                )
                samples.append(contentsOf: parsed.samples)
                previousTrackFragmentDataEnd = parsed.dataEnd
            }
        }

        guard !samples.isEmpty else {
            throw ISOBMFFError.missing("fragment samples")
        }
        return ISOBMFFMediaSegment(sequenceNumber: sequenceNumber, samples: samples)
    }
}

// MARK: - Box model

private struct FourCC: Equatable {
    let rawValue: UInt32

    init(_ string: String) {
        precondition(string.utf8.count == 4)
        self.rawValue = string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let moov = FourCC("moov")
    static let trak = FourCC("trak")
    static let tkhd = FourCC("tkhd")
    static let mdia = FourCC("mdia")
    static let mdhd = FourCC("mdhd")
    static let hdlr = FourCC("hdlr")
    static let minf = FourCC("minf")
    static let stbl = FourCC("stbl")
    static let stsd = FourCC("stsd")
    static let mvex = FourCC("mvex")
    static let trex = FourCC("trex")
    static let hvc1 = FourCC("hvc1")
    static let hev1 = FourCC("hev1")
    static let hvcC = FourCC("hvcC")
    static let mp4a = FourCC("mp4a")
    static let esds = FourCC("esds")
    static let moof = FourCC("moof")
    static let mfhd = FourCC("mfhd")
    static let traf = FourCC("traf")
    static let tfhd = FourCC("tfhd")
    static let tfdt = FourCC("tfdt")
    static let trun = FourCC("trun")
    static let mdat = FourCC("mdat")
    static let vide = FourCC("vide")
    static let soun = FourCC("soun")
}

private struct ISOBox {
    let type: FourCC
    let start: Int
    let size: Int
    let headerSize: Int

    var payloadRange: Range<Int> {
        (start + headerSize)..<(start + size)
    }
}

private final class ByteReader {
    private let data: Data
    let range: Range<Int>

    init(data: Data, range: Range<Int>) throws {
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              range.upperBound <= data.count else {
            throw ISOBMFFError.malformed("byte range is outside input")
        }
        self.data = data
        self.range = range
    }

    func require(_ count: Int, at relativeOffset: Int = 0, context: String) throws {
        guard relativeOffset >= 0,
              count >= 0,
              relativeOffset <= range.count,
              count <= range.count - relativeOffset else {
            throw ISOBMFFError.malformed("truncated \(context)")
        }
    }

    func uint8(at offset: Int) -> UInt8 {
        data[range.lowerBound + offset]
    }

    func uint16(at offset: Int) -> UInt16 {
        (UInt16(uint8(at: offset)) << 8) |
            UInt16(uint8(at: offset + 1))
    }

    func uint24(at offset: Int) -> UInt32 {
        (UInt32(uint8(at: offset)) << 16) |
            (UInt32(uint8(at: offset + 1)) << 8) |
            UInt32(uint8(at: offset + 2))
    }

    func uint32(at offset: Int) -> UInt32 {
        (UInt32(uint8(at: offset)) << 24) |
            (UInt32(uint8(at: offset + 1)) << 16) |
            (UInt32(uint8(at: offset + 2)) << 8) |
            UInt32(uint8(at: offset + 3))
    }

    func int32(at offset: Int) -> Int32 {
        Int32(bitPattern: uint32(at: offset))
    }

    func uint64(at offset: Int) -> UInt64 {
        (UInt64(uint32(at: offset)) << 32) | UInt64(uint32(at: offset + 4))
    }

    func data(at offset: Int, count: Int) -> Data {
        let start = range.lowerBound + offset
        return data.subdata(in: start..<(start + count))
    }
}

private func boxes(in range: Range<Int>, data: Data) throws -> [ISOBox] {
    let reader = try ByteReader(data: data, range: range)
    var result: [ISOBox] = []
    var offset = 0

    while offset < range.count {
        try reader.require(8, at: offset, context: "box header")
        let compactSize = reader.uint32(at: offset)
        let type = FourCC(rawValue: reader.uint32(at: offset + 4))
        let headerSize: Int
        let boxSize: Int

        switch compactSize {
        case 0:
            headerSize = 8
            boxSize = range.count - offset
        case 1:
            try reader.require(16, at: offset, context: "extended box header")
            let extendedSize = reader.uint64(at: offset + 8)
            guard extendedSize <= UInt64(Int.max) else {
                throw ISOBMFFError.malformed("box size exceeds addressable memory")
            }
            headerSize = 16
            boxSize = Int(extendedSize)
        default:
            headerSize = 8
            boxSize = Int(compactSize)
        }

        guard boxSize >= headerSize else {
            throw ISOBMFFError.malformed("box is smaller than its header")
        }
        guard boxSize <= range.count - offset else {
            throw ISOBMFFError.malformed("box exceeds its parent")
        }
        result.append(ISOBox(
            type: type,
            start: range.lowerBound + offset,
            size: boxSize,
            headerSize: headerSize
        ))
        offset += boxSize
    }
    return result
}

private func requiredChild(_ type: FourCC, of parent: ISOBox, data: Data, name: String) throws -> ISOBox {
    guard let child = try boxes(in: parent.payloadRange, data: data).first(where: { $0.type == type }) else {
        throw ISOBMFFError.missing(name)
    }
    return child
}

// MARK: - Initialization segment

private struct TrackDefaults {
    var duration: UInt32 = 0
    var size: UInt32 = 0
    var flags: UInt32 = 0
}

private struct PartialTrack {
    let id: UInt32
    let kind: ISOBMFFTrackKind
    let timescale: UInt32
    let hevc: HEVCDecoderConfiguration?
    let aac: AACDecoderConfiguration?
}

private func parseTrackExtends(from moovChildren: [ISOBox], data: Data) throws -> [UInt32: TrackDefaults] {
    guard let mvex = moovChildren.first(where: { $0.type == .mvex }) else {
        throw ISOBMFFError.missing("mvex")
    }
    var result: [UInt32: TrackDefaults] = [:]
    for trex in try boxes(in: mvex.payloadRange, data: data) where trex.type == .trex {
        let reader = try ByteReader(data: data, range: trex.payloadRange)
        try reader.require(24, context: "trex")
        let trackID = reader.uint32(at: 4)
        result[trackID] = TrackDefaults(
            duration: reader.uint32(at: 12),
            size: reader.uint32(at: 16),
            flags: reader.uint32(at: 20)
        )
    }
    return result
}

private func parseTrack(_ trak: ISOBox, data: Data) throws -> PartialTrack {
    let tkhd = try requiredChild(.tkhd, of: trak, data: data, name: "tkhd")
    let tkhdReader = try ByteReader(data: data, range: tkhd.payloadRange)
    try tkhdReader.require(1, context: "tkhd version")
    let trackIDOffset: Int
    switch tkhdReader.uint8(at: 0) {
    case 0: trackIDOffset = 12
    case 1: trackIDOffset = 20
    default: throw ISOBMFFError.unsupported("tkhd version")
    }
    try tkhdReader.require(4, at: trackIDOffset, context: "tkhd track ID")
    let trackID = tkhdReader.uint32(at: trackIDOffset)
    guard trackID != 0 else {
        throw ISOBMFFError.malformed("track ID is zero")
    }

    let mdia = try requiredChild(.mdia, of: trak, data: data, name: "mdia")
    let mdhd = try requiredChild(.mdhd, of: mdia, data: data, name: "mdhd")
    let mdhdReader = try ByteReader(data: data, range: mdhd.payloadRange)
    try mdhdReader.require(1, context: "mdhd version")
    let timescaleOffset: Int
    switch mdhdReader.uint8(at: 0) {
    case 0: timescaleOffset = 12
    case 1: timescaleOffset = 20
    default: throw ISOBMFFError.unsupported("mdhd version")
    }
    try mdhdReader.require(4, at: timescaleOffset, context: "mdhd timescale")
    let timescale = mdhdReader.uint32(at: timescaleOffset)
    guard timescale != 0 else {
        throw ISOBMFFError.malformed("track \(trackID) has a zero timescale")
    }

    let hdlr = try requiredChild(.hdlr, of: mdia, data: data, name: "hdlr")
    let handlerReader = try ByteReader(data: data, range: hdlr.payloadRange)
    try handlerReader.require(12, context: "hdlr")
    let kind: ISOBMFFTrackKind
    switch FourCC(rawValue: handlerReader.uint32(at: 8)) {
    case .vide: kind = .video
    case .soun: kind = .audio
    default: throw ISOBMFFError.unsupported("non-audio/video track \(trackID)")
    }

    let minf = try requiredChild(.minf, of: mdia, data: data, name: "minf")
    let stbl = try requiredChild(.stbl, of: minf, data: data, name: "stbl")
    let stsd = try requiredChild(.stsd, of: stbl, data: data, name: "stsd")
    let sampleDescription = try parseSampleDescription(stsd, kind: kind, data: data)
    return PartialTrack(
        id: trackID,
        kind: kind,
        timescale: timescale,
        hevc: sampleDescription.hevc,
        aac: sampleDescription.aac
    )
}

private func parseSampleDescription(
    _ stsd: ISOBox,
    kind: ISOBMFFTrackKind,
    data: Data
) throws -> (hevc: HEVCDecoderConfiguration?, aac: AACDecoderConfiguration?) {
    let reader = try ByteReader(data: data, range: stsd.payloadRange)
    try reader.require(8, context: "stsd")
    let entryCount = reader.uint32(at: 4)
    guard entryCount > 0 else {
        throw ISOBMFFError.missing("sample description")
    }
    let entryRange = (stsd.payloadRange.lowerBound + 8)..<stsd.payloadRange.upperBound
    guard let entry = try boxes(in: entryRange, data: data).first else {
        throw ISOBMFFError.missing("sample entry")
    }

    switch kind {
    case .video:
        guard entry.type == .hvc1 || entry.type == .hev1 else {
            throw ISOBMFFError.unsupported("video sample entry is not HEVC")
        }
        guard entry.payloadRange.count >= 78 else {
            throw ISOBMFFError.malformed("truncated HEVC sample entry")
        }
        let childrenRange = (entry.payloadRange.lowerBound + 78)..<entry.payloadRange.upperBound
        guard let configuration = try boxes(in: childrenRange, data: data).first(where: { $0.type == .hvcC }) else {
            throw ISOBMFFError.missing("hvcC")
        }
        return (try parseHEVCConfiguration(configuration, data: data), nil)

    case .audio:
        guard entry.type == .mp4a else {
            throw ISOBMFFError.unsupported("audio sample entry is not mp4a")
        }
        let entryReader = try ByteReader(data: data, range: entry.payloadRange)
        try entryReader.require(28, context: "mp4a sample entry")
        let soundVersion = entryReader.uint16(at: 8)
        let childOffset: Int
        switch soundVersion {
        case 0: childOffset = 28
        case 1: childOffset = 44
        default: throw ISOBMFFError.unsupported("mp4a sound version \(soundVersion)")
        }
        guard entry.payloadRange.count >= childOffset else {
            throw ISOBMFFError.malformed("truncated mp4a sample entry")
        }
        let childrenRange = (entry.payloadRange.lowerBound + childOffset)..<entry.payloadRange.upperBound
        guard let esds = try boxes(in: childrenRange, data: data).first(where: { $0.type == .esds }) else {
            throw ISOBMFFError.missing("esds")
        }
        return (nil, try parseAACConfiguration(esds, data: data))
    }
}

private func parseHEVCConfiguration(_ box: ISOBox, data: Data) throws -> HEVCDecoderConfiguration {
    let reader = try ByteReader(data: data, range: box.payloadRange)
    try reader.require(23, context: "hvcC")
    guard reader.uint8(at: 0) == 1 else {
        throw ISOBMFFError.unsupported("hvcC configuration version")
    }
    let nalLengthSize = Int(reader.uint8(at: 21) & 0x03) + 1
    let arrayCount = Int(reader.uint8(at: 22))
    var cursor = 23
    var vps: [Data] = []
    var sps: [Data] = []
    var pps: [Data] = []

    for _ in 0..<arrayCount {
        try reader.require(3, at: cursor, context: "hvcC NAL array")
        let nalType = reader.uint8(at: cursor) & 0x3f
        let nalCount = Int(reader.uint16(at: cursor + 1))
        cursor += 3
        for _ in 0..<nalCount {
            try reader.require(2, at: cursor, context: "hvcC NAL length")
            let length = Int(reader.uint16(at: cursor))
            cursor += 2
            try reader.require(length, at: cursor, context: "hvcC NAL unit")
            let unit = reader.data(at: cursor, count: length)
            cursor += length
            switch nalType {
            case 32: vps.append(unit)
            case 33: sps.append(unit)
            case 34: pps.append(unit)
            default: break
            }
        }
    }

    guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else {
        throw ISOBMFFError.missing("HEVC VPS/SPS/PPS")
    }
    return HEVCDecoderConfiguration(
        nalUnitLengthSize: nalLengthSize,
        videoParameterSets: vps,
        sequenceParameterSets: sps,
        pictureParameterSets: pps
    )
}

private let aacSampleRates: [UInt32] = [
    96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
    22_050, 16_000, 12_000, 11_025, 8_000, 7_350
]

private struct AACBitReader {
    let data: Data
    var bitOffset = 0

    mutating func read(_ count: Int) throws -> UInt32 {
        guard count >= 0, count <= 32,
              bitOffset <= data.count * 8,
              count <= data.count * 8 - bitOffset else {
            throw ISOBMFFError.malformed("truncated AAC AudioSpecificConfig")
        }
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = data[bitOffset / 8]
            let shift = 7 - (bitOffset % 8)
            value = (value << 1) | UInt32((byte >> shift) & 1)
            bitOffset += 1
        }
        return value
    }
}

private func parseAACConfiguration(_ box: ISOBox, data: Data) throws -> AACDecoderConfiguration {
    let reader = try ByteReader(data: data, range: box.payloadRange)
    try reader.require(5, context: "esds")
    let descriptorRange = (box.payloadRange.lowerBound + 4)..<box.payloadRange.upperBound
    guard let specificConfig = try findDecoderSpecificInfo(in: descriptorRange, data: data) else {
        throw ISOBMFFError.missing("AAC AudioSpecificConfig")
    }
    var bits = AACBitReader(data: specificConfig)
    var objectType = try bits.read(5)
    if objectType == 31 {
        objectType = 32 + (try bits.read(6))
    }
    guard objectType > 0, objectType <= UInt8.max else {
        throw ISOBMFFError.unsupported("AAC audio object type")
    }
    let frequencyIndex = try bits.read(4)
    let sampleRate: UInt32
    if frequencyIndex == 15 {
        sampleRate = try bits.read(24)
        guard sampleRate > 0 else {
            throw ISOBMFFError.malformed("zero explicit AAC sample rate")
        }
    } else {
        guard Int(frequencyIndex) < aacSampleRates.count else {
            throw ISOBMFFError.unsupported("reserved AAC sample rate")
        }
        sampleRate = aacSampleRates[Int(frequencyIndex)]
    }
    let channelConfiguration = try bits.read(4)
    guard channelConfiguration > 0 else {
        throw ISOBMFFError.unsupported("AAC program config element")
    }
    return AACDecoderConfiguration(
        audioSpecificConfig: specificConfig,
        audioObjectType: UInt8(objectType),
        samplingFrequencyIndex: UInt8(frequencyIndex),
        sampleRate: sampleRate,
        channelConfiguration: UInt8(channelConfiguration)
    )
}

private func findDecoderSpecificInfo(in range: Range<Int>, data: Data) throws -> Data? {
    let reader = try ByteReader(data: data, range: range)
    var cursor = 0
    while cursor < range.count {
        try reader.require(2, at: cursor, context: "MPEG-4 descriptor")
        let tag = reader.uint8(at: cursor)
        cursor += 1
        var length = 0
        var hasTerminator = false
        for _ in 0..<4 {
            try reader.require(1, at: cursor, context: "MPEG-4 descriptor length")
            let byte = reader.uint8(at: cursor)
            cursor += 1
            guard length <= (Int.max >> 7) else {
                throw ISOBMFFError.malformed("descriptor length overflow")
            }
            length = (length << 7) | Int(byte & 0x7f)
            if byte & 0x80 == 0 {
                hasTerminator = true
                break
            }
        }
        guard hasTerminator else {
            throw ISOBMFFError.malformed("unterminated descriptor length")
        }
        try reader.require(length, at: cursor, context: "MPEG-4 descriptor payload")
        let payloadStart = range.lowerBound + cursor
        let payloadRange = payloadStart..<(payloadStart + length)
        if tag == 0x05 {
            return data.subdata(in: payloadRange)
        }

        let childSkip: Int?
        switch tag {
        case 0x03:
            guard length >= 3 else {
                throw ISOBMFFError.malformed("truncated ES descriptor")
            }
            let payloadReader = try ByteReader(data: data, range: payloadRange)
            let flags = payloadReader.uint8(at: 2)
            var skip = 3
            if flags & 0x80 != 0 { skip += 2 }
            if flags & 0x40 != 0 {
                try payloadReader.require(1, at: skip, context: "ES descriptor URL length")
                skip += 1 + Int(payloadReader.uint8(at: skip))
            }
            if flags & 0x20 != 0 { skip += 2 }
            childSkip = skip
        case 0x04:
            childSkip = 13
        default:
            childSkip = nil
        }

        if let childSkip, childSkip <= length,
           let found = try findDecoderSpecificInfo(
            in: (payloadRange.lowerBound + childSkip)..<payloadRange.upperBound,
            data: data
           ) {
            return found
        }
        cursor += length
    }
    return nil
}

// MARK: - Media segment

private struct TrackFragmentHeader {
    let trackID: UInt32
    let baseDataOffset: UInt64?
    let defaultBaseIsMoof: Bool
    let defaultDuration: UInt32?
    let defaultSize: UInt32?
    let defaultFlags: UInt32?
}

private struct TrackRunSample {
    let duration: UInt32?
    let size: UInt32?
    let flags: UInt32?
    let compositionOffset: Int64
}

private struct TrackRun {
    let dataOffset: Int32?
    let firstSampleFlags: UInt32?
    let samples: [TrackRunSample]
}

private func parseTrackFragment(
    _ traf: ISOBox,
    moof: ISOBox,
    data: Data,
    mediaDataRanges: [Range<Int>],
    initialization: ISOBMFFInitialization,
    implicitBaseDataOffset: Int?
) throws -> (samples: [ISOBMFFSample], dataEnd: Int?) {
    let children = try boxes(in: traf.payloadRange, data: data)
    guard let tfhdBox = children.first(where: { $0.type == .tfhd }) else {
        throw ISOBMFFError.missing("tfhd")
    }
    guard let tfdtBox = children.first(where: { $0.type == .tfdt }) else {
        throw ISOBMFFError.missing("tfdt")
    }
    let header = try parseTrackFragmentHeader(tfhdBox, data: data)
    guard let track = initialization.tracks[header.trackID] else {
        throw ISOBMFFError.malformed("fragment references unknown track \(header.trackID)")
    }
    var decodeTime = try parseBaseDecodeTime(tfdtBox, data: data)

    let baseDataOffset: Int
    if let explicit = header.baseDataOffset {
        guard explicit <= UInt64(Int.max) else {
            throw ISOBMFFError.malformed("base data offset exceeds addressable memory")
        }
        baseDataOffset = Int(explicit)
    } else if header.defaultBaseIsMoof {
        baseDataOffset = moof.start
    } else if let implicitBaseDataOffset {
        baseDataOffset = implicitBaseDataOffset
    } else {
        baseDataOffset = moof.start
    }

    var output: [ISOBMFFSample] = []
    var previousRunEnd: Int?
    let runBoxes = children.filter { $0.type == .trun }
    guard !runBoxes.isEmpty else {
        throw ISOBMFFError.missing("trun")
    }

    for runBox in runBoxes {
        let run = try parseTrackRun(runBox, data: data)
        let runStart: Int
        if let relativeOffset = run.dataOffset {
            runStart = try adding(baseDataOffset, Int(relativeOffset), context: "trun data offset")
        } else if let previousRunEnd {
            runStart = previousRunEnd
        } else {
            runStart = baseDataOffset
        }
        var sampleDataOffset = runStart

        for (sampleIndex, runSample) in run.samples.enumerated() {
            let duration = runSample.duration ?? header.defaultDuration ?? track.defaultSampleDuration
            let size = runSample.size ?? header.defaultSize ?? track.defaultSampleSize
            let flags = runSample.flags
                ?? (sampleIndex == 0 ? run.firstSampleFlags : nil)
                ?? header.defaultFlags
                ?? track.defaultSampleFlags

            guard duration > 0 else {
                throw ISOBMFFError.missing("sample duration for track \(track.id)")
            }
            guard size > 0 else {
                throw ISOBMFFError.missing("sample size for track \(track.id)")
            }
            let sampleEnd = try adding(sampleDataOffset, Int(size), context: "sample data size")
            let sampleRange = sampleDataOffset..<sampleEnd
            guard mediaDataRanges.contains(where: {
                sampleRange.lowerBound >= $0.lowerBound && sampleRange.upperBound <= $0.upperBound
            }) else {
                throw ISOBMFFError.malformed("sample data lies outside mdat")
            }

            guard decodeTime <= UInt64(Int64.max) else {
                throw ISOBMFFError.malformed("decode timestamp exceeds signed timestamp range")
            }
            let decodeTimeSigned = Int64(decodeTime)
            let (presentationTime, overflow) = decodeTimeSigned.addingReportingOverflow(runSample.compositionOffset)
            guard !overflow else {
                throw ISOBMFFError.malformed("presentation timestamp overflow")
            }
            output.append(ISOBMFFSample(
                trackID: track.id,
                kind: track.kind,
                decodeTime: decodeTime,
                presentationTime: presentationTime,
                duration: duration,
                isRandomAccess: track.kind == .audio || flags & 0x0001_0000 == 0,
                data: data.subdata(in: sampleRange)
            ))
            sampleDataOffset = sampleEnd
            let (nextDecodeTime, decodeOverflow) = decodeTime.addingReportingOverflow(UInt64(duration))
            guard !decodeOverflow else {
                throw ISOBMFFError.malformed("decode timestamp overflow")
            }
            decodeTime = nextDecodeTime
        }
        previousRunEnd = sampleDataOffset
    }
    return (output, previousRunEnd)
}

private func parseTrackFragmentHeader(_ box: ISOBox, data: Data) throws -> TrackFragmentHeader {
    let reader = try ByteReader(data: data, range: box.payloadRange)
    try reader.require(8, context: "tfhd")
    guard reader.uint8(at: 0) == 0 else {
        throw ISOBMFFError.unsupported("tfhd version")
    }
    let flags = reader.uint24(at: 1)
    var cursor = 8
    let trackID = reader.uint32(at: 4)
    let baseDataOffset: UInt64?
    let defaultDuration: UInt32?
    let defaultSize: UInt32?
    let defaultFlags: UInt32?

    if flags & 0x000001 != 0 {
        try reader.require(8, at: cursor, context: "tfhd base data offset")
        baseDataOffset = reader.uint64(at: cursor)
        cursor += 8
    } else {
        baseDataOffset = nil
    }
    if flags & 0x000002 != 0 {
        try reader.require(4, at: cursor, context: "tfhd sample description index")
        cursor += 4
    }
    if flags & 0x000008 != 0 {
        try reader.require(4, at: cursor, context: "tfhd default duration")
        defaultDuration = reader.uint32(at: cursor)
        cursor += 4
    } else {
        defaultDuration = nil
    }
    if flags & 0x000010 != 0 {
        try reader.require(4, at: cursor, context: "tfhd default size")
        defaultSize = reader.uint32(at: cursor)
        cursor += 4
    } else {
        defaultSize = nil
    }
    if flags & 0x000020 != 0 {
        try reader.require(4, at: cursor, context: "tfhd default flags")
        defaultFlags = reader.uint32(at: cursor)
    } else {
        defaultFlags = nil
    }
    return TrackFragmentHeader(
        trackID: trackID,
        baseDataOffset: baseDataOffset,
        defaultBaseIsMoof: flags & 0x020000 != 0,
        defaultDuration: defaultDuration,
        defaultSize: defaultSize,
        defaultFlags: defaultFlags
    )
}

private func parseBaseDecodeTime(_ box: ISOBox, data: Data) throws -> UInt64 {
    let reader = try ByteReader(data: data, range: box.payloadRange)
    try reader.require(4, context: "tfdt")
    switch reader.uint8(at: 0) {
    case 0:
        try reader.require(8, context: "tfdt version 0")
        return UInt64(reader.uint32(at: 4))
    case 1:
        try reader.require(12, context: "tfdt version 1")
        return reader.uint64(at: 4)
    default:
        throw ISOBMFFError.unsupported("tfdt version")
    }
}

private func parseTrackRun(_ box: ISOBox, data: Data) throws -> TrackRun {
    let reader = try ByteReader(data: data, range: box.payloadRange)
    try reader.require(8, context: "trun")
    let version = reader.uint8(at: 0)
    guard version == 0 || version == 1 else {
        throw ISOBMFFError.unsupported("trun version")
    }
    let flags = reader.uint24(at: 1)
    let sampleCount = Int(reader.uint32(at: 4))
    // Every sample accepted below must contain at least one byte in `mdat`.
    // This also prevents a tiny defaulted `trun` from claiming billions of
    // samples and forcing an input-disproportionate allocation.
    guard sampleCount <= data.count else {
        throw ISOBMFFError.malformed("trun sample count exceeds input size")
    }
    var cursor = 8
    let dataOffset: Int32?
    let firstSampleFlags: UInt32?

    if flags & 0x000001 != 0 {
        try reader.require(4, at: cursor, context: "trun data offset")
        dataOffset = reader.int32(at: cursor)
        cursor += 4
    } else {
        dataOffset = nil
    }
    if flags & 0x000004 != 0 {
        try reader.require(4, at: cursor, context: "trun first sample flags")
        firstSampleFlags = reader.uint32(at: cursor)
        cursor += 4
    } else {
        firstSampleFlags = nil
    }

    let perSampleByteCount =
        (flags & 0x000100 != 0 ? 4 : 0) +
        (flags & 0x000200 != 0 ? 4 : 0) +
        (flags & 0x000400 != 0 ? 4 : 0) +
        (flags & 0x000800 != 0 ? 4 : 0)
    guard sampleCount == 0 || perSampleByteCount <= (reader.range.count - cursor) / sampleCount else {
        throw ISOBMFFError.malformed("truncated trun sample table")
    }

    var samples: [TrackRunSample] = []
    samples.reserveCapacity(sampleCount)
    for _ in 0..<sampleCount {
        let duration: UInt32?
        let size: UInt32?
        let sampleFlags: UInt32?
        let compositionOffset: Int64
        if flags & 0x000100 != 0 {
            duration = reader.uint32(at: cursor)
            cursor += 4
        } else { duration = nil }
        if flags & 0x000200 != 0 {
            size = reader.uint32(at: cursor)
            cursor += 4
        } else { size = nil }
        if flags & 0x000400 != 0 {
            sampleFlags = reader.uint32(at: cursor)
            cursor += 4
        } else { sampleFlags = nil }
        if flags & 0x000800 != 0 {
            compositionOffset = version == 0
                ? Int64(reader.uint32(at: cursor))
                : Int64(reader.int32(at: cursor))
            cursor += 4
        } else {
            compositionOffset = 0
        }
        samples.append(TrackRunSample(
            duration: duration,
            size: size,
            flags: sampleFlags,
            compositionOffset: compositionOffset
        ))
    }
    return TrackRun(dataOffset: dataOffset, firstSampleFlags: firstSampleFlags, samples: samples)
}

private func adding(_ left: Int, _ right: Int, context: String) throws -> Int {
    let (result, overflow) = left.addingReportingOverflow(right)
    guard !overflow, result >= 0 else {
        throw ISOBMFFError.malformed("\(context) overflow")
    }
    return result
}
