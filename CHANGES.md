# Apple Watch Live Activity: change summary

Branch `feature/watch-live-activity`, based on `5e2d440`. Nothing here has been run on a physical device, an Apple Watch, or with real signing.

## Summary

While Tubeist is streaming, the iPhone shows an ActivityKit Live Activity (lock screen and Dynamic Island). It is designed for iOS to mirror it to a paired Apple Watch Smart Stack; that has not been verified on hardware. It shows LIVE state, elapsed time, YouTube stream health and, depending on the detail setting, viewers, bitrate, local upload quality, thermal state and battery. A Bad / No Data health state raises a Time Sensitive alert (watch haptic). There is no backend and no push tokens: the foreground app updates the activity locally. The design is in `docs/superpowers/specs/2026-09-20-watch-live-activity-design.md`.

## How it works

- `StreamActivityCoordinator` (main actor) runs while a stream is live. It ticks every 5 s, polls YouTube stream health every 30 s and concurrent viewers every 60 s (Full detail only), backs off after errors (5 min when YouTube rejects the call with HTTP 403, which is how a quota rejection arrives), and builds a `StreamSnapshot`. The bitrate is read with the router's non-mutating `currentVideoBitrate()`, and only in Full detail: `recommendedVideoBitrate()` evaluates the adaptive-bitrate controller, which belongs to the encoding pipeline alone.
- `StreamActivityPolicy` (pure, unit tested) turns snapshots into a `Decision`: update throttle (5 s), a 60 s heartbeat so an unchanged healthy activity is still pushed before its 90 s stale date, stale after 60 s without fresh health, alert debounce (10 s) and cooldown (60 s), recovery alert. The debounce is measured on the polled state, so with a 30 s poll a single bad reading can alert; YouTube's health value is already smoothed on their side. When no YouTube stream id is bound (manual stream key, or not signed in) health is not tracked at all: no alerts, never stale, and the widget shows a plain "Live".
- `StreamActivityController` owns the `Activity`: request, update (staleDate 90 s), end, restart before the 8 h ActivityKit limit (at 7.5 h), and re-request if the user dismissed or the system ended the activity (ending the dead one first). `end()` ends every activity of this type, and `endOrphanedActivities()` runs at launch while idle to clear an activity a crash or force-quit left on screen. Alerts go through the activity; if it is unavailable or dismissed they fall back to a local Time Sensitive notification (`StreamAlertNotifier`). Notification authorization is requested from `TubeistView.onAppear` while not streaming, never at go-live, where a system modal would land on the camera UI.
- `TubeistLiveActivity` widget extension renders the lock screen, Dynamic Island and watch (`.small`) layouts. Shared types live in `Shared/StreamActivityAttributes.swift`, compiled into both targets.
- `AppState` gained `youtubeStreamId` (bound stream id, needed for the health poll) and `streamStartedAt`.

## Files

Added:
- `Shared/StreamActivityAttributes.swift`: `StreamActivityAttributes`, `ContentState`, `YouTubeStreamHealth`, `LinkQuality`, `ContentState.bitrateLabel(kbps:)`.
- `Tubeist/StreamActivityPolicy.swift`: pure snapshot to decision/alert policy, plus `LiveActivityDetail` and `StreamSnapshot`.
- `Tubeist/StreamActivityController.swift`: ActivityKit lifecycle, `StreamActivitySink` protocol, `StreamAlertNotifier`.
- `Tubeist/StreamActivityCoordinator.swift`: polling/tick loop and snapshot assembly.
- `TubeistLiveActivity/StreamLiveActivity.swift`, `TubeistLiveActivityBundle.swift`, `Info.plist`: widget extension.
- `TubeistTests/StreamActivityPolicyTests.swift`, `StreamActivityCoordinatorTests.swift`, `StreamActivityFormattingTests.swift`, `StreamActivityLifecycleTests.swift`.
- `docs/superpowers/specs/2026-09-20-watch-live-activity-design.md`, `docs/superpowers/plans/2026-09-20-watch-live-activity.md`.

