import AVFoundation
import Foundation

// Standalone app services. All media, recovery and upload code is production.
@globalActor actor PipelineActor: GlobalActor { static let shared = PipelineActor() }
let FRAGMENT_DURATION = 2.0
let AUDIO_SAMPLE_RATE = 44_100.0
struct Preset: Sendable {
    let width = 320, height = 180
    let frameRate = 30.0, keyframeInterval = 2.0
    let bitrateLadder = BitrateLadder(maximum: 1_000_000, minimum: 250_000)
    var audioChannels = 2
    let audioBitrate = 64_000, videoBitrate = 1_000_000
}
enum Settings { static let selectedPreset = Preset() }
enum LogLevel { case debug, info, warning, error }
func LOG(_ message: String, level: LogLevel) { if level != .debug { print(message) } }
enum StreamHealth { case unusable, degraded }
actor Streamer {
    static let shared = Streamer()
    func setStreamHealth(_ health: StreamHealth) {}
    func handleRuntimeFailure(_ error: any Error) { print("UNEXPECTED RUNTIME FAILURE: \(error)") }
}
enum ContentPackagingError: Error {
    case alreadyEncoding, videoNeverStarted
    case fragmentSequenceGap(expected: Int, pending: [Int])
}

final class ProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    func read() -> Double { lock.withLock { time } }
    func set(_ value: Double) { lock.withLock { time = value } }
}

actor ProbeFailures {
    private(set) var count = 0
    func record(_ error: any Error) { count += 1 }
}

/// Models scarce capture-owned storage. A slot returns only when every sample
/// and block-buffer reference to its original bytes has been released.
final class ProbeAudioCapturePool: @unchecked Sendable {
    private let lock = NSLock()
    private var inUse = 0
    private var exhausted = 0
    var exhaustionCount: Int { lock.withLock { exhausted } }
    var retainedBuffers: Int { lock.withLock { inUse } }

    func capture(_ input: CMSampleBuffer) throws -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetDataBuffer(input),
              let format = CMSampleBufferGetFormatDescription(input) else {
            throw MediaEncodingError.invalid("Capture pool needs PCM input")
        }
        let acquired = lock.withLock {
            guard inUse < 16 else { exhausted += 1; return false }
            inUse += 1
            return true
        }
        guard acquired else { return nil }
        let length = CMBlockBufferGetDataLength(source)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
        var custom = CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion,
            AllocateBlock: nil,
            FreeBlock: { reference, memory, _ in
                memory.deallocate()
                let pool = Unmanaged<ProbeAudioCapturePool>.fromOpaque(reference!).takeRetainedValue()
                pool.lock.withLock { pool.inUse -= 1 }
            },
            refCon: Unmanaged.passRetained(self).toOpaque()
        )
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: memory,
            blockLength: length, blockAllocator: nil, customBlockSource: &custom,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
        if status != noErr {
            memory.deallocate()
            Unmanaged<ProbeAudioCapturePool>.fromOpaque(custom.refCon!).release()
            lock.withLock { inUse -= 1 }
            try checkMediaStatus(status, "Creating limited capture storage")
        }
        try checkMediaStatus(CMBlockBufferCopyDataBytes(source, atOffset: 0, dataLength: length,
            destination: memory), "Filling capture storage")
        var timing = CMSampleTimingInfo()
        try checkMediaStatus(CMSampleBufferGetSampleTimingInfo(input, at: 0, timingInfoOut: &timing), "Reading capture timing")
        var sample: CMSampleBuffer?
        try checkMediaStatus(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block,
            formatDescription: format, sampleCount: CMSampleBufferGetNumSamples(input),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), "Creating limited capture sample")
        return sample
    }
}

actor ProbeTransport: YouTubeHLSHTTPTransport {
    private let folder: URL
    private var blocked: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private var stopped = false
    private var requests = 0
    private(set) var uploaded = 0
    init(folder: URL, blocked: Bool) { self.folder = folder; self.blocked = blocked }

    func send(_ request: URLRequest, body: Data) async throws -> YouTubeHLSHTTPResponse {
        if blocked { await withCheckedContinuation { waiter = $0 } }
        guard !stopped else { throw URLError(.cancelled) }
        let playlist = request.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl"
        let name = String(format: playlist ? "playlist_%03d.m3u8" : "upload_%03d.ts", requests)
        try body.write(to: folder.appendingPathComponent(name))
        requests += 1
        if !playlist { uploaded += 1 }
        return YouTubeHLSHTTPResponse(statusCode: 200)
    }

    func release() { blocked = false; waiter?.resume(); waiter = nil }
    func invalidate() { stopped = true; release() }
}
