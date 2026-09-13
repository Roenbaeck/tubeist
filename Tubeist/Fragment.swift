//
//  Fragment.swift
//  Tubeist
//

import Foundation

/// A complete encoded container fragment. Live upload uses MPEG-TS; the MP4
/// case remains useful for recording delegate output and fixture validation.
struct Fragment: Sendable, CustomStringConvertible {
    let sequence: Int
    let segment: Data
    let duration: Double
    var discontinuity: Bool = false
    var type: SegmentType = .separable
    var container: Container = .fragmentedMP4

    enum Container: Sendable, Equatable {
        case fragmentedMP4
        case mpegTransportStream
    }

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
