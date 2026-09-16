# Physical iPhone HLS upload replay

Debug-only diagnostic for separating capture/encoding from upload behavior.
Launch Tubeist with `-hls-upload-replay`; normal camera, audio, settings migration,
purchases and YouTube bootstrap are bypassed. A normal launch is unchanged.

Only run against a specifically authorized test broadcast. Create the matching
unlisted broadcast first, select its HLS key, and verify auto-start, auto-stop,
latency and DVR settings. The diagnostic does not create or complete broadcasts.

Prepare recorded uploads without credentials:

```
PYTHONDONTWRITEBYTECODE=1 python3 Tools/HLSUploadReplay/prepare.py \
  /path/to/captured/session /tmp/HLSReplay --broadcast-id VIDEO_ID
```

Place the primary HTTPS ingestion URL, ending in `file=`, in `endpoint.txt` in
that prepared folder with owner-only permissions. Transfer the folder to
`Documents/HLSReplay` in the installed Debug app container using devicectl.
Keep URLs/keys out of shell arguments and logs. Launch the app with the explicit
flag after confirming the test broadcast. Keep the phone unlocked/foreground;
screen mirroring is unnecessary.

Separate app arguments from devicectl options with `--`:

```
xcrun devicectl device process launch --device DEVICE_ID \
  --terminate-existing --console com.subside.Tubeist -- -hls-upload-replay
```

The runner validates every media hash before network activity and removes the
endpoint file before uploading. It uses the real YouTubeHLSUploader, normal
URLSession timeouts/configuration/retries, fresh filenames, and the original
playlist-request schedule for segment availability. Playlists are regenerated
by the production uploader; media bytes are unchanged. It retains the ten-second
grace from final media acknowledgement to ENDLIST. Complete the broadcast in
Studio after the runner reports success, matching the prior Mac tests.

`Documents/HLSReplay/results_<session>/` contains:

- `uploads.jsonl` and `bodies/`: exact safe request capture and HTTP responses.
- `network.jsonl`: protocol, connection reuse, byte counts and transaction timing.
  No URLs, credentials, headers, server response bodies or IP addresses.

Copy results back without opening the phone screen. Validate the playlist and
media against the original capture, then compare all available replay audio
fragments against the source. The manifest is bounded to 300 segments/ten minutes
and 512 MiB; the explicit launch flag and consumed endpoint prevent unintended
replays. For a new test, supply a newly verified plan/destination. Do not reuse
an ended broadcast. Stop the diagnostic app after the test; normal launch restores
the regular camera UI. Never pass `-ui-testing` on the user's phone because that
mode deliberately resets test settings.

## Bounded live-camera comparison

The separate Debug flag `-hls-live-diagnostic` keeps the normal Tubeist view,
camera/microphone startup, effects, hardware encoders, adaptive bitrate, recording,
segment queue and uploader. It replaces only destination selection and timed
Start/Stop, leaving broadcast creation/completion to the authorized Studio test.
Status polling for the saved key is skipped so it cannot replace test status.

Prepare `Documents/HLSLiveTest/plan.json` with `broadcastID` and `duration`
(10–180 seconds), plus the primary HLS URL in `endpoint.txt`. Verify the unlisted
broadcast and selected key first. The destination is consumed before streaming.
Launch with volatile defaults, which do not replace saved output preferences:

```
xcrun devicectl device process launch --device DEVICE_ID \
  --terminate-existing --console com.subside.Tubeist -- \
  -hls-live-diagnostic -Stream YES -Record YES -RecordHLSAcceptance YES
```

`Documents/HLSLiveTest/result.json` records the session identifier and completion.
The normal diagnostic capture is in `Documents/TubeistDirectHLSAcceptance/SESSION/`;
the MP4 is in Documents. Wait for successful completion before ending the Studio
broadcast and retrieving both. No screen mirroring is needed. Stop the diagnostic
process afterward; normal launch uses the original Settings and camera interface.
