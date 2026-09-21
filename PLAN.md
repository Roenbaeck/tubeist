> The encoding architecture below records the earlier AssetWriter migration.
> The VideoToolbox branch replaces that live path; see [the current design and validation](Tools/VideoToolboxProbe/README.md).
> The auto-stop-only policy below is also historical. The current signed-in Stop
> waits ten seconds after the final media ACK, sends ENDLIST, waits another ten
> seconds after its ACK, then requests completion within the shutdown deadline.
> See [current ending behavior](Tools/Acceptance/README.md). Fixes for replay gaps
> and tail loss remain unverified; earlier successful tests did not establish a
> complete fix.

# Tubeist YouTube-only hardening plan

- Status: repeat-stream and no-litter Settings fixes verified; YouTube-owned auto-stop experiment awaits physical acceptance
- Last reviewed: 2026-08-23
- Baseline: codex/direct-youtube-hls at e82bb7b
- Supersedes: the completed direct-YouTube implementation plan in Git history

## Current verification status

- Settings now uses explicit Cancel/Save draft semantics. Save persists the
  next-stream preferences locally and performs no YouTube mutation; signed-in
  Start reuses an existing `ready` broadcast before it creates and binds one.
  The Save path contains no YouTube API operation, while request-level tests
  prove that Start does not insert or bind when a `ready` event already exists.
- The 2026-08-22 Settings fix passes all 103 unit tests and all 9 UI tests on the
  iPhone 16 Pro iOS 18.2 simulator, plus Swift parsing, property-list and
  YouTube-only source checks, and an unsigned generic-device Release build.
- The 2026-08-22 background/status/Stop-tail follow-up suppresses expected idle
  preview interruptions, preserves the last known YouTube indicator across
  transient status failures, counts split final audio/video callbacks as one
  pending output segment, and publishes a terminal `#EXT-X-ENDLIST` playlist
  only after the last segment is acknowledged. All 105 unit tests, all 9 UI
  tests, all five local HTTPS socket scenarios, Swift parsing, property-list and
  YouTube-only source checks, and the unsigned generic-device Release build
  pass; physical archive-tail proof remains pending.
- The explicit-completion experiment disabled YouTube automatic stop, drained
  and acknowledged the HLS tail, published `#EXT-X-ENDLIST`, waited for ingest
  settlement, and then transitioned the event to `complete`. Physical tests
  still lost approximately six, four, and two seconds under successively longer
  waits, so HTTP and live-stream status are not accepted as archive-tail proof.
- Backgrounding now has a three-second recovery grace period before Stop is
  committed. YouTube status polling pauses immediately to avoid locked-device
  Keychain reads; returning during the grace period preserves the media pipeline
  and same broadcast, while a longer absence proceeds through the normal drained
  Stop path. All 106 unit tests and the unsigned generic-device Release build
  pass; physical interruption/recovery verification remains pending.
- Signed-in Start now explicitly enables YouTube automatic stop for existing
  `ready` events and newly created successors. Tubeist Stop still drains and
  acknowledges all media and `#EXT-X-ENDLIST`, but no longer sends an explicit
  `complete` transition; YouTube owns completion using its internal ingest and
  archive state. Wind-down polling keeps the indicator red until YouTube reports
  a non-live state. The indicator remains monochrome, entirely status-colored,
  and hidden when the user is not signed in. All 106 unit tests, the YouTube-only
  source check, Swift parsing, property-list and diff-hygiene checks, and the
  unsigned generic-device Release build pass; physical archive-tail proof
  remains pending.
- The 2026-08-21 repeat-stream, buffer-continuity, and Stop-tail fixes pass all
  103 unit tests on the iPhone 16 Pro iOS 18.2 simulator, Swift parsing, the
  YouTube-only source check, and an unsigned generic-device Release build.
- Historical queue policy (superseded by the September adaptive delivery update
  documented in `Docs/AdaptiveBitrate.md`): the local jitter queue was distinct from YouTube's
  five-outstanding-segment protocol limit: it absorbed at least sixty seconds of
  two-second fragments before a bounded discontinuity is required, and upload
  retries remain active for up to two minutes. Stop freezes audio at the user's
  action and lets stabilized video reach that timestamp before capture is
  detached. Automated verification passes; physical verification remains
  pending.
