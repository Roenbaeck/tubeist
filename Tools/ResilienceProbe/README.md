# Capture and network resilience validation

Run `zsh Tools/ResilienceProbe/validate.sh` on a Mac with Xcode, hardware HEVC
encoding, FFmpeg and Python 3. It uses generated 10-bit BT.2020 HLG camera frames
and 48 kHz PCM audio. No camera, phone, credentials or internet connection is used.

The executable compiles the production live pipeline, HEVC/AAC encoders, segment
assembler, MPEG-TS muxer, recording writer, upload queue, uploader and playlist.
Only application services and HTTP transport are replaced. A controllable clock
makes capture faults deterministic; recording and encoding use the real frameworks.

The scenarios cover:

- Normal capture and local recording.
- Audio beginning before the first video frame, requiring a partial PCM block
  to be trimmed without relying on sample-size metadata.
- Missing 200 ms of audio/video, duplicate samples and late samples.
- Sustained frame coalescing under processing pressure, without manufacturing
  duplicate catch-up work or interrupting healthy audio.
- Three-second loss of both tracks, or either track independently, with mono
  and stereo recording coverage.
- A 27-second loss followed by recovery, exercising bounded recording padding.
- A backward capture-clock reset while capture callbacks continue.
- Repeated stabilization changes, including video arriving 1.2 seconds behind
  audio and then switching to a shorter delay on the same stream.
- Startup and recovery with only 16 capture-owned audio buffers available;
  holding the originals must not starve the simulated microphone.
- A network outage long enough to overflow the local segment queue.
- An independent watchdog detecting total silence, remaining active across
  encoder recovery, reporting a terminal stall once, and stopping between sessions.

Every uploaded segment and MP4 recording is independently decoded with FFmpeg.
The verifier checks HLG metadata, that uploaded video pixels match the recording,
that healthy/briefly repaired capture loses no frames, and that silence replaces
missing microphone samples without removing surrounding audio. Recovered segments
must start with aligned audio even when stabilization delays video delivery. Network overflow
must preserve the complete recording while resuming upload with a small backlog.
Every uploaded AAC payload must also be present unchanged in the MP4, with its
timestamp agreeing with the shared video/transport clock to within one AAC packet.
This check rejects recordings that decode correctly but collapse recovery gaps.
Artifacts are retained in the printed temporary directory.

The app allows 200 ms for delayed capture delivery, conceals missing media for up
to two seconds, then waits for both tracks to deliver fresh, increasing timestamps
before restarting the encoders on one shared timeline. Thirty seconds without
recovery is a reported capture failure. Healthy samples retain their timestamps and
original HLG pixel buffers; concealment only supplies missing content. Long recovery
may omit an incomplete live GOP, while retaining its encoded samples in the recording.

Video processing and encoding overlap through a bounded latest-frame queue. Short
timestamp skips during ongoing delivery retain their real timing instead of adding
encoding work to an already busy pipeline. Actual delivery pauses can be concealed,
but each batch has a one-frame-time work budget so it cannot monopolize microphone
processing. A single hardware encoder call may itself exceed that budget.

Recovery retains up to five seconds of audio (at most 512 buffers) to match fresh
stabilized video with its original audio timestamps. It does not require the latest
audio and video callbacks to describe the same instant, and does not shift audio
independently of video. Startup and recovery history own independent PCM copies,
releasing scarce capture-pool storage promptly; normal encoding does not use this
extra copy. The pool fixture tracks release of the original byte storage, so a
shallow sample-buffer copy cannot pass. Run a selected scenario with, for example,
`zsh Tools/ResilienceProbe/validate.sh stabilization-changes`.

The live upload path retries transient failures until stopped, including HTTP 408
and 429. Permanent HTTP errors still fail visibly. Retry filenames and media bytes
remain fixed until acknowledged. Once the local queue exceeds 30 segments or 60
seconds, old complete segments are discarded and the queue is reduced toward six
seconds of media. This limit is a local latency policy, not a promise about YouTube's
playback buffer. HLS and MPEG-TS discontinuity signaling accompanies any skipped media.

Simulator unit tests separately cover timestamp arithmetic and clock drift,
playlist discontinuity history, immutable target duration, bounded segment ordering,
retry exhaustion/recovery/cancellation, and transport-stream payload preservation.
Actual YouTube playback and phone capture interruptions remain device acceptance checks.

## Recording audio across recovery

AVAssetWriter's compressed AAC passthrough path does not preserve empty audio
intervals merely from the resumed packet timestamps. Recording fills these
missing intervals with encoded silence, without decoding or re-encoding captured
audio/video. A silent AAC-LC packet is generated and cached only when first
needed for a format. Both mono and stereo use their own matching packet.

The writer tracks elapsed packet duration from the first audio timestamp and
pads toward the next real timestamp. This carries fractional-packet rounding
across recoveries rather than accumulating a new error each time. Rounding is
bounded by half a packet (about 11.6 ms at 44.1 kHz), plus container time-base
quantization. A simulator test covers 1,000 fractional-packet recoveries.
Padding is generated lazily with a limit of 64 packets per drain call, reuses
compressed bytes, and respects writer backpressure. It cannot enqueue seconds
of PCM or run an encoder continuously. The YouTube path receives the original
encoded samples and retains its existing discontinuity handling.

The verifier checks packet payloads and timing in every media scenario, and
also decodes the middle of a long recording gap to ensure that it is silence.
The original three-second-stall recording fails this check by about 1.29 seconds;
the fixed recording is within 11.1 ms in the same fixture. Repeated stabilization
changes measured a maximum error of 6.94 ms, and the 27-second interruption
measured 2.72 ms. All fifteen scenarios pass, alongside twelve focused simulator
tests and the iOS Release build. Physical-phone/YouTube acceptance
remains separate from these real-framework offline checks.
