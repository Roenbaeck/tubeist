# Remux fixture validation

`validate_generated_hlg.sh` is a development-only oracle for the pure Swift
fMP4 reader and MPEG-TS muxer. It generates synthetic HEVC Main10 HLG/BT.2020
video and AAC-LC stereo audio with FFmpeg, remuxes three adjacent fragments with
Tubeist code, checks the resulting stream metadata with `ffprobe`, and decodes
the concatenated TS sequence to a null sink.

Run it from any directory:

```sh
Tools/RemuxFixture/validate_generated_hlg.sh
```

It requires a local FFmpeg build with `libx265`. FFmpeg is never linked into or
shipped with Tubeist.

This generated fixture complements, but does not replace, Apple-specific device
fixtures. In a Debug build, enable **Capture fMP4 remux fixtures** under Settings
and run a short recording/stream. Tubeist saves the initialization segment, six
media fragments, and a JSON manifest under
`Documents/TubeistRemuxFixtures/<session-id>`. Use generated imagery/silence when
checking fixtures into the repository; never capture private camera content.
