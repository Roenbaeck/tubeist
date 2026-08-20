<img src="https://github.com/Roenbaeck/tubeist/blob/8dc94e3895936ae2c1c6d8ac17cb4d7cbd5aedec/Tubeist/Assets.xcassets/AppIcon.appiconset/TubeistIcon.png" alt="Tubeist icon" width="110" height="110">&nbsp;&nbsp;&nbsp;<a href="https://apps.apple.com/us/app/tubeist/id6740208994"><img src="https://github.com/Roenbaeck/tubeist/blob/a706314e3155cb0dbda8ef6c0ac0965b5883a55b/Download_AppStore.svg"/></a>

# Tubeist

Tubeist is a Swift 6 iPhone application for recording locally and streaming HDR video directly to YouTube over HLS. It encodes HEVC Main10 HLG and AAC once, writes the original fragmented MP4 when recording is enabled, and remuxes that encoded media to MPEG-2 TS for YouTube without running a second encoder. The project was initially conceived as a Swift learning exercise, with significant early development aided by large language models.

The primary goal of Tubeist is to facilitate the streaming of high-fidelity HDR content, particularly targeted for platforms like YouTube. It's designed for scenarios where pristine visual quality is paramount, rather than ultra-low latency interaction. This makes it an ideal choice for streaming events, sporting competitions, educational content, or any other long-running stream where immediate audience interaction is not the primary focus. You can watch some [demos of Tubeist on YouTube](https://youtube.com/playlist?list=PLFnkPgO2HxdAp_YiFVSWVpyak--0y6m5U&si=b2vjD-jVe0FY2egZ).

