import Foundation
import Testing
@testable import Tubeist

struct HEVCReorderingTests {
    @Test func actualIPhoneMain10SPSMatchesFFmpegTraceHeaders() throws {
        // Codec metadata only, extracted from the countdown capture; no media.
        let hex = "420101222000000300b00000030000030099a001e020021c4d8815ee45954d4244824020"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { index in
            UInt8(hex.dropFirst(index).prefix(2), radix: 16)!
        }
        let limits = try HEVCReordering(sequenceParameterSets: [Data(bytes)])
        #expect(limits.pictureBufferCount == 5)
        #expect(limits.reorderFrames == 2)
    }

    @Test(arguments: [0, 1, 2, 4, 15])
    func readsDepthWithoutAssumingTwoFrames(depth: Int) throws {
        let limits = try HEVCReordering(sequenceParameterSets: [sps(ordering: [(depth + 1, depth)])])
        #expect(limits.reorderFrames == depth)
        #expect(limits.pictureBufferCount == depth + 1)
    }

    @Test(arguments: [false, true])
    func highestTemporalLayerAndOptionalSyntax(allLayers: Bool) throws {
        let data = sps(ordering: allLayers ? [(2, 0), (4, 1), (5, 2)] : [(5, 2)],
                       highestLayer: 2, allLayers: allLayers, optionalSyntax: true)
        let limits = try HEVCReordering(sequenceParameterSets: [data])
        #expect(limits.reorderFrames == 2)
        #expect(limits.pictureBufferCount == 5)
        #expect(try HEVCReordering(sequenceParameterSets: [data, data]) == limits)
    }

    @Test func missingTruncatedAndInvalidOrderingAreRejected() throws {
        let valid = sps(ordering: [(5, 2)])
        #expect(throws: MediaEncodingError.self) { try HEVCReordering(sequenceParameterSets: []) }
        for length in 0..<(valid.count - 1) {
            #expect(throws: MediaEncodingError.self) {
                try HEVCReordering(sequenceParameterSets: [valid.prefix(length)])
            }
        }
        for invalid in [
            sps(ordering: [(5, 5)]), // reorder depth must be less than capacity
            sps(ordering: [(17, 2)]),
            sps(ordering: [(5, 2), (4, 1)], highestLayer: 1, allLayers: true),
            Data([0x40, 1, 0]),
            Data([0x42, 1, 0, 0, 3, 4]), // invalid escape
            Data([0x42, 1, 0, 0, 3])
        ] {
            #expect(throws: MediaEncodingError.self) { try HEVCReordering(sequenceParameterSets: [invalid]) }
        }
        #expect(throws: MediaEncodingError.self) {
            try HEVCReordering(sequenceParameterSets: [valid, sps(ordering: [(3, 1)])])
        }
    }

    private func sps(ordering: [(Int, Int)], highestLayer: Int = 0,
                     allLayers: Bool = false, optionalSyntax: Bool = false) -> Data {
        var b = SPSBits()
        b.write(0, 4); b.write(highestLayer, 3); b.write(1, 1)
        b.write(0, 96)
        for layer in 0..<highestLayer {
            b.write(layer == 0 ? 1 : 0, 1); b.write(1, 1)
        }
        if highestLayer > 0 { b.write(0, (8 - highestLayer) * 2) }
        for layer in 0..<highestLayer {
            if layer == 0 { b.write(0, 88) }
            b.write(0, 8)
        }
        b.ue(0); b.ue(optionalSyntax ? 3 : 1)
        if optionalSyntax { b.write(1, 1) }
        b.ue(1920); b.ue(1080)
        b.write(optionalSyntax ? 1 : 0, 1)
        if optionalSyntax { for value in [0, 2, 0, 2] { b.ue(value) } }
        b.ue(2); b.ue(2); b.ue(4)
        b.write(allLayers ? 1 : 0, 1)
        for (capacity, reorder) in ordering { b.ue(capacity - 1); b.ue(reorder); b.ue(0) }
        return b.nal()
    }
}

private struct SPSBits {
    var bits: [UInt8] = []
    mutating func write(_ value: Int, _ count: Int) {
        for shift in (0..<count).reversed() {
            bits.append(shift < Int.bitWidth ? UInt8((value >> shift) & 1) : 0)
        }
    }
    mutating func ue(_ value: Int) {
        let width = Int.bitWidth - (value + 1).leadingZeroBitCount
        write(0, width - 1); write(value + 1, width)
    }
    mutating func nal() -> Data {
        write(1, 1)
        while bits.count % 8 != 0 { write(0, 1) }
        var data = Data([0x42, 1]), zeros = 0
        for offset in stride(from: 0, to: bits.count, by: 8) {
            let byte = bits[offset..<offset + 8].reduce(UInt8(0)) { ($0 << 1) | $1 }
            if zeros == 2, byte <= 3 { data.append(3); zeros = 0 }
            data.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return data
    }
}
