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
- Missing 200 ms of audio/video, duplicate samples and late samples.
- Three-second loss of both tracks, or either track independently.
- A backward capture-clock reset while capture callbacks continue.
- A network outage long enough to overflow the local segment queue.
- An independent watchdog detecting total silence, remaining active across
  encoder recovery, reporting a terminal stall once, and stopping between sessions.

Every uploaded segment and MP4 recording is independently decoded with FFmpeg.
The verifier checks HLG metadata, that uploaded video pixels match the recording,
that healthy/briefly repaired capture loses no frames, and that silence replaces
missing microphone samples without removing surrounding audio. Network overflow
must preserve the complete recording while resuming upload with a small backlog.
Artifacts are retained in the printed temporary directory.

The app allows 200 ms for delayed capture delivery, conceals missing media for up
to two seconds, then waits for both tracks to deliver fresh, increasing timestamps
before restarting the encoders on one shared timeline. Thirty seconds without
recovery is a reported capture failure. Healthy samples retain their timestamps and
original HLG pixel buffers; concealment only supplies missing content. Long recovery
may omit an incomplete live GOP, while retaining its encoded samples in the recording.

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
