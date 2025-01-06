<img src="https://github.com/Roenbaeck/tubeist/blob/8dc94e3895936ae2c1c6d8ac17cb4d7cbd5aedec/Tubeist/Assets.xcassets/AppIcon.appiconset/TubeistIcon.png" alt="Tubeist icon" width="110" height="110">

# Tubeist

Tubeist is an iPhone application for live streaming, leveraging the fMP4 format over the HLS (HTTP Live Streaming) protocol. Built entirely in Swift 6, this project was initially conceived as a learning exercise to explore the Swift language, with significant early development aided by the capabilities of large language models.

The primary goal of Tubeist is to facilitate the streaming of high-fidelity HDR content, particularly targeted for platforms like YouTube. It's designed for scenarios where pristine visual quality is paramount, rather than ultra-low latency interaction. This makes it an ideal choice for streaming events, sporting competitions, educational content, or any other long-running stream where immediate audience interaction is not the primary focus.

![IMG_1727](https://github.com/user-attachments/assets/7d7c5c97-024c-466d-9281-8a8acfd095a5)

## TestFlight
A TestFlight version is publicly available here: https://testflight.apple.com/join/atDHXHWy

## Features (Under Development)

While still under active development, Tubeist aims to provide a robust set of features for high-quality streaming. Key features currently being developed and tested include:

* **High Dynamic Range (HDR) Streaming:** Capture and broadcast video with enhanced color and detail.
* **High Frame Rate Support:** Stream with smoother motion for supported platforms and content.
* **fMP4 over HLS:** Utilizing industry-standard protocols for reliable and scalable streaming.
* **Manual camera controls:** Staying true to common camera controls, made easily accessible.
* **Web Overlay Support:** Integrate dynamic graphics and information into your stream.
* **Bandwidth-Aware Presets:**  Optionally input your available bandwidth to receive recommendations for optimal streaming settings.

**Please note that this project is continuously evolving, and the availability and stability of specific features may vary.**

## Usage

It's important to understand that in its current phase, Tubeist may still contain bugs. However, it is progressively becoming more stable and user-friendly. Using Xcode you can clone this repository and manually compile and install Tubeist on your iPhone. Tubeist also relies on a server infrastructure capable of ingesting fMP4 over HLS.

For testing purposes, a rudimentary stream server is available as a separate project: [https://github.com/Roenbaeck/hls-relay](https://github.com/Roenbaeck/hls-relay). This is an HTTP server that accepts HLS input, which is forwarded to YouTube (or Twitch) using ffmpeg. You will need to configure Tubeist to point to your HLS relay server.

**Detailed usage instructions will be provided as the app matures.**

## Getting Started (For Developers)

If you're interested in contributing to the development of Tubeist, here's a basic guide to get started:

1. **Clone the Repository:** `git clone https://github.com/Roenbaeck/tubeist`
2. **Install Dependencies:**  There are no dependencies to external frameworks.
3. **Build the Project:** Open the `Tubeist.xcodeproj` or `Tubeist.xcworkspace` in Xcode and build the project for your target device.
4. **Run on your iPhone:** Connect your iPhone and run the application from Xcode.

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
