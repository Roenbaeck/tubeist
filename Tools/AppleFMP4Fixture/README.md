# Apple segmented-fMP4 validation

`validate_apple_writer.sh` creates synthetic HEVC Main10 HLG/BT.2020 and AAC-LC
source media and passes both encoded tracks through an `AVAssetReader` and an
`AVAssetWriter` configured for `mpeg4AppleHLS` with one-second fragments. The
macOS command-line environment cannot encode AAC through `AVAssetWriter`, so
this host oracle deliberately tests Apple's combined initialization and media-
fragment layout without claiming to reproduce the iPhone encoder. Because the
host writer also disallows automatic intervals with two passthrough tracks, the
tool calls `flushSegment()` at source keyframes. It then
remuxes three adjacent Apple fragments with Tubeist and validates/decode-checks
the resulting TS stream with FFmpeg. It also presents the initialization and all
media fragments as the exact concatenated byte stream written by
`RecordingActor`, then probes and decodes that fragmented MP4 independently.

The script covers 30 fps stereo and 60 fps mono variants:

```sh
Tools/AppleFMP4Fixture/validate_apple_writer.sh
```

It requires macOS, Xcode command-line tools, and an FFmpeg build with `libx265`.
All generated media is synthetic and stored in a unique temporary directory.
This host-side Apple fixture does not replace the physical-iPhone capture matrix
in `PLAN.md`, but it catches Apple box-layout differences that FFmpeg-generated
fMP4 cannot. Each variant also records `apple_box_layout.json`, including
`tfhd`/`tfdt`/`trun` versions and flags, plus `remuxed_ffprobe.txt` with the
expected transport-stream metadata and `recording_ffprobe.txt` with the expected
local-recording metadata.
