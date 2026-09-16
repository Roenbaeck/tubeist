#if DEBUG
import Foundation
import Testing
@testable import Tubeist

struct HLSUploadReplayTests {
    private let hash = String(repeating: "a", count: 64)

    @Test func acceptsOrderedFiniteReplay() throws {
        let segment = HLSUploadReplay.Plan.Segment(filename: hash + ".ts", sha256: hash, duration: 2, availableAt: 2)
        try HLSUploadReplay.Plan(broadcastID: "S5gxxGltk64", segments: [segment]).validate()
    }

    @Test(arguments: [Double.nan, Double.infinity, -1, 601])
    func rejectsInvalidAvailability(time: Double) {
        let segment = HLSUploadReplay.Plan.Segment(filename: hash + ".ts", sha256: hash, duration: 2, availableAt: time)
        #expect(throws: HLSUploadReplay.Failure.self) {
            try HLSUploadReplay.Plan(broadcastID: "S5gxxGltk64", segments: [segment]).validate()
        }
    }

    @Test func rejectsReorderedSegmentsAndPathTraversal() {
        let first = HLSUploadReplay.Plan.Segment(filename: hash + ".ts", sha256: hash, duration: 2, availableAt: 4)
        let earlier = HLSUploadReplay.Plan.Segment(filename: hash + ".ts", sha256: hash, duration: 2, availableAt: 2)
        let unsafe = HLSUploadReplay.Plan.Segment(filename: "../" + hash + ".ts", sha256: hash, duration: 2, availableAt: 2)
        for segments in [[first, earlier], [unsafe], []] {
            #expect(throws: HLSUploadReplay.Failure.self) {
                try HLSUploadReplay.Plan(broadcastID: "S5gxxGltk64", segments: segments).validate()
            }
        }
    }
}
#endif
