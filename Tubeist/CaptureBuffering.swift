import AVFoundation

enum CaptureBuffering {
    // A brief processing backlog, not a fixed delay. Both video stages use
    // the original arrival time so their waiting-time budgets cannot stack.
    static let duration: TimeInterval = 0.1
    static let videoPolicy: AsyncMailboxPolicy = .buffered(duration: duration, limit: 6)
    // Audio is cheap to retain and gaps are audible. Keep the original 32-block
    // allowance (about 0.7 seconds for 1,024-sample blocks), without video's
    // short arrival-age cutoff. Capacity is not an intentional playout delay.
    static let audioPolicy: AsyncMailboxPolicy = .fifo(limit: 32)
}

struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
    let receivedAt: TimeInterval

    init(value: CMSampleBuffer, receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.value = value
        self.receivedAt = receivedAt
    }

    var mailboxTiming: AsyncMailboxTiming {
        var duration = CMSampleBufferGetDuration(value).seconds
        if !duration.isFinite || duration <= 0 {
            if let format = CMSampleBufferGetFormatDescription(value),
               CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio,
               let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format),
               audio.pointee.mSampleRate > 0 {
                duration = Double(CMSampleBufferGetNumSamples(value)) / audio.pointee.mSampleRate
            } else {
                // Camera frames normally carry their duration; the count and
                // arrival-age limits remain in force if a frame omits it.
                duration = 1 / DEFAULT_FRAMERATE
            }
        }
        return AsyncMailboxTiming(duration: duration, receivedAt: receivedAt)
    }
}
