import Foundation

/// The highest temporal layer's SPS ordering limits (H.265, 7.3.2.2.1).
/// These describe the decoder, independently of VideoToolbox's compression window.
struct HEVCReordering: Equatable, Sendable {
    let pictureBufferCount: Int
    let reorderFrames: Int

    init(sequenceParameterSets: [Data]) throws {
        guard let first = sequenceParameterSets.first else {
            throw MediaEncodingError.invalid("Missing HEVC sequence parameter set")
        }
        let limits = try Self.read(first)
        for sps in sequenceParameterSets.dropFirst() {
            guard try Self.read(sps) == limits else {
                throw MediaEncodingError.invalid("HEVC sequence parameter sets disagree on picture reordering")
            }
        }
        self = limits
    }

    private init(pictureBufferCount: Int, reorderFrames: Int) {
        self.pictureBufferCount = pictureBufferCount
        self.reorderFrames = reorderFrames
    }

    private static func read(_ sps: Data) throws -> Self {
        guard (3...65_536).contains(sps.count) else {
            throw MediaEncodingError.invalid("Invalid HEVC SPS size")
        }
        let bytes = [UInt8](sps)
        guard bytes[0] == 0x42, bytes[1] == 1 else {
            throw MediaEncodingError.invalid("Invalid or unsupported HEVC SPS header")
        }
        var bits = try HEVCOrderingBits(escaped: Array(bytes.dropFirst(2)))
        try bits.skip(4) // sps_video_parameter_set_id
        let highestLayer = try bits.read(3)
        guard highestLayer <= 6 else { throw MediaEncodingError.invalid("Invalid HEVC temporal layer count") }
        try bits.skip(1) // sps_temporal_id_nesting_flag
        try bits.skip(96) // general profile_tier_level, including level_idc
        var profiles: [Bool] = [], levels: [Bool] = []
        for _ in 0..<highestLayer {
            profiles.append(try bits.read(1) != 0)
            levels.append(try bits.read(1) != 0)
        }
        if highestLayer > 0 { try bits.skip((8 - highestLayer) * 2) }
        for index in 0..<highestLayer {
            if profiles[index] { try bits.skip(88) }
            if levels[index] { try bits.skip(8) }
        }
        _ = try bits.ue(maximum: 15) // sps_seq_parameter_set_id
        let chroma = try bits.ue(maximum: 3)
        if chroma == 3 { try bits.skip(1) } // separate_colour_plane_flag
        let width = try bits.ue(), height = try bits.ue()
        guard width > 0, height > 0 else { throw MediaEncodingError.invalid("Invalid HEVC picture dimensions") }
        if try bits.read(1) != 0 { // conformance_window_flag
            for _ in 0..<4 { _ = try bits.ue() }
        }
        _ = try bits.ue(maximum: 8) // bit_depth_luma_minus8
        _ = try bits.ue(maximum: 8) // bit_depth_chroma_minus8
        _ = try bits.ue(maximum: 12) // log2_max_pic_order_cnt_lsb_minus4
        let allLayers = try bits.read(1) != 0
        var previous: Self?
        for _ in (allLayers ? 0 : highestLayer)...highestLayer {
            let buffersMinusOne = try bits.ue(maximum: 15)
            let reorder = try bits.ue(maximum: buffersMinusOne)
            _ = try bits.ue() // sps_max_latency_increase_plus1
            let limits = Self(pictureBufferCount: buffersMinusOne + 1, reorderFrames: reorder)
            if let previous {
                guard limits.pictureBufferCount >= previous.pictureBufferCount,
                      limits.reorderFrames >= previous.reorderFrames else {
                    throw MediaEncodingError.invalid("Invalid HEVC sublayer ordering limits")
                }
            }
            previous = limits
        }
        return previous! // There is always at least one ordering entry.
    }
}

/// Only reads the bounded SPS prefix needed for picture ordering, not slice data.
private struct HEVCOrderingBits {
    let bytes: [UInt8]
    var offset = 0

    init(escaped: [UInt8]) throws {
        var rbsp: [UInt8] = []
        var zeros = 0
        for (index, byte) in escaped.enumerated() {
            if zeros == 2, byte == 3 {
                guard index + 1 < escaped.count, escaped[index + 1] <= 3 else {
                    throw MediaEncodingError.invalid("Invalid HEVC emulation-prevention byte")
                }
                zeros = 0
                continue
            }
            rbsp.append(byte)
            zeros = byte == 0 ? min(2, zeros + 1) : 0
        }
        bytes = rbsp
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= bytes.count * 8 - offset else {
            throw MediaEncodingError.invalid("Truncated HEVC ordering information")
        }
        offset += count
    }

    mutating func read(_ count: Int) throws -> Int {
        guard (0...32).contains(count), count <= bytes.count * 8 - offset else {
            throw MediaEncodingError.invalid("Truncated HEVC ordering information")
        }
        var value = 0
        for _ in 0..<count {
            value = (value << 1) | Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
            offset += 1
        }
        return value
    }

    mutating func ue(maximum: Int = Int(UInt32.max)) throws -> Int {
        var zeros = 0
        while try read(1) == 0 {
            zeros += 1
            guard zeros <= 31 else { throw MediaEncodingError.invalid("Invalid HEVC Exp-Golomb value") }
        }
        let value = (1 << zeros) - 1 + (try read(zeros))
        guard value <= maximum else { throw MediaEncodingError.invalid("Invalid HEVC ordering value") }
        return value
    }
}