Modified:
- `Tubeist/YouTubeService.swift`, `Tubeist/YouTubeAPITransport.swift`: `fetchStreamHealth(streamId:)`, `fetchConcurrentViewers(videoId:)`, `setYouTubeBroadcast(id:streamId:status:)`.
- `Tubeist/TubeistApp.swift`: `AppState.youtubeStreamId`, `streamStartedAt`; app-level wiring.
- `Tubeist/TubeistView.swift`: starts/stops the coordinator with stream state and scene phase.
- `Tubeist/Streamer.swift`: records the stream id alongside the broadcast id.
- `Tubeist/Settings.swift`: "Apple Watch" settings section and keys.
- `Tubeist/Tubeist.entitlements`: `com.apple.developer.usernotifications.time-sensitive`.
- `Tubeist.xcodeproj/project.pbxproj`: new extension target, embed phase, `INFOPLIST_KEY_NSSupportsLiveActivities = YES` on the app target, new sources and test files.
- `TubeistTests/StreamerTests.swift`, `TubeistTests/YouTubeServiceTests.swift`: new coverage.

## Applying

Base commit: `5e2d440`. From a checkout of that commit: `git am patches/*.patch`, then build in Xcode 26 or later. The `patches/` directory is not in the repository: it is produced inside the delivery zip described in the plan document, alongside a copy of the source.

## Settings (UserDefaults)

| Key | Type | Default |
|---|---|---|
| `LiveActivityDetail` | string: off / standard / full | `standard` |
| `AlertOnBadHealth` | Bool | `true` |
| `AlertOnRecovery` | Bool | `false` |

Recovery alerts are only meaningful when Bad alerts are on (the toggle is disabled otherwise).

## Build and test results (actual)

Destination: `platform=iOS Simulator,id=894A0599-2AF5-49F7-8160-0BC445B4E21E` (iPhone 17 Pro; the name alone is ambiguous on this machine). All with `CODE_SIGNING_ALLOWED=NO`.

- `xcodebuild test -project Tubeist.xcodeproj -scheme Tubeist ...` (full test action, unit and UI): `** TEST SUCCEEDED **`. 265 test cases reported passed and 0 failed: 252 unit tests (Swift Testing/XCTest in `TubeistTests`) and 13 UI tests (`TubeistUITests`). During the UI phase the log showed one "Simulator device failed to launch com.subside.TubeistUITests.xctrunner" launch error; the run continued and every UI test passed, so treat it as simulator flakiness. Counts are from `Test case ... passed` lines in the log.
- After the final review fixes: `xcodebuild test ... -only-testing:TubeistTests`: `** TEST SUCCEEDED **`, 261 `Test case ... passed` lines and 0 failed (238 distinct unit test cases, up from 228; the difference between line and case counts comes from parameterized tests). UI tests were not re-run.
- `xcodebuild build ... -configuration Release`: `** BUILD SUCCEEDED **`. The only warning is the pre-existing "no 'async' operations occur within 'await' expression" in `LiveEncodingPipeline.swift:50`, which this branch does not touch.
- The Live Activity UI (widget extension) is only compile-checked. There are no tests for the widget views, the link row, or the real ActivityKit calls (the lifecycle tests use the `StreamActivitySink` fake).

## Decisions and deviations from the plan

