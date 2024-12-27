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
let STREAMING_QUEUE_CONCURRENT = DispatchQueue(label: "com.subside.StreamingQueueConcurrent", qos: .userInitiated, attributes: .concurrent)

// CameraMonitor settings
let DEFAULT_CAMERA = "Back Camera" // available on most (all?) devices
let ZOOM_LIMIT = 20.0
let DEFAULT_FRAMERATE: Int = 30
let CAPTURE_WIDTH: Int = 3840
let CAPTURE_HEIGHT: Int = 2160

// Color settings
let CG_COLOR_SPACE: CGColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
let AV_COLOR_SPACE: AVCaptureColorSpace = .HLG_BT2020

// AssetInterceptor settings
let DEFAULT_COMPRESSED_WIDTH: Int = 1920
let DEFAULT_COMPRESSED_HEIGHT: Int = 1080
let DEFAULT_VIDEO_BITRATE: Int = 4_000_000
let DEFAULT_AUDIO_BITRATE: Int = 48_000
let DEFAULT_AUDIO_CHANNELS: Int = 2
let DEFAULT_KEYFRAME_INTERVAL: Double = 2.0 // seconds
let FRAGMENT_DURATION: Int = 2 // seconds
let FRAGMENT_MINIMUM_DURATION: Double = 0.010 // at least 10ms (to ignore very short fragments at the end of the stream)
let TIMESCALE: Int = 60000 // something divisible with FRAMERATE
let FRAGMENT_CM_TIME = CMTimeMake(value: Int64(FRAGMENT_DURATION * TIMESCALE), timescale: Int32(TIMESCALE))

// AudioMeter settings
let AUDIO_METER_HEIGHT: CGFloat = 3

// Journal settings
let MAX_LOG_ENTRIES = 1000
func LOG(_ message: String, level: LogLevel = .info) {
    Journal.shared.log(message, level: level)
}

// FragmentPusher settings
let NETWORK_METRICS_SLIDING_WINDOW: TimeInterval = 10 // seconds
let MAX_UPLOAD_RETRIES = 30
let MAX_CONCURRENT_UPLOADS = 3
let MAX_BUFFERED_FRAGMENTS = 90

// Web View Process Pool
@MainActor
let WK_PROCESS_POOL = WKProcessPool()

