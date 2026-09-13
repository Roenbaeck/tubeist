import Foundation

/// Only complete, independently decodable TS segments may cross a missing
/// sequence. MP4 initialization and recording fragments must never be skipped.
struct FragmentReorderBuffer {
    private var pending: [Int: Fragment] = [:]
    private(set) var nextSequence = 0
    private var gapStartedAt: TimeInterval?
    let maximumCount: Int
    let maximumWait: TimeInterval

    init(maximumCount: Int = 8, maximumWait: TimeInterval = 2) {
        self.maximumCount = maximumCount
        self.maximumWait = maximumWait
    }

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }

    mutating func insert(_ fragment: Fragment) {
        guard fragment.sequence >= nextSequence, pending[fragment.sequence] == nil else { return }
        if pending.count >= maximumCount {
            // The drain can be suspended in another actor. Bound memory even
            // then, but always let the missing expected segment close its gap.
            guard fragment.sequence == nextSequence, let last = pending.keys.max() else { return }
            pending.removeValue(forKey: last)
        }
        pending[fragment.sequence] = fragment
    }

    mutating func takeNext(now: TimeInterval) throws -> Fragment? {
        if let next = pending.removeValue(forKey: nextSequence) {
            nextSequence += 1
            gapStartedAt = nil
            return next
        }
        guard let first = pending.keys.min() else { gapStartedAt = nil; return nil }
        if gapStartedAt == nil { gapStartedAt = now }
        guard pending.count >= maximumCount || now - gapStartedAt! >= maximumWait else { return nil }
        guard var next = pending[first], next.container == .mpegTransportStream else {
            throw ContentPackagingError.fragmentSequenceGap(expected: nextSequence, pending: pending.keys.sorted())
        }
        pending.removeValue(forKey: first)
        nextSequence = first + 1
        gapStartedAt = nil
        next.discontinuity = true
        return next
    }
}