- Xcode 26.6 builds the unsigned generic-device Debug and Release configurations,
  and Xcode static analysis passes without findings.
- The complete Swift 6 unit and UI suite passes on an iPhone 17 Pro iOS 26.5
  simulator. Xcode recovered from one parallel UI-runner clone failure and
  returned a successful full run; focused reruns also pass, including essential
  controls at the largest accessibility Dynamic Type category.
- GitHub Actions run
  [32350714076](https://github.com/Roenbaeck/tubeist/actions/runs/32350714076)
  passes on Xcode 16.4: source policy, property-list and Swift parsing checks,
  the serial unit/UI suite, static analysis, generic-device Debug and Release
  builds, the generated HLG transport-stream fixture, and the loopback HTTPS
  uploader harness.
- Focused tests cover structured multi-sink shutdown, one monotonic shutdown
  deadline, background expiration at each representative finalization stage,
  slow/failing recording I/O, final-only durability sync, bounded capture,
  Keychain migration, typed YouTube API status/mutations/refresh/pagination/
  cancellation/concurrency, overlay policy, Journal bounds, and Mach port
  ownership under repeated CPU sampling.
- The YouTube-only source policy, property-list validation, diff hygiene,
  generated HLG remux fixture, and local HTTPS socket scenarios for contract,
  reconnect, timeout, Stop, and cancellation pass.
- An unsigned Release archive was inspected. It contains the expected packaged
  privacy manifest and hardened Info.plist; the Debug-only loopback uploader
  endpoint is absent from Release behavior.
- An iPhone 16 Pro running iOS 26.6 physically confirms the restored compact
  landscape layout and a direct YouTube start/stop smoke test. Physical
  Stop/archive-tail proof, long-duration and preset matrices, Instruments
  budgets, canary scans, saved-settings migration, and TestFlight
  acceptance remain open.

## Outcome

Tubeist will support exactly three output combinations:

1. record locally;
2. stream directly to YouTube over HLS;
3. stream directly to YouTube and record locally.

Stream means YouTube HLS. The checked ISOBMFF reader, HEVC/AAC MPEG-2 TS
muxer, media playlist, and YouTube uploader remain the technical foundation.

This plan defines the supported product surface and addresses the reliability,
performance, security, privacy, UI, and test findings from the
2026-08-19 whole-app audit.

## Product decision

- Use YouTube HLS as the streaming destination throughout code, UI, settings,
  tests, and documentation.
- Configure streaming with a YouTube HLS key and optional Google authorization.
- Use one YouTube uploader for buffering, retries, and delivery metrics.
- Represent output choices as streaming, recording, or both.
- Keep runtime settings limited to supported functionality.
- Support record-only and stream-and-record operation.
- Allow manual YouTube HLS keys without sign-in; sign-in remains optional for
  broadcast management.

## Existing foundation to preserve

- [x] One AVAssetWriter encodes HEVC Main10 HLG and AAC for recording and
  streaming; there is no second direct-stream encoder.
- [x] The ISOBMFF reader rejects malformed and out-of-bounds input.
- [x] The muxer emits independently valid MPEG-2 TS with PAT, PMT, PES, PCR,
  continuity, Annex B HEVC, and ADTS AAC.
- [x] The YouTube uploader has a bounded serial queue, retry classification,
  cancellation, playlist state, and secret redaction.
- [x] Direct-path parser, muxer, playlist, uploader, fixture, malformed-input,
  cancellation, and physical-device tests exist.
- [x] A real 1080p30 session reached YouTube with accepted segments.
- [x] The baseline generic-device Release build succeeds.
- [ ] The latest final-fragment fix still needs a physical Stop/archive-tail test.
- [ ] Long-duration, 60 fps, 4K, interruption, thermal, and TestFlight acceptance
  remain open.

## Target architecture

    camera + microphone
            |
            v
    bounded ordered capture intake
            |
            v
    one AVAssetWriter encode
            |
            +-- original fMP4 --> bounded recording sink --> local MP4
            |
            +-- fMP4 init/media --> ISOBMFF reader --> TS muxer
                                                     |
                                                     v
                                      playlist + YouTube HLS uploader

One coordinator owns the complete session:

    idle -> preparing -> live -> stopping -> idle
               |          |          |
               +----------+----------+-> failed

A session is not idle until every enabled sink has finished or produced a
surfaced failure.

## Non-negotiable invariants

- Encode each camera/audio sample at most once.
- Preserve media order explicitly; do not rely on unstructured task scheduling.
- Bound every queue by count and/or media duration.
- Never silently lose recording bytes, upload media, or the shutdown tail.
- Keep recording viable after a network failure when local I/O is healthy.
- Make Start and Stop serialized and idempotent.
- Use monotonic clocks for deadlines, retries, and measurements.
- Keep stream keys, OAuth tokens, passwords, and key-bearing URLs out of
  UserDefaults, logs, diagnostics, and crash context.
- Accept only HTTPS YouTube ingestion endpoints in production.
- Surface fatal capture, writer, recording, remux, upload, and shutdown errors in
  the UI as well as the journal.
- Keep Debug diagnostics opt-in, bounded, and inexpensive.

## Settings migration

The first build with this work must perform a one-time testable migration:

- Recover TargetData["youtube"] when it contains an existing YouTube key.
- Move the stream key and OAuth access/refresh tokens to Keychain with an
  explicitly selected accessibility class.
- Retain only suitable non-secret YouTube preferences in UserDefaults.
- Delete migrated secret values only after successful Keychain writes.
- Remove obsolete endpoint, credential, and destination preferences after
  preserving the YouTube configuration.
- If no YouTube key exists, disable streaming and show setup; never treat a
  Twitch key as a YouTube key.
- Make migration idempotent and safe if launch is interrupted.
- Test migration with isolated preference and Keychain stores.

## Scope

In scope:

- YouTube-only configuration and settings migration.
- One authoritative stream lifecycle and complete finalization barriers.
- Bounded capture delivery and runtime error propagation.
- Reliable local recording and background finalization.
- Keychain, ATS, privacy manifest, and privacy-policy work.
- YouTube API/OAuth and settings correctness.
- Measured performance improvements.
- Accessibility, broader Swift 6 tests, CI, and release validation.

Out of scope:

- Streaming providers or protocols other than YouTube HLS.
- Multiple renditions, a master playlist, or parallel primary/backup ingest.
- New codecs, captions, or encryption beyond HTTPS.
- Capture after iOS suspends the app.
- Rewriting the validated remuxer without measurements.
- Adding a third-party media framework to the shipping app.

## Implementation phases

Each phase ends with tests and a reviewable commit. Do not combine deletion,
lifecycle changes, and muxer optimization in one change.

### Phase 0 — Baseline and deletion inventory

- [x] Record the complete test baseline, analyzer result, and unsigned Debug and
  Release device builds.
- [x] Capture the existing record/stream output matrix in tests before simplifying
  it.
- [x] Inventory the streaming symbols, settings, tests, build entries, tools,
  and documentation against the supported output modes.
- [x] Add failing tests for the intended settings migration.
- [x] Preserve direct-stream acceptance evidence and fixtures without secrets or
  user media.

Exit gate: the baseline is reproducible, deletion scope is reviewed, and migration
behavior is specified by tests.

### Phase 1 — Make Tubeist YouTube-only

- [x] Centralize buffering, retries, metrics, and HTTP delivery in the YouTube uploader.
- [x] Keep EncodedOutputRouter, Streamer, StreamOutputPlan, and health reporting
  aligned with the supported output modes.
- [x] Represent whether a session streams to YouTube and whether it records locally.
- [x] Keep streaming settings and constants specific to YouTube HLS.
- [x] Implement the one-time settings and Keychain migration.
- [x] Rename direct-only types where Direct no longer distinguishes a second path;
  keep renames mechanical.
- [x] Keep tests, tools, assets, docs, and TODO items aligned with supported functionality.
- [x] Add a repository check enforcing YouTube-only production streaming and
  ingestion hosts.

Exit gate: streaming code and UI use YouTube HLS, saved settings migrate, and
Stream always selects one YouTube sink.

### Phase 2 — One authoritative session lifecycle

- [x] Replace lifecycle Boolean authorities with StreamSessionState: idle,
  preparing, live, stopping, and failed.
- [x] Serialize Start, Stop, restart, interruption, and background commands in one
  coordinator; make repeats idempotent.
- [x] Publish UI state from that coordinator.
- [x] Make startup transactional and roll back every prepared component on error.
- [x] Freeze an immutable configuration for each active session.
- [x] During Stop: close intake, drain accepted samples, finish AVAssetWriter,
  route every final callback, finish recording and upload, then become idle.
- [x] Classify writer callbacks at delegate time, coalesce split final audio and
  video callbacks into one displayed/output segment, and publish a terminal
  playlist after the final segment acknowledgement before closing ingestion.
- [x] For signed-in streaming, explicitly enable YouTube automatic stop during
  Start. After terminal playlist acknowledgement, close ingestion without an
  explicit `complete` transition and poll until YouTube reports the event ended.
- [ ] Physically verify timestamp-aligned Stop: audio freezes at the button press,
  stabilized video catches up to that instant, and the archive includes the
  spoken Stop marker without an unmatched audio-only tail.
- [x] Return a structured shutdown result and never report success after a caught
  sink failure.
- [x] Test double Start/Stop, Stop while preparing, Start while stopping, uploader
  failure during Stop, and rapid stop/restart.

Exit gate: state always reflects reality and a new session cannot discard the
previous session's tail.

### Phase 3 — Bounded capture and runtime failures

- [x] Replace per-sample unstructured video/audio tasks with one ordered bounded
  media-intake abstraction.
- [x] Give video a documented latest-frame/drop policy and audio a small
  timestamp-ordered bound.
- [x] Make AVFoundation late-frame discarding provide actual backpressure.
- [x] Bound startup audio and fail if video never arrives.
- [x] Remove per-preview-frame unstructured main-actor task creation.
- [x] Make capture setup throw typed errors and always commit or roll back
  beginConfiguration.
- [x] Mark the camera ready only after device, format, audio, outputs, and session
  startup succeed.
- [x] Handle interruptions, runtime errors, media-services reset, permissions, and
  device connection changes.
- [x] Treat an idle preview interruption caused by backgrounding as recoverable
  lifecycle state rather than presenting a fatal camera-configuration alert.
- [x] Escalate AVAssetWriter append/status failures to the session coordinator.
- [x] Select cameras by unique ID, refresh hot-plugged devices, and derive frame
  rates from the selected camera.
- [x] Stress slow downstream processing and assert fixed retained-sample bounds
  and ordered timestamps.

Exit gate: overload has bounded memory and documented degradation, and capture or
writer failures become actionable session failures.

### Phase 4 — Recording and background finalization

- [x] Add RecordingActor.finish to await queued writes, close the file, and return
  write/close errors.
- [x] Bound recording work and handle disk-full and file-protection failures.
- [x] Use one tested final durability sync instead of synchronizing every
  fragment; intermediate writes apply backpressure without a per-fragment sync.
- [x] Request finite iOS background time when a live session must finalize.
- [x] Give shutdown a monotonic deadline within that background window.
- [x] Report incomplete finalization instead of claiming a successful Stop.
- [x] Test background expiration at every representative shutdown stage and
  inject slow/failing file I/O.

Exit gate: idle means recording is closed and the accepted YouTube tail finished,
or a specific finalization failure is visible.

### Phase 5 — Secrets, transport, and privacy

- [x] Complete the Keychain credential store and migration.
- [x] Mask the stream key with an explicit temporary reveal control.
- [x] Retain canary tests proving keys and key-bearing URLs cannot escape.
- [x] Remove NSAllowsArbitraryLoads; permit only HTTPS YouTube/API traffic and the
  narrowest exception genuinely required by web overlays.
- [x] Review overlay navigation and document its network behavior.
- [x] Add PrivacyInfo.xcprivacy with approved required-reason declarations.
- [x] Rewrite PRIVACY.md for local processing/recording, YouTube transfer, OAuth,
  overlays, retention, deletion, and account revocation.
- [x] Link privacy and credential-removal instructions from Settings.
- [x] Inspect the packaged privacy manifest and Release Info.plist in an unsigned
  app archive.

Exit gate: no secret remains in preferences or diagnostics, production
credentials cannot travel over HTTP, and shipping privacy metadata is accurate.

### Phase 6 — YouTube API and transactional settings

- [x] Centralize YouTube HTTP handling with typed decoding, validated status
  codes, timeouts, redacted errors, and one controlled authentication refresh.
- [x] Correct OAuth form encoding; add and validate state; retain/cancel the auth
  session; handle secure-random failures.
- [x] Separate read-only broadcast lookup from serialized, idempotent successor
  creation.
- [x] Make signed-in Start preflight the YouTube broadcast: reuse `ready`, create
  and bind a successor after `complete`, and reject active or incomplete states
  before capture or uploads begin.
- [x] Replace the shared isLoading Boolean with operation-aware state.
- [x] Add pagination and idempotent playlist membership.
- [x] Reject thumbnails still over the size limit after compression.
- [x] Edit a settings draft: Cancel discards; Save validates and persists before
  dismissal. Saving remains local-only and cannot create a YouTube event.
- [x] Keep manual-key streaming clearly independent from optional sign-in.
- [x] Mock every API mutation, status, retry, page, cancellation, and concurrency
  case.

Exit gate: each YouTube operation validates server state or returns a typed error,
and Settings Save/Cancel behavior is truthful.

### Phase 7 — Performance and diagnostics

- [x] Fix SystemMetrics Mach allocation ownership and prove repeated sampling
  releases thread send rights.
- [x] Replace the 25 Hz audio-meter task fan-out with one cancellable loop and
  coalesced display updates.
- [x] Bound Journal ordering/storage and batch UI publication.
- [x] Make acceptance recording opt-in and append/batch bounded output instead of
  rewriting the full report per segment.
- [x] Verify ordered upload, bounded local backlog and discontinuity after overflow.
  The September adaptive delivery policy replaces the old 60-second continuity
  allowance with a ten-second waiting-media limit; see `Docs/AdaptiveBitrate.md`.
- [x] Fix deterministic overlay order, clearing the last overlay, transparent
  bounds, and main-actor UIKit/WebKit isolation.
- [ ] Profile stream-only and stream-and-record with Instruments before changing
  the muxer.
- [ ] Only if measured: reduce sample, Annex-B, PES, and per-TS-packet copies with
  ranged writes into a preallocated buffer.
- [ ] Establish memory, CPU, energy, dropped-frame, queue, and thermal budgets for
  1080p30, 1080p60, and supported 4K modes.

Exit gate: a one-hour session has bounded memory/diagnostics and meets agreed
budgets; each optimization has before/after traces.

### Phase 8 — Errors, accessibility, and UI consistency

- [x] Present persistent actionable errors; the journal is supporting detail, not
  the only notification.
- [x] Use in-app foreground alerts; request notification permission only for a
  defined background use.
- [x] Add labels, values, and hints to icon-only controls.
- [x] Restore the proven 30-point compact landscape rail after 44-point targets
  caused the preview and controls to overflow; retain labels, hints, and Dynamic
  Type coverage.
- [ ] Redesign the dense camera rail before claiming recommended 44-point target
  sizes without sacrificing simultaneous access to its ten controls.
- [x] Never communicate health only by color or an unlabeled symbol.
- [x] Unify stream, YouTube, recording, queue, and finalization status.
- [x] Add simulator UI tests for manual-key Save/Cancel, visible validation
  errors, settings persistence, launch, accessible primary-control names, and
  essential controls at the largest accessibility Dynamic Type category.
- [ ] Complete device UI acceptance for Google sign-in, record, stream, Stop,
  finalization, migration, VoiceOver, large text, and contrast.

Exit gate: essential flows work without reading logs and pass VoiceOver,
large-text, contrast, and hit-target checks.

### Phase 9 — Tests, CI, docs, and Release configuration

- [x] Move test targets to Swift 6 with concurrency checking aligned to the app.
- [x] Add tests for session state, capture bounds, recording barriers, background
  deadlines, migration/Keychain, YouTube HTTP, overlays, Journal, and metrics.
- [x] Retain all parser/muxer/uploader fixture and malformed-input suites.
- [x] Add CI for tests, mock HTTP validation, static analysis, and unsigned
  generic-device Debug/Release builds.
- [x] Keep FFmpeg and HTTPS mock tools development-only and reproducible.
- [x] Rewrite README and troubleshooting for a YouTube-only product.
- [x] Document supported presets, HLS key requirements, manual versus signed-in
  use, recording, and iOS limitations.
- [x] Remove the obsolete Debug-only direct-stream flag; YouTube HLS is the only
  streaming destination and is available in both Debug and Release builds.

Exit gate: a clean checkout is continuously verifiable and Release contains no
legacy behavior or accidental development-only gate.

### Phase 10 — Device, YouTube, and TestFlight acceptance

- [x] Add secret-safe tooling that validates bounded Debug acceptance reports
  and scans exported containers and diagnostics for a canary without printing it.
- [x] Add redacted FFprobe evidence tooling for accepted-tail duration, recording
  and archive A/V skew, HLG metadata, resolution, frame rate, and audio channels.
- [x] Configure HEVC output to prohibit open GOPs so every sync sample begins an
  independently decodable group; retain physical-output verification below.
- [x] On 2026-08-20, verify on iPhone 16 Pro with iOS 26.6 that the restored
  compact landscape UI keeps the preview and controls on-screen and that a
  direct YouTube stream can start, appear on YouTube, and stop cleanly.
- [ ] On a signed-in device, open and save Settings repeatedly before streaming;
  verify that no additional upcoming YouTube events are created.
- [ ] On a signed-in device, start, stop, wait for `complete`, then start again
  without opening Settings; verify Tubeist creates a new `ready` broadcast and
  that the second broadcast appears live on YouTube.
- [ ] Test stream-only and stream-and-record at 1080p30, 1080p60, and a supported
  4K preset, covering mono/stereo where applicable.
- [ ] Run a 60-minute session and a longer soak for drift, memory, thermal, and
  queue stability.
- [ ] Confirm YouTube health, archive A/V sync, resolution/frame rate, HEVC
  Main10, HLG/BT.2020, and closed GOPs.
- [ ] Compare capture, YouTube archive, and recording durations; explicitly prove
  Stop preserves the buffered tail.
- [ ] Exercise rapid controls, backgrounding, interruptions, route changes,
  media-services reset, low storage, network loss, timeout, 5xx, authentication
  failure, and thermal pressure.
- [ ] On device, recover from short network interruptions without an archive gap;
  exceed the ten-second waiting-media limit and verify bounded, visibly degraded
  behavior with a correctly signaled discontinuity and complete local recording.
- [ ] Verify budgets with acceptance diagnostics disabled.
- [ ] Scan logs, preferences, app container, and crash context for a canary key.
- [ ] Repeat the core matrix in TestFlight, including saved-settings migration.
- [ ] Record device/iOS versions, results, and accepted limitations.

Exit gate: all release criteria pass in a Release-equivalent build and no P1 issue
can truncate, corrupt, expose, or indefinitely delay a stream.

## Regression matrix

| Mode | fMP4 recording | TS remux | YouTube upload |
| --- | ---: | ---: | ---: |
| Idle preview | no | no | no |
| Record only | yes | no | no |
| YouTube stream only | no | yes | yes |
| YouTube stream + record | yes | yes | yes |

Test every mode through success, startup rollback, runtime failure, backgrounding,
and immediate restart. Settings changes affect only the next session.

## Failure and backpressure policy

- Capture overload: enforce the tested media policy and report degradation.
- Parser/muxer error: stop upload; never send bytes of unknown validity; finish
  healthy recording.
- Permanent YouTube error: stop retries, preserve recording, show a redacted
  actionable error.
- Transient network/5xx: retry identical names and bytes with bounded backoff.
- Upload bound: remain within count/duration limits; if a segment must be lost,
  declare discontinuity and degraded health instead of growing memory.
- Recording error: report invalid recording and allow upload to continue if safe.
- Capture/writer error: close intake and bound finalization of accepted media.
- Shutdown deadline: cancel unfinished work, clear stale session state, and name
  the sink that failed to finish.

## Release criteria

- [x] Production streaming uses YouTube HLS ingestion exclusively.
- [ ] Existing YouTube users migrate without re-entry; secrets exist only in
  Keychain and never appear in diagnostics.
- [x] Session lifecycle and every media queue are ordered and bounded.
- [ ] Stop/background either preserve the accepted tail or report exact failure.
- [ ] A 60-minute device stream passes health, A/V/HDR, memory, CPU, energy,
  thermal, and archive-duration checks.
- [ ] Stream-and-record produces a playable MP4 without truncating YouTube.
- [x] ATS, privacy manifest/policy, and archived Release metadata are accurate.
- [x] Swift 6 tests, fixtures, mock HTTP, analyzer, CI, and clean Debug/Release
  builds pass.
- [ ] Essential flows pass accessibility and visible-error tests.
- [x] Direct YouTube streaming is enabled in Release because it is the sole
  streaming path; the remaining criteria still govern distribution readiness.

## Commit sequence

1. Baseline tests and migration contract.
2. YouTube-only configuration and settings migration.
3. Session coordinator and shutdown barriers.
4. Bounded capture and runtime errors.
5. Recording/background finalization.
6. Keychain, ATS, and privacy.
7. YouTube API and settings cleanup.
8. Measured performance and diagnostics cleanup.
9. Accessibility, CI, tests, and docs.
10. Physical evidence and Release enablement.

Preserve validated remuxer behavior unless a focused test and device measurement
justify a change.

## Deferred camera and audio improvements

Saved for later on 2026-09-19. These are optional follow-up features, outside the
current release criteria. Prioritize the first three, then evaluate subject
tracking. Gate each feature on the active device, route, and format capabilities.

- [ ] Add explicit wind-noise control for supported built-in microphones
  (iOS 18+). Inspect the framework's current setting, expose a toggle, and compare
  outdoor speech and ambient sound with reduction on and off.
  [Apple API](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/iswindnoiseremovalenabled)
- [ ] Enable high-quality AirPods recording on iOS 26+, retaining HFP fallback.
  Verify selection, reconnect behavior, audio quality, and A/V synchronization.
  [Apple overview](https://developer.apple.com/videos/play/wwdc2025/251/)
- [ ] Add a discreet lens-smudge warning on supported iOS 26+ cameras. Initially
  run detection once after camera startup and check false positives and startup
  cost before considering periodic checks.
  [Apple API](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setcameralenssmudgedetectionenabled(_:detectioninterval:))
- [ ] Expose supported microphone processing modes through the system UI,
  including the iOS 26 input picker, and display the active mode. Preserve the
  existing saved input selection and leave Voice Isolation optional for music,
  crowd sound, and performances.
  [Apple overview](https://developer.apple.com/documentation/avfoundation/system-video-effects-and-microphone-modes)
- [ ] Add optional tap-to-track autofocus on supported iOS 27+ formats. Subscribe
  to tracking metadata, indicate acquired/lost tracking, and preserve manual
  focus and the existing single-focus behavior.
  [Apple API](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscontinuousautofocustrackingenabled)
- [ ] Evaluate iOS 27 low-light video noise reduction. First confirm support for
  Tubeist's HDR video-data output, then measure detail, motion quality, power,
  and thermal behavior before choosing defaults.
  [Apple API](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/automaticallyenableslowlightvideonoisereduction)
- [ ] Evaluate optional Center Stage framing for front-camera presenters on
  compatible iPhones, preserving fixed stream dimensions and correct orientation.
  [Apple walkthrough](https://developer.apple.com/videos/play/wwdc2026/341/)

Spatial audio and Cinematic capture remain lower priority because they require
more changes to capture and recording. Low-latency stabilization is already
exposed in Tubeist.
