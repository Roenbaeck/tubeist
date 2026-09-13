//
//  Fragment.swift
//  Tubeist
//

import Foundation

/// An encoded ISOBMFF fragment shared by the recording and YouTube pipelines.
struct Fragment: Sendable, CustomStringConvertible {
    let sequence: Int
    let segment: Data
    let duration: Double
    var discontinuity: Bool = false
    var type: SegmentType = .separable

    enum SegmentType: Sendable, Equatable {
        case initialization
        case separable
        case finalization
    }

    func segmentType() -> String {
        switch type {
        case .separable: "Separable"
        case .initialization: "Initialization"
        case .finalization: "Finalization"
        }
    }

    var description: String {
        """
        Fragment:
        - Sequence: \(sequence)
        - Segment: \(segment.count) bytes
        - Duration: \(duration)s
        - Discontinuity: \(discontinuity)
        - Type: \(segmentType())
        """
    }
}
