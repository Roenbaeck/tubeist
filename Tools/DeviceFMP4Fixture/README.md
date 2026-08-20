# Physical-device fMP4 validation

In a Debug build, enable **Capture fMP4 remux fixtures** under **YouTube HLS
Development**, then start a stream using generated/test imagery. Tubeist captures
one initialization segment and the next six media fragments, automatically turns
the capture setting off, and writes the set under
`Documents/TubeistRemuxFixtures/<session-id>` for export through the Files app.

Validate an exported directory from the repository root:

```sh
Tools/DeviceFMP4Fixture/validate_capture.sh /path/to/exported/session-directory
```

The validator parses the Apple box layout, remuxes every ordered fragment with
Tubeist's Swift implementation, probes and decodes both the exact fragmented-MP4
recording byte stream and the concatenated MPEG-TS output, and compares audio
sample rate, channel count, and video frame rate. It requires macOS, Xcode
command-line tools, FFmpeg, and FFprobe. Artifacts are written to a unique
temporary directory printed at startup; the stream key is never part of a
capture or artifact.
