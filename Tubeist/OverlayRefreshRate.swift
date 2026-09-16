import Foundation

enum OverlayRefreshRate: Int, CaseIterable, Identifiable, Sendable {
    case once = 1
    case three = 3
    case ten = 10
    case thirty = 30

    var id: Int { rawValue }
    var interval: TimeInterval { 1 / Double(rawValue) }
    var label: String { "\(rawValue) update\(self == .once ? "" : "s")/second" }

    static func stored(_ value: Int) -> Self { Self(rawValue: value) ?? .once }
}

/// Coalesces changes into one pending snapshot, using monotonic seconds.
/// Completing slow work never creates credits for a later burst of captures.
struct OverlayCaptureSchedule {
    var rate: OverlayRefreshRate = .once
    private(set) var isPending = false
    private(set) var isCapturing = false
    private var lastStart: TimeInterval?

    mutating func request() { isPending = true }

    func delay(at now: TimeInterval) -> TimeInterval? {
        guard isPending, !isCapturing else { return nil }
        return lastStart.map { max(0, $0 + rate.interval - now) } ?? 0
    }

    mutating func begin(at now: TimeInterval) -> Bool {
        guard delay(at: now) == 0 else { return false }
        isPending = false
        isCapturing = true
        lastStart = now
        return true
    }

    mutating func complete() { isCapturing = false }

    mutating func reset() {
        isPending = false
        lastStart = nil
        // An outstanding WebKit callback must finish before another capture.
    }
}
