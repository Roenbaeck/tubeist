# Watch Live Activity — design

Base commit: `5e2d440` (branch `feature/watch-live-activity`).

## Goal

While streaming, show live YouTube stream status on the Apple Watch (and iPhone
lock screen / Dynamic Island) without opening YouTube or looking at the phone,
and alert on the watch when stream health becomes Bad or No Data.

## Approach

An iOS Live Activity (ActivityKit) defined in a widget extension and driven
directly by the running Tubeist app. watchOS 11+ mirrors iPhone Live Activities
to the Smart Stack automatically, so no watchOS target is needed. No backend and
no APNs: Tubeist is running (camera capture + `BackgroundExecutionLease`) for
the whole stream, so it can update the activity locally.

Rejected: a native watchOS companion app (extra target, WatchConnectivity, more
testing for a glanceable status) and a backend push service (only needed if
updates must survive the app being killed).

Existing auth is reused: `YOUTUBE_SCOPES` is `https://www.googleapis.com/auth/youtube`,
which covers stream health and viewer counts. No new sign-in or scope.

## Components

- `StreamSnapshot` — immutable value: session state, start time, YouTube health
  (`good|ok|bad|noData|unknown`), concurrent viewers, bitrate, dropped frames,
  thermal state, battery, warning text, last-updated time.
- `StreamActivityPolicy` — pure logic, no ActivityKit. Selects fields per detail
  level, throttles updates (~1 per 5 s), marks values stale after ~60 s, and runs
  the alert state machine (debounce ~10 s, cooldown 60 s, optional recovery alert).
- `StreamActivityController` — `@MainActor` wrapper over ActivityKit: start,
  update, end, 8-hour restart, detect Live Activities disabled, fall back to a
  local notification when the activity cannot be shown.
- `StreamActivityAttributes` — shared ActivityKit attributes/content state
  (compiled into app and extension).
- `TubeistLiveActivity` widget extension — lock screen, Dynamic Island and
  Smart Stack layouts.
- `YouTubeService` additions — `fetchStreamHealth(streamId:)` and
  `fetchConcurrentViewers(videoId:)`, reusing `apiGet`, token refresh and
  `YouTubeAPITransport` error handling.

## Settings

- Live Activity detail: Off / Standard / Full.
  - Standard: state, elapsed time, YouTube health, reconnect/upload-outage warning.
  - Full: Standard plus viewers, bitrate, dropped frames, thermal state, battery.
- Alert on Bad / No Data (default on).
- Alert when recovered (default off).

## Data flow and polling

`Streamer` state changes and a poller feed a `StreamSnapshot`; the policy turns
it into an activity update. Health is polled ~every 15 s; viewers ~every 30 s and
only in Full. A failed poll keeps last values and marks them stale (shown as
"?", never a false "good"). 403/quota errors back off the interval. All work is
off the media pipeline and fire-and-forget; nothing here may disturb streaming.

## Alerts

Primary: update the activity with an `AlertConfiguration`, which raises a watch
banner and haptic even while mirrored. Fallback: local notification
(`UNUserNotificationCenter`, with a `willPresent` handler so it shows in the
foreground) when Live Activities are unavailable. Marked time-sensitive, which
requires the Time Sensitive Notifications entitlement. An alert fires only when
Bad/NoData persists ~10 s; repeats limited to one per minute.

## Known limits

- iOS ends a Live Activity after 8 h; the controller restarts it for longer streams.
- Live Activities disabled in iOS Settings → feature falls back to notifications only.
- Viewer counts from YouTube lag by tens of seconds; polling costs API quota.
- Watch rendering and haptics can only be verified on a real device.

## Testing

- Unit tests (`TubeistTests`) for `StreamActivityPolicy`: detail levels,
  throttling, debounce, cooldown, stale handling.
- Decoding tests with JSON fixtures for health and viewer responses.
- `xcodebuild build` and `test` on a simulator with signing disabled.
- Manual device checklist: activity appears on watch, health change alerts,
  8-hour restart, Live Activities disabled path.

## Delivery

Commits on `feature/watch-live-activity` only; nothing is pushed. Deliverable
zip: `patches/` (`git format-patch` against `5e2d440`), `CHANGES.md`, and a
`git archive` snapshot. The author's local signing/entitlement tweaks are kept
out of the branch and the zip. Project work is recorded as a new phase in
`PLAN.md`.
