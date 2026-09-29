import Foundation

/// Move a selected fMP4 window to its own zero-based timeline. Both tracks
/// receive the same time shift; sample payloads, durations and GOPs stay intact.
struct HighlightClipAssembler {
    private let initialization: ISOBMFFInitialization
    private let origin: Double

    init(initialization data: Data, first: Data?) throws {
        let reader = ISOBMFFReader()
        let metadata = try reader.parseInitializationSegment(data)
        initialization = metadata
        guard let first else { throw HighlightError.missingInitialization }
        let samples = try reader.parseMediaSegment(first, initialization: initialization).samples
        guard samples.first(where: { $0.kind == .video })?.isRandomAccess == true else {
            throw ISOBMFFError.malformed("highlight does not start on a keyframe")
        }
        origin = try samples.map { sample in
            guard let track = metadata.tracks[sample.trackID], track.timescale > 0 else {
                throw ISOBMFFError.malformed("highlight track timescale")
            }
            return min(Double(sample.decodeTime), Double(sample.presentationTime)) / Double(track.timescale)
        }.min() ?? 0
    }

    func normalize(_ source: Data, fileOffset: Int) throws -> Data {
        var data = Data(source)
        for box in try boxes(data, range: 0..<data.count) {
            if box.type == "sidx" {
                guard box.payload.count >= 20 else { throw ISOBMFFError.malformed("highlight sidx") }
                let scale = try read(data, at: box.payload.lowerBound + 8, width: 4)
                try shift(&data, at: box.payload.lowerBound + 12,
                          width: data[box.payload.lowerBound] == 1 ? 8 : 4, timescale: scale)
            }
            guard box.type == "moof" else { continue }
            for traf in try boxes(data, range: box.payload) where traf.type == "traf" {
                let children = try boxes(data, range: traf.payload)
                guard let header = children.first(where: { $0.type == "tfhd" }), header.payload.count >= 8,
                      let timing = children.first(where: { $0.type == "tfdt" }), timing.payload.count >= 8 else {
                    throw ISOBMFFError.missing("highlight tfhd/tfdt")
                }
                let id = UInt32(try read(data, at: header.payload.lowerBound + 4, width: 4))
                guard let track = initialization.tracks[id] else { throw ISOBMFFError.missing("highlight track") }
                let flags = try read(data, at: header.payload.lowerBound + 1, width: 3)
                if flags & 1 != 0 {
                    // A fragment-local explicit base becomes a file-global base.
                    guard header.payload.count >= 16 else { throw ISOBMFFError.malformed("highlight base offset") }
                    let base = try read(data, at: header.payload.lowerBound + 8, width: 8)
                    guard base <= UInt64(source.count) else { throw ISOBMFFError.unsupported("absolute fragment base") }
                    write(&data, at: header.payload.lowerBound + 8, width: 8, value: UInt64(fileOffset) + base)
                }
                let version = data[timing.payload.lowerBound]
                guard version <= 1, timing.payload.count >= (version == 1 ? 12 : 8) else {
                    throw ISOBMFFError.unsupported("highlight tfdt version")
                }
                try shift(&data, at: timing.payload.lowerBound + 4,
                          width: version == 1 ? 8 : 4, timescale: UInt64(track.timescale))
            }
        }
        return data
    }

    private func shift(_ data: inout Data, at offset: Int, width: Int, timescale: UInt64) throws {
        let time = try read(data, at: offset, width: width)
        let shift = origin * Double(timescale)
        guard shift.isFinite, shift >= 0, shift < Double(UInt64.max) else {
            throw ISOBMFFError.malformed("highlight time origin")
        }
        let ticks = UInt64(shift.rounded(.down))
        guard time >= ticks else { throw ISOBMFFError.malformed("highlight timestamp before origin") }
        write(&data, at: offset, width: width, value: time - ticks)
    }

    private struct Box {
        var type: String
        var payload: Range<Int>
    }

    private func boxes(_ data: Data, range: Range<Int>) throws -> [Box] {
        var cursor = range.lowerBound
        var result: [Box] = []
        while cursor < range.upperBound {
            guard range.upperBound - cursor >= 8 else { throw ISOBMFFError.malformed("highlight box header") }
            let size = try read(data, at: cursor, width: 4)
            let header = size == 1 ? 16 : 8
            let length = size == 0 ? UInt64(range.upperBound - cursor) : size == 1 ? try read(data, at: cursor + 8, width: 8) : size
            guard length >= header, length <= UInt64(range.upperBound - cursor) else {
                throw ISOBMFFError.malformed("highlight box bounds")
            }
            let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            let end = cursor + Int(length)
            result.append(Box(type: type, payload: (cursor + header)..<end))
            cursor = end
        }
        return result
    }

    private func read(_ data: Data, at offset: Int, width: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count, width <= data.count - offset else {
            throw ISOBMFFError.malformed("highlight field bounds")
        }
        return data[offset..<(offset + width)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private func write(_ data: inout Data, at offset: Int, width: Int, value: UInt64) {
        for index in 0..<width { data[offset + index] = UInt8(truncatingIfNeeded: value >> ((width - 1 - index) * 8)) }
    }
}
