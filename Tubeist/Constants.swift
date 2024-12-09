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

let TIMESCALE: Int = 60000 // something divisible with FRAMERATE

let STREAMING_QUEUE = DispatchQueue(label: "com.subside.StreamingQueue", qos: .userInitiated, attributes: .concurrent)
let FRAGMENT_CM_TIME = CMTimeMake(value: Int64(FRAGMENT_DURATION * TIMESCALE), timescale: Int32(TIMESCALE))

let AUDIO_BARS = 20

