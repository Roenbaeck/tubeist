<img src="https://github.com/Roenbaeck/tubeist/blob/8dc94e3895936ae2c1c6d8ac17cb4d7cbd5aedec/Tubeist/Assets.xcassets/AppIcon.appiconset/TubeistIcon.png" alt="Tubeist icon" width="110" height="110">&nbsp;&nbsp;&nbsp;<a href="https://apps.apple.com/us/app/tubeist/id6740208994"><img src="https://github.com/Roenbaeck/tubeist/blob/a706314e3155cb0dbda8ef6c0ac0965b5883a55b/Download_AppStore.svg" alt="Download Tubeist on the App Store"></a>

# Tubeist

Tubeist is a native Swift 6 camera app for recording and streaming HDR video from an iPhone. It sends HEVC Main10 HLG video and AAC audio directly to YouTube over HLS, without an intermediate relay server. When local recording is enabled, the same encoded media is saved as fragmented MP4 while it is remuxed to MPEG-2 TS for streaming—no second video or audio encoder is required.

Tubeist is designed for events, sports, education, performances, and other long-form productions where image quality matters more than conversational latency. Watch [Tubeist demos on YouTube](https://youtube.com/playlist?list=PLFnkPgO2HxdAp_YiFVSWVpyak--0y6m5U&si=b2vjD-jVe0FY2egZ).

![Tubeist camera interface with the Blackbright style, Grain effect, and two web overlays](https://github.com/user-attachments/assets/c48ee5ce-86a9-49a1-b859-8c88c4a341d9)

## Features

- Direct YouTube HLS delivery from the iPhone, with no relay server
- HEVC Main10 HLG video and AAC audio
- Record-only, stream-only, and simultaneous stream-and-record modes
- Fragmented MP4 local recordings using the original encoded media
- Built-in presets from 540p through 4K, subject to the selected camera's capabilities
- Manual focus, exposure, white balance, zoom, stabilization, and camera controls
- Local and external monitoring options
- Live bandwidth, buffer, CPU, battery, and thermal information
- Web overlays for graphics and live information
- Built-in image styles and effects
- Optional Google sign-in for YouTube broadcast discovery and management

## Installation

Tubeist is available on the [App Store](https://apps.apple.com/us/app/tubeist/id6740208994), and public builds are also distributed through [TestFlight](https://testflight.apple.com/join/atDHXHWy).

To build from source:

1. Clone this repository.
2. Open `Tubeist.xcodeproj` in Xcode.
3. Select your development team and a connected iPhone.
4. Build and run.

Tubeist requires iOS 18 or later and a physical iPhone with an HDR-capable capture format. The project has no external framework dependencies.

## Streaming to YouTube

Create a YouTube Live stream configured for **HLS ingestion**, then enter its stream key in Tubeist Settings. An RTMP or RTMPS key is not interchangeable with an HLS key.

Manual-key streaming does not require Google sign-in. Signing in is optional and lets Tubeist discover the matching HLS ingestion resource, display broadcast state, and apply supported metadata and broadcast settings. Opening Settings never creates or modifies a broadcast; changes are sent only when you choose Apply.

See YouTube's official [HLS ingestion guide](https://developers.google.com/youtube/v3/live/guides/hls-ingestion) for help creating a compatible stream.

### Output modes and presets

Tubeist supports:

- local recording without streaming;
- YouTube streaming without a local recording; and
- YouTube streaming with a simultaneous local recording.

Built-in presets cover 540p, 720p, 1080p, 1440p, and 4K at frame rates supported by the selected iPhone camera. Custom presets are limited to formats that the camera reports as HDR-capable. Available combinations depend on the device, selected lens, thermal state, storage, and network capacity.

### Starting and stopping

Before starting, confirm that Tubeist has Camera and Microphone access, the selected camera supports the chosen preset, and the phone has sufficient upload bandwidth and free storage.

Stopping is complete when enabled outputs have finalized. Keep Tubeist open while the control shows the orange stopping state so the recording can close cleanly and the accepted streaming tail can finish uploading.

## Camera interface

Tubeist uses a fixed landscape interface with a central 16:9 preview and a compact control rail. Pinch the preview to zoom, tap to position focus or exposure, and use the rail for camera selection, stabilization, monitoring, styles, focus, exposure, white balance, overlays, and streaming.

The interface displays operational information—including current throughput, upload utilization, buffered media, CPU load, battery level, and thermal state—without covering the primary camera controls.

## Overlays, styles, and effects

Web overlays can add live graphics and information to the encoded output. Tubeist also includes visual styles and effects that can be combined with overlays while recording or streaming. Some styles and effects are available through an in-app purchase.

## iOS behavior

iOS does not permit indefinite camera capture in the background. If Tubeist moves to the background during capture, it stops capture and uses finite background execution time to finalize the local recording and accepted YouTube tail. Keep the app in the foreground for an active stream.

Battery-saving mode can reduce display power use during long sessions while leaving the capture pipeline active.

## Privacy and credentials

Stream keys and authentication credentials are stored using iOS-provided secure storage. Tubeist redacts stream keys, complete ingestion URLs, and OAuth tokens from its diagnostic output. Never include those credentials—or private recordings—in an issue or bug report.

See the [privacy policy](PRIVACY.md) for details about data handling.

## Troubleshooting

If Start is unavailable or a stream fails:

1. Confirm Camera and Microphone access in iOS Settings.
2. Confirm that the stream key belongs to a YouTube stream configured for HLS, not RTMP.
3. Select a preset supported by the current camera and lens.
4. Check upload bandwidth, device temperature, and available storage.
5. Read the persistent in-app error first, then open the journal for additional detail.

After a successful stop, YouTube may need additional time to process the live archive before every quality level is available.

## Development and verification

Tubeist's capture, encoding, remuxing, and delivery pipeline is implemented in Swift and Apple media frameworks. Repository tooling provides deterministic checks for the media and network boundaries:

- [Remux fixture](Tools/RemuxFixture/README.md) validates generated HLG MPEG-2 TS output.
- [YouTube HLS mock](Tools/YouTubeHLSMock/README.md) exercises uploader behavior against loopback HTTPS.
- [Apple fMP4 fixture](Tools/AppleFMP4Fixture/README.md) checks Apple's `mpeg4AppleHLS` box layout.
- [Device fMP4 fixture](Tools/DeviceFMP4Fixture/README.md) validates exported physical-device captures.
- [Media comparison tools](Tools/Acceptance/README.md) produce redacted evidence summaries and scan them for credential canaries.

Continuous integration enforces the YouTube-only source boundary, Swift parsing, property-list validation, unit and UI tests, static analysis, Debug and Release builds, and the offline media validators.

## Contributing

Bug reports, feature proposals, documentation improvements, test results, and pull requests are welcome. For useful bug reports, include reproducible steps, iPhone model, iOS version, selected preset, and redacted screenshots or journal output. Do not include stream keys, complete ingestion URLs, OAuth tokens, or private recordings.

For code changes, fork the repository, create a focused branch, include relevant tests, and open a pull request explaining the behavior and motivation.

Join the [Tubeist Discord server](https://discord.gg/W48k2rSvr8) for discussion and support.

## Acknowledgements

Tubeist was inspired by the work on [Moblin](https://github.com/eerimoq/moblin), another open-source live-streaming application. Tubeist began as a Swift learning project, with significant early development aided by large language models.
