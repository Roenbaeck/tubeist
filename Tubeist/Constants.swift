//
//  Constants.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-11-26.
//

import Foundation
import CoreMedia

let FRAMERATE: Int = 30

let CAPTURE_WIDTH: Int = 3840
let CAPTURE_HEIGHT: Int = 2160

let COMPRESSED_WIDTH: Int = 1920
let COMPRESSED_HEIGHT: Int = 1080
let FRAGMENT_DURATION: Int = 2 // seconds
let FRAGMENT_MINIMUM_DURATION: Double = 0.010 // at least 10ms (to ignore very short fragments at the end of the stream)

let TIMESCALE: Int = 60000 // something divisible with FRAMERATE

let STREAMING_QUEUE_CONCURRENT = DispatchQueue(label: "com.subside.StreamingQueueConcurrent", qos: .userInitiated, attributes: .concurrent)

let FRAGMENT_CM_TIME = CMTimeMake(value: Int64(FRAGMENT_DURATION * TIMESCALE), timescale: Int32(TIMESCALE))

let AUDIO_BARS: Int = 50
let ZOOM_LIMIT = 20.0

let DEFAULT_CAMERA = "Back Camera" // available on most (all?) devices
