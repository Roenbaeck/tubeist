//
//  Constants.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-11-26.
//

import Foundation
import AVFoundation
import CoreMedia
import WebKit

// Generic settings
let DEFAULT_MONITOR: Monitor = .camera
let CAMERA_CONTROL_QUEUE = DispatchQueue(label: "com.subside.Tubeist.CameraControlQueue")

@globalActor actor PipelineActor: GlobalActor {
    static let shared = PipelineActor()
    static let queue = DispatchQueue(label: "com.subside.Tubeist.PipelineQueue", qos: .userInitiated) //, attributes: .concurrent)
}
@globalActor actor UploadActor: GlobalActor {
    static let shared = UploadActor()
}

// CameraMonitor settings
let DEFAULT_CAMERA = "Back Camera" // available on most (all?) devices
let DEFAULT_MICROPHONE = "iPhone Microphone"
let ZOOM_LIMIT: Double = 20.0
let DEFAULT_FRAMERATE: Double = 60
let DEFAULT_CAPTURE_WIDTH: Int = 3840
let DEFAULT_CAPTURE_HEIGHT: Int = 2160

// Color settings
let CG_COLOR_SPACE: CGColorSpace = .init(name: CGColorSpace.itur_2100_HLG)!
let AV_COLOR_SPACE: AVCaptureColorSpace = .HLG_BT2020

// OverlayBundler settings
let BOUNDING_BOX_SEARCH_WIDTH: Int = 160 // needs to be a divisor of possible output widths (960, 1280, 1920, 2560, 3840)

// AssetInterceptor settings
let DEFAULT_COMPRESSED_WIDTH: Int = 1920
let DEFAULT_COMPRESSED_HEIGHT: Int = 1080
let DEFAULT_VIDEO_BITRATE: Int = 4_000_000
let DEFAULT_AUDIO_BITRATE: Int = 48_000
let DEFAULT_AUDIO_CHANNELS: Int = 2
let DEFAULT_KEYFRAME_INTERVAL: Double = 2.0 // seconds
let FRAGMENT_DURATION: Double = 2.0 // seconds
let FRAGMENT_MINIMUM_DURATION: Double = 0.010 // at least 10ms (to ignore very short fragments at the end of the stream)
let REFERENCE_TIMEPOINT: Date = {
    let referenceTime = Date() // always UTC?
    var calendar = Calendar.current
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let previousYear = calendar.component(.year, from: referenceTime) - 1
    let startOfPreviousYear = calendar.date(from: DateComponents(year: previousYear, month: 1, day: 1))!
    return startOfPreviousYear
}()

// AudioMeter settings
let AUDIO_METER_HEIGHT: CGFloat = 3

// Journal settings
let MAX_LOG_ENTRIES = 1000

// FragmentPusher settings
let DEFAULT_TARGET = "youtube"
let MISSING_STREAM_KEY = "missing_stream_key"
let NETWORK_METRICS_SLIDING_WINDOW: TimeInterval = 10 // seconds
let MAX_UPLOAD_RETRIES = 30
let MAX_CONCURRENT_UPLOADS = 3
let MAX_BUFFERED_FRAGMENTS = 90

// Web View Process Pool
@MainActor let WK_PROCESS_POOL = WKProcessPool()

// Useful for debugging purposes
func printCurrentExecutionInfo(message: String = "") {
    let currentQueue = OperationQueue.current?.name ?? "No Queue"
    let underlyingCurrentQueue = OperationQueue.current?.underlyingQueue?.label ?? "No Queue"
    let thread = Thread.current
    let threadName = thread.name ?? (thread.isMainThread ? "Main Thread" : "Background Thread")
    let threadNumber = thread.hashValue

    print("""
    --------------------------------------------------
    \(message)
    Queue: \(currentQueue)
    Underlying: \(underlyingCurrentQueue)
    Thread: \(threadName) (ID: \(threadNumber))
    Is Main Thread: \(thread.isMainThread)
    Call Stack:
    \(Thread.callStackSymbols.joined(separator: "\n"))
    --------------------------------------------------
    """)
}
