# Save Highlight

Highlights are off by default. In Settings, turn on **Highlights → Enable Highlights** and tap Save before starting a stream or recording. The choice applies to the next session and stays fixed until it ends.

During an enabled session, tap the lightning/clock button below Start/Stop to save a short MP4 around the current moment. The same action is available in the Live Activity and Apple Watch Smart Stack when those are enabled. The control becomes available after the first encoded fragment arrives. When highlights are disabled, these buttons are hidden.

Tubeist keeps approximately ten seconds of completed fragments before the press and collects approximately five seconds afterward. Selection uses complete keyframe-aligned fragments, so the duration is approximate. Pressing early in a session gives a shorter lead-in. Stopping while a highlight is pending saves the available ending rather than discarding the request.

Clips are named `highlight_<session identifier>.mp4` and saved in Tubeist's Documents folder, alongside local recordings. They are accessible through Files. They are not automatically imported into Photos. The app and Watch show Saving, Saved or Failed feedback; failures also appear as warnings in the log.

## Pipeline and limits

When enabled, the highlight buffer works in Stream Only, Stream and Record, and Record Only. In Stream Only, a passthrough MP4 writer packages already-compressed HEVC/AAC samples in memory, without writing a full recording or running another encoder. This adds packaging work and memory use compared with streaming without highlights; it should be measured on real devices before release.

With highlights disabled, Stream Only does not create this MP4 writer or retain a highlight buffer. Full recording continues normally without retaining extra highlight history.

The recent-fragment ring and each pending clip have a 64 MiB byte limit in addition to the time limit. Only one highlight can be collected or saved at a time, including across rapid Stop/Start cycles. The byte limit can shorten the available history at very high bitrates, or reject a clip that exceeds the limit. Saving and timestamp rebasing run on a separate actor, so disk access does not hold up frame processing or stream shutdown.

Each clip uses the original initialization metadata and compressed samples. Its first video sample must be a keyframe. Both tracks receive one common time shift so the clip has its own timeline, preserving their timing difference, durations, color metadata and compressed payloads. This does not change timestamps or packaging sent to YouTube.

Activity buttons carry their session ID. A request from an old activity cannot capture a newer stream. Highlight requests require an active session while Tubeist is in the foreground; the existing background capture policy remains in effect. A full-recording failure still follows the existing recording error handling, while a highlight-only buffering failure leaves the live output running.

## Validation and device testing

Unit tests cover optional packaging in each output mode, disabled buffering, session-specific controls, history selection, pre/post-roll assembly, Stop with a pending highlight, duplicate and stale requests, unique filenames, file failures, slow storage, timestamp rebasing and Watch feedback. A Settings UI test checks the default-off choice and Save/Cancel behavior. An Apple AVAssetWriter-generated HEVC/AAC fixture was sliced from later in its timeline; FFprobe and FFmpeg verified the resulting clip's shifted timing and successful audio/video decoding.

Before release, test Stream Only and Stream and Record on a physical iPhone, play clips requested well into the session, request one just before Stop, and check paired Watch delivery. Compare CPU, memory and battery use with the current release, especially at 4K60. Simulator tests cannot validate hardware encoding or Watch-to-iPhone delivery.

## Attribution

This feature was contributed by Jan Lindhardsen in [PR #64](https://github.com/Roenbaeck/tubeist/pull/64), commit `284639132c7a965e259a49d3e05b4b999eff478f`. The selective cherry-pick preserves his authorship and adapts the feature to Tubeist's current streaming and Watch implementation.
