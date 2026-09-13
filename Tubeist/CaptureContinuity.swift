import Foundation
import CoreMedia

enum CaptureContinuityError: LocalizedError {
    case discontinuity
    case stalled
    case invalidTiming

    var errorDescription: String? {
        switch self {
        case .discontinuity: "Capture timestamps require coordinated audio/video recovery"
        case .stalled: "Camera or microphone delivery did not recover within 30 seconds"
        case .invalidTiming: "Capture delivered invalid sample timing"
        }
    }
}

/// Uses elapsed wall time, independently of capture timestamps and synthetic
/// samples. Duplicate frames therefore cannot keep a stalled camera healthy.
struct CaptureLiveness {
    enum State: Equatable { case starting, healthy, concealing, recovering, failed }
    let startedAt: TimeInterval
    private(set) var videoAt: TimeInterval?
    private(set) var audioAt: TimeInterval?
    static let concealmentLimit: TimeInterval = 2
    static let arrivalGrace: TimeInterval = 0.2

    mutating func receivedVideo(at now: TimeInterval) { videoAt = now }
    mutating func receivedAudio(at now: TimeInterval) { audioAt = now }

    func state(at now: TimeInterval) -> State {
        let oldest = min(videoAt ?? startedAt, audioAt ?? startedAt)
        let age = max(0, now - oldest)
        if age >= 30 { return .failed }
        if videoAt == nil || audioAt == nil {
            return age >= Self.concealmentLimit ? .recovering : .starting
        }
        if age >= Self.concealmentLimit { return .recovering }
        return age >= Self.arrivalGrace ? .concealing : .healthy
    }
}

struct AudioCaptureRepair {
    struct Plan {
        let trimFrames: Int
        let silenceFrames: Int
        let silencePTS: CMTime
        let inputPTS: CMTime
    }

    let sampleRate: Double
    private(set) var expectedPTS: CMTime?

    /// Ignore complete duplicates/late blocks; trim a partially late block.
    /// A sub-millisecond discrepancy is clock drift/rounding, not missing PCM.
    func plan(pts: CMTime, frames: Int) throws -> Plan? {
        guard pts.isNumeric, sampleRate.isFinite, sampleRate > 0, frames > 0 else {
            throw CaptureContinuityError.invalidTiming
        }
        let expected = expectedPTS ?? pts
        let delta = CMTimeSubtract(pts, expected).seconds
        guard delta.isFinite else { throw CaptureContinuityError.invalidTiming }
        let tolerance = max(0.0005, 2 / sampleRate)
        if delta > CaptureLiveness.concealmentLimit { throw CaptureContinuityError.discontinuity }
        if -delta >= Double(frames) / sampleRate { return nil }
        let trim = delta < -tolerance ? min(frames, Int(ceil(-delta * sampleRate))) : 0
        guard trim < frames else { return nil }
        let silence = delta > tolerance ? Int((delta * sampleRate).rounded()) : 0
        return Plan(trimFrames: trim, silenceFrames: silence, silencePTS: expected,
                    inputPTS: CMTimeAdd(pts, CMTime(seconds: Double(trim) / sampleRate, preferredTimescale: 90_000)))
    }

    mutating func accepted(pts: CMTime, frames: Int) {
        expectedPTS = CMTimeAdd(pts, CMTime(seconds: Double(frames) / sampleRate, preferredTimescale: 90_000))
    }
}

struct VideoCaptureRepair {
    let frameDuration: CMTime
    private(set) var lastPTS: CMTime?

    func missingFrames(before pts: CMTime) throws -> [CMTime]? {
        guard pts.isNumeric else { throw CaptureContinuityError.invalidTiming }
        guard let lastPTS else { return [] }
        guard pts > lastPTS else { return nil }
        let delta = CMTimeSubtract(pts, lastPTS).seconds
        guard delta <= CaptureLiveness.concealmentLimit else { throw CaptureContinuityError.discontinuity }
        var result: [CMTime] = []
        var next = CMTimeAdd(lastPTS, frameDuration)
        while CMTimeSubtract(pts, next).seconds > frameDuration.seconds * 0.5 {
            result.append(next)
            next = CMTimeAdd(next, frameDuration)
        }
        return result
    }

    mutating func accepted(_ pts: CMTime) { lastPTS = pts }
}
