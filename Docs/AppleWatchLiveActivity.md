# Apple Watch and Live Activity

Tubeist provides an iPhone ActivityKit Live Activity, mirrored by the system to the Apple Watch Smart Stack on watchOS 11 or later. A separate watchOS app or push server is not required. The iPhone deployment target remains iOS 18.

The contribution in `tubeist-watch-live-activity.zip` (base `5e2d440`) inspired this implementation. Its old app files and independent YouTube health poller were not imported.

## Behavior

Settings → Apple Watch and Live Activity offers Off, Standard and Full. Standard shows the session phase, elapsed time and health. Full also shows the current adaptive encoder bitrate target, viewer count when YouTube provides it, iPhone battery/temperature and upload status on the Watch. The bitrate is not a measurement of available network bandwidth. Recording-only sessions say Recording. Missing data is left unavailable rather than displayed as zero or healthy.

The timer starts when capture goes live and freezes at Stop. Finishing remains visible during drain and YouTube completion. The final Ended/Stopped state is retained briefly, with the elapsed time frozen. Starting a new session removes previous activities. Dismissing an activity suppresses it for the rest of that session. iOS may still choose when and where to present a Live Activity.

Alerts are off by default. Notification authorization is requested only when the user enables alerts in Settings. Remote problems require two distinct fresh health observations at least ten seconds apart. Initial noData is not treated as failed delivery. Persistent local upload failure and terminal session failures can also alert. Healthy recovery alerts are separately optional. There are no loss-of-data alerts during intentional finalization.

Ordinary notification fallback respects notification settings and Focus. While iPhone is unlocked, that fallback normally appears on iPhone. Actual Live Activity alert delivery and Watch haptics must be verified on paired hardware.

## Resource use and isolation

The activity reads the same session health monitor used by the main UI. It never scans streams, polls ingest health independently, touches video encoding, or requests an adaptive bitrate recommendation. The optional Full-mode viewer query uses the stream's pinned account and broadcast ID, at most once per minute while streaming in the foreground, with failure backoff. Viewer counts expire after two minutes. No viewer queries are made during finalization, while backgrounded, or in Standard/Off mode.

A five-second evaluation timer runs only during an active session with the feature enabled. Changes are throttled and unchanged content only refreshes once per minute. The system draws elapsed time without per-second app updates. ActivityKit's stale state is rendered as unavailable, including after app suspension or termination. Apple budgets Watch synchronization, so five-second evaluations do not guarantee five-second Watch refreshes.

Cancellation and replacement are serialized around ActivityKit calls. Late viewer requests are discarded after cancellation. Current background capture suspension and YouTube completion policies are unchanged.

## Development and simulator testing

Use the `StreamLiveActivity` Xcode previews and select the Smart Stack variant. The shared views also contain a stale-state preview. Build and run Debug with `-live-activity-demo` to inspect the same Watch view and create a real Live Activity without using the camera or contacting YouTube. Controls cover healthy/problem/finishing/ended states and an explicitly requested test alert. Demo content is labeled Demo. This launch route is excluded from Release/TestFlight.

Unit tests cover observation-based alert decisions, stale data, session identity, recording-only labeling, optional viewer decoding and pinned-account requests, and teardown while an update is in flight. Production integration is tested with the normal unit/UI suites.

Validation on 2026-09-21: the full run passed 392 unit tests and 17 existing UI tests. The iOS 18.2 compatibility run passed 107 selected tests. After final refinements, all 21 Live Activity policy/session/coordinator tests and the new compact-layout UI test passed. A real ActivityKit activity was created in the iOS 18.2 simulator; the compact layout was visually checked. The unsigned Release device build passed with the extension embedded and matching version/build values. Paired physical Watch synchronization and alert delivery have not yet been tested.

## TestFlight acceptance on a physical Watch

1. Pair an Apple Watch on watchOS 11+ with an iPhone running Tubeist. Allow Tubeist Live Activities in iPhone Settings and relevant Live Activity/Smart Stack settings on the Watch.
2. Start a stream with Standard. Keep Tubeist foreground and iPhone unlocked. Check Smart Stack status, elapsed time and agreement with the phone.
3. Repeat with Full. Check bitrate, viewers (YouTube may omit this), battery, thermal and upload status. Check small Watch sizes and Always On Display.
4. Enable problem/recovery alerts explicitly. Verify delivery while the phone stays awake, with the wrist raised/lowered, and with notification/Focus settings varied. Do not assume an ActivityKit update guarantees a haptic.
5. Press Stop: confirm Finishing remains until finalization ends, the timer freezes, then the activity ends. Repeat quickly with another session to detect late updates from the old session.
6. Dismiss during a stream: status updates must not recreate it. A new stream may create a new activity.
7. Test record-only, no YouTube authorization/manual key, background/foreground within the grace period, longer backgrounding, force quit/relaunch, and a temporary connection loss. Stale data must never look freshly healthy.
8. Test Off: no Live Activity or additional viewer queries. Compare normal and Battery Saving Mode during a longer stream.

## Signing and versions

The iPhone app embeds the new `com.subside.Tubeist.LiveActivity` extension with automatic signing and the existing development team. Xcode may need to register/provision that new identifier on the first signed archive. No Watch app identifier, push service or time-sensitive notification entitlement is added.

The app and extension inherit `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from the Xcode project. Bump the project-level values together before a TestFlight upload; the current version/build were not incremented by this feature.