- Foreground app, no backend: updates are pushed locally by the running app; no APNs, no push-to-start tokens.
- Dropped frames are not shown. No dropped-frame counter exists, so Full detail shows local upload quality (`LinkQuality`) instead. The link row appears only when quality is not good.
- `Activity` is not `Sendable` in the iOS 27 SDK, so `StreamActivityController` wraps it in a private `ActivityHandle: @unchecked Sendable` box (about 14 lines, commented). This assumes ActivityKit `update`/`end` are safe from any isolation.
- `StreamAlertNotifier` is `@MainActor` instead of `@unchecked Sendable`. `.timeSensitive` was dropped from the authorization options request (it is an interruption level on the content plus the entitlement, not an auth option).
- A `StreamActivitySink` protocol seam lets lifecycle tests run without ActivityKit.
- `AppState.streamStartedAt` (set on first `.live`, cleared at idle/failed) drives the elapsed timer so it survives coordinator restarts, for example a foreground/background bounce inside the 3 s grace window.
- A dismissed or ended activity is re-requested; alerts fall back to a notification instead of being swallowed by a dead activity.
- Bitrate shows as `%.1f Mbps`, or kbps under 1000 (`ContentState.bitrateLabel(kbps:)`), fixing an integer-division bug in the original plan snippet.
- Restart at 7.5 h (before ActivityKit's 8 h cap).
- Review rounds fixed: link row never rendered (Task 4), grace-window bounce leaving the coordinator stopped and stop/poll race orphaning an activity (Task 5).
- Final review round fixed: the status loop evaluated the adaptive-bitrate controller (now a non-mutating read, Full only); a healthy Standard activity went stale at 90 s (60 s heartbeat); failed status polls logged ERROR every cycle (now `.debug`); the notification prompt fired at go-live (now while idle, from `onAppear`); a crash left a permanent "live" activity (launch sweep, end-all, gone handles ended); streams with no bound YouTube stream id read "Live ?" forever (`healthTracked`); polling quota roughly halved (30 s / 60 s); a stale gap now restarts the bad-health debounce.

## Known limitations and follow-ups

- Key unverified risk: see notes for the lead below.
- Policy has no trailing update in its throttle; correctness relies on the coordinator's 5 s tick.
- Redundant `start()` ends and re-requests the activity (brief watch gap); adopting an existing activity would be better.
- Only HTTP 403 (how a quota rejection arrives) is backed off; 429/5xx retry at the normal 30 s cadence. Stream/video ids are not percent-encoded in URLs (matches existing code).
- Policy state (debounce, cooldown) does not survive a coordinator restart, `.connecting`/`.stopping` are effectively unreachable phases, viewer counts carry no staleness marker, `areActivitiesEnabled` is read on every push, and the fallback notification reuses one identifier. All deliberate, all recorded here rather than fixed.
- Timer keeps counting in `.stopping`/`.ended` states of the widget (the controller ends the activity immediately; check on device). Battery icon is static. The `.small` watch layout may truncate "Live . No data".
- Bitrate rounding near 1050 kbps is float-dependent; `String(format:)` is not localized.
- Test gaps: stale-to-fresh bad transitions, `.ok` recovery, `.unknown` resetting debounce, runtime toggling of `alertOnBad`, cancellation re-check, `isGone`, snapshot round trip, no test for clearing the stream id.
- Disabled recovery toggle can still display ON (no effect without bad alerts).

## Manual device checklist

- [ ] Unit tests pass for `StreamActivityPolicy` and the YouTube health/viewer fetches.
- [ ] App and `TubeistLiveActivity` build for iOS Simulator.
- [ ] Device: Live Activity appears on the paired watch Smart Stack during a stream, including with the iPhone unlocked and Tubeist in the foreground (key risk; see spec).
- [ ] Device: Bad / No Data health produces a watch alert and haptic; recovery alert respects its toggle.
- [ ] Device: Off/Standard/Full change what is shown; Live Activities disabled in iOS Settings falls back to notifications.
- [ ] Device: a stream longer than 8 h keeps a Live Activity (restart path).
- [ ] Device: whether a Live Activity alert (the `AlertConfiguration` on an update) requires notification permission at all is unverified. Tubeist now asks for permission while idle rather than at go-live, so check both answers: permission granted, and permission denied with alerts still expected on the watch.
- [ ] Device: force-quit or crash Tubeist mid-stream, relaunch, and confirm the leftover Live Activity is swept away at launch.
- [ ] Device: stream with a manual stream key (no bound YouTube stream), and confirm the activity reads "Live" with a neutral dot rather than "Live ?".

## Notes for the lead

- Extension bundle id must be prefixed by the app's bundle id. Today: `com.subside.Tubeist.LiveActivity` under `com.subside.Tubeist`. If your app id differs, change `PRODUCT_BUNDLE_IDENTIFIER` on the `TubeistLiveActivity` target.
- Signing and provisioning for the new extension have never been exercised: every build used `CODE_SIGNING_ALLOWED=NO`. Set `DEVELOPMENT_TEAM` on the extension target and create its App ID/profile.
- Enable the Time Sensitive Notifications capability on the App ID. The entitlement `com.apple.developer.usernotifications.time-sensitive` was added to `Tubeist/Tubeist.entitlements`.
- `INFOPLIST_KEY_NSSupportsLiveActivities = YES` is a build setting on the app target (no Info.plist edit).
- The pbxproj was edited with the `xcodeproj` Ruby gem. Review the diff; expect harmless churn such as dropped empty `packageProductDependencies` lists.
- Verify first on a real device: whether the Live Activity and the Bad/No Data alert reach the watch while the iPhone is unlocked with Tubeist in the foreground. iOS may keep Live Activities off the watch while the phone is in active use. Fallback if it does not: a watchOS companion app via WatchConnectivity.
- Nothing has been device-tested.
