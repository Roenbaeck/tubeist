# HEVC colour sampling selection

Debug and Release builds automatically select Main42210 when **Prefer 10-bit
4:2:2 color** is on in Settings, the first camera buffer is 10-bit 4:2:2, and a
hardware encoder can configure and prepare that profile at the chosen
resolution/frame rate. If preparation fails, the failed session is released
before trying Main10 4:2:0. A 4:2:0 source goes directly to Main10. There is no
phone-model allowlist, software encoder, extra encode, or per-frame capability
query.

The setting defaults to on and is read once, when streaming or recording starts.
Turning it off skips the Main42210 attempt entirely, so no hardware session is
created for that profile; the log records `turned off in Settings` at Debug
level. This is the supported way out for an account or playback device that
does not accept 4:2:2, given YouTube's documented 4:2:0 requirement below.

Selection is fixed for the entire stream/recording, including capture recovery,
so the MP4 track cannot unexpectedly change profile. A new session re-evaluates
the camera, the setting, and the hardware. The log reports the chosen sampling
at Info level and any fallback reason at Debug level. Changing the setting while
live has no effect until the next start.

YouTube's
[HDR HLS specification](https://developers.google.com/youtube/v3/live/guides/hls-ingestion#hdr)
still requires 10-bit 4:2:0. The 4:2:2 path is based on the successful live trial
below, not a documented guarantee of YouTube support.

## Offline phone test

Build and install Debug, then launch Tubeist with `-hevc-422-probe` (Xcode scheme
arguments, or `devicectl device process launch ... com.subside.Tubeist -- -hevc-422-probe`).
This launch replaces the normal application view and skips camera/microphone
setup, account access, settings migration, and uploads. It writes to
`Documents/HEVC422Probe/<run UUID>/` without changing saved settings.

The probe uses the production automatic selection, hardware-required encoder,
and decoding-timestamp logic at 1080p30 and 4K60, each with a 4:2:0 source and a
4:2:2 source. It supplies matching 10-bit pixel buffers with HLG/BT.2020 attachments,
encodes three seconds at a 20 Mbps target, forces keyframes at two seconds,
checks that all frames return, and saves elementary HEVC files and a text report.
The report names the selected sampling; the 4:2:2 source should fall back on
hardware that cannot prepare Main42210. The filenames describe the input.

Retrieve the run folder and check each file with:

```sh
ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=profile,width,height,pix_fmt,color_range,color_space,color_transfer,color_primaries,nb_read_frames \
  -of json FILE.hevc
ffmpeg -v error -xerror -i FILE.hevc -f null -
```

Expect `yuv422p10le` when 4:2:2 is selected, `yuv420p10le` otherwise, 90/180
frames respectively, `bt2020nc`, `arib-std-b67`, and `bt2020`. FFprobe calls
the 4:2:2 profile `Rext` (HEVC range extensions). Decode success and actual
chroma format are required; accepting the profile property alone is insufficient.

On 20 September 2026, an iPhone 16 Pro (iOS 27.0) passed all four explicitly
requested profile cases in the original probe. Every
frame decoded without errors and all colour metadata matched. This is a short
synthetic capability check, not sustained performance, battery, live camera,
YouTube, or television playback validation.

## Real stream validation

In a Debug build, enable HLS diagnostics and optionally MP4 recording to verify
the actual camera result, inspect YouTube ingest health, and compare playback
on different devices. Both uploads and optional local MP4 recordings use the
same encoded samples. No other encoder setting, bitrate policy, or transport
policy changes with colour sampling.

### Live result, 20 September 2026

The iPhone 16 Pro live camera trial played successfully on YouTube according to
the tester. The captured first uploaded TS segment independently reports HEVC
`Rext`, `yuv422p10le`, 3840×2160 at 60 fps, limited range, HLG transfer, and
BT.2020 primaries/matrix. This confirms actual 4:2:2 input to YouTube, rather
than inferring it from the experimental setting or the playback rendition.

The matching request capture is complete: 41 media uploads and all 83 media/
playlist requests returned HTTP 200. YouTube advertised 2160p60 HDR playback
renditions in VP9 Profile 2 and 10-bit AV1, plus SDR renditions. This establishes
successful ingest and HDR processing for this trial. It does not establish
gap-free playback by frame comparison, Sony TV compatibility, sustained battery
cost, or general support beyond YouTube's documented 4:2:0 requirement.