![IMG_1816](https://github.com/user-attachments/assets/c48ee5ce-86a9-49a1-b859-8c88c4a341d9)
User interface, showing the "Blackbright" style with "Grain" effect, together with two web overlays.

## TestFlight
A TestFlight version is publicly available here: https://testflight.apple.com/join/atDHXHWy

## Features (Under Development)

While still under active development, Tubeist aims to provide a robust set of features for high-quality streaming. Key features currently being developed and tested include:

* **High Dynamic Range (HDR) Streaming:** Capture and broadcast video with enhanced color and detail.
* **High Frame Rate Support:** Stream with smoother motion for supported platforms and content.
* **YouTube HLS:** Remux the encoded fMP4 output to MPEG-2 TS and upload it directly to YouTube.
* **Local Recording:** Save the original fragmented MP4 while streaming, or record without streaming.
* **Manual camera controls:** Staying true to common camera controls, made easily accessible.
* **Web Overlay Support:** Integrate dynamic graphics and information into your stream.
* **Bandwidth-Aware Presets:**  Optionally input your available bandwidth to receive recommendations for optimal streaming settings.
* **Styling and Effects:** A number of styles and effects are available through an In-App purchase (kept at the lowest price possible).

**Please note that this project is continuously evolving, and the availability and stability of specific features may vary.**

## Usage

Tubeist remains under active development. Clone the repository and install it on
a supported iPhone with Xcode. To stream, create a YouTube Live stream configured
for HLS ingestion and enter its stream key in Tubeist Settings. You may sign in
with Google to manage the matching broadcast from Tubeist, but sign-in is not
required for manual-key streaming.

### YouTube HLS

Tubeist remuxes its existing HEVC Main10 HLG and AAC output to MPEG-2 TS on the
phone. It does not start a second video or audio encoder and does not require an
intermediate server.

Direct delivery requires a YouTube stream configured for the **HLS** ingestion
type. An RTMP/RTMPS key is not interchangeable. When Tubeist is signed in to
YouTube it validates the matching stream resource and uses the primary HLS
ingestion address returned by the API. Without sign-in it uses YouTube's
documented primary manual-key template. Stream keys and complete ingestion URLs
must never be included in logs or bug reports.

The feature remains Debug-only until the physical-device, long-stream, and real
YouTube acceptance gates in [PLAN.md](PLAN.md) have passed. See YouTube's official
[HLS ingestion guide](https://developers.google.com/youtube/v3/live/guides/hls-ingestion)
for creating a compatible stream key.

### Supported output modes and presets

Tubeist supports record-only, YouTube stream-only, and simultaneous YouTube
streaming plus local recording. Built-in presets cover 540p, 720p, 1080p,
1440p, and 4K at frame rates supported by the selected iPhone camera; custom
presets are restricted to formats the selected camera reports as HDR-capable.
The 1080p30 path has real YouTube acceptance evidence. The 60 fps, 4K,
long-duration, interruption, and TestFlight matrices remain release gates in
[PLAN.md](PLAN.md), not implied guarantees.

Manual-key streaming sends directly to YouTube and does not require Google
sign-in. Optional sign-in is only for discovering the HLS ingestion resource,
viewing broadcast state, and applying title, visibility, DVR, latency,
thumbnail, and playlist changes. Opening Settings does not create or modify a
YouTube broadcast; mutations happen only after Apply.

### iOS behavior and troubleshooting

Tubeist requires iOS 18 and a physical iPhone with an HDR-capable capture
format. iOS does not permit indefinite camera capture in the background, so
backgrounding Tubeist stops capture and uses finite background time to finalize
the MP4 and accepted YouTube tail. Keep the app in the foreground for an active
stream.

If Start is unavailable or fails:

1. confirm Camera and Microphone access in iOS Settings;
2. confirm the key belongs to a YouTube stream configured for HLS, not RTMP;
3. select a preset supported by the currently selected camera;
4. verify at least 1 Mbps measured upload bandwidth and sufficient free storage;
5. read the persistent in-app error first, then use the journal for detail.

Stop is complete only after enabled outputs finalize. Do not force-quit the app
while the control shows the orange stopping state. Stream keys, complete
ingestion URLs, OAuth tokens, and user recordings must not be attached to bug
reports.

## Getting Started (For Developers)

If you're interested in contributing to the development of Tubeist, here's a basic guide to get started:

1. **Clone the Repository:** `git clone https://github.com/Roenbaeck/tubeist`
2. **Install Dependencies:**  There are no dependencies to external frameworks.
3. **Build the Project:** Open the `Tubeist.xcodeproj` or `Tubeist.xcworkspace` in Xcode and build the project for your target device.
4. **Run on your iPhone:** Connect your iPhone and run the application from Xcode.

The pure Swift remuxer also has a generated offline conformance check; see
[`Tools/RemuxFixture/README.md`](Tools/RemuxFixture/README.md).
The direct uploader's real `URLSession` behavior has a loopback HTTPS validator;
see [`Tools/YouTubeHLSMock/README.md`](Tools/YouTubeHLSMock/README.md).
Apple's host-side `mpeg4AppleHLS` box layout is covered separately; see
[`Tools/AppleFMP4Fixture/README.md`](Tools/AppleFMP4Fixture/README.md).
Exported physical-iPhone fixture sets can be checked with
[`Tools/DeviceFMP4Fixture/README.md`](Tools/DeviceFMP4Fixture/README.md).
CI also enforces the YouTube-only source boundary, Swift parsing, property-list
validation, tests, static analysis, generic-device Debug/Release builds, and the
offline media validators.

**Ensure you have a valid development certificate and provisioning profile configured in Xcode.**

## Discord
Join the official Discord server to connect with the developer and other users, discuss features, and get support: 
https://discord.gg/W48k2rSvr8

**For reporting issues or suggesting improvements, it's highly recommended to create a detailed issue directly here on GitHub. Even better, if you have a solution, consider submitting a pull request!**

## Contributing

We welcome contributions to Tubeist! If you're interested in helping make Tubeist better, there are several ways you can contribute:

* Reporting Bugs: If you encounter any issues or unexpected behavior while using the app, please create a detailed issue on GitHub. Be sure to include steps to reproduce the bug, your device information, and any relevant screenshots or logs.
* Suggesting Enhancements: Do you have an idea for a new feature or improvement? Feel free to open an issue on GitHub to discuss your suggestion.
* Submitting Code Changes (Pull Requests): If you've fixed a bug or implemented a new feature, we encourage you to submit a pull request. Please ensure your code follows the project's coding style (if defined) and includes relevant tests.
* Improving Documentation: Help make Tubeist more accessible by improving the documentation. This could include clarifying existing documentation, adding new examples, or creating tutorials.
* Testing: As the app moves towards a TestFlight release, providing feedback and thorough testing on new builds will be invaluable.

### How to Contribute Code

* Fork the Repository: Create your own fork of the Tubeist repository on GitHub.
* Create a Branch: Create a new branch in your fork for your changes. It's good practice to name your branch descriptively (e.g., fix-login-bug or add-new-overlay-feature).
* Make Your Changes: Implement your bug fix or new feature.
* Commit Your Changes: Commit your changes with clear and concise commit messages.
* Push to Your Fork: Push your branch to your forked repository.
* Submit a Pull Request: Create a pull request from your branch to the main Tubeist repository. Describe the changes you've made and why they are necessary.

## Acknowledgements
Tubeist was inspired by the amazing work put into [Moblin](https://github.com/eerimoq/moblin), another Open Source live streaming software. 
