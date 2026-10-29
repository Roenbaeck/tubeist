# Planned Streams and Read-only Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In Settings, let the operator pick one of today's YouTube Studio-planned broadcasts on this phone's stream key, edit it, and Start on exactly that broadcast. Settings can also be opened read-only while streaming. The existing manual "New stream" flow does not regress.

**Architecture:**
- **Pure layer.** A new `Tubeist/PlannedStreams.swift` holds the pure parts: the saved-selection model, today-filtering, labels, and change diffs.
- **YouTube API.** `YouTubeService` gains read calls (planned list, playlist membership, thumbnail download, playlist removal) and a planned/restart branch in the Start preflight. Its upcoming-broadcast discovery is narrowed so "New stream" only reuses broadcasts Tubeist created.
- **Settings and Start.** `YouTubeSettingsDraft` and `SettingsView` add the picker and a separate saved selection. The `YouTubeBroadcastPreferences` template stays as it is. `Streamer` passes the selection to Start and turns it into a Restart entry once Start succeeds.
- **Read-only mode.** `SettingsView` takes an `isReadOnly` flag, and `TubeistView` skips every open and close side effect in that mode.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), YouTube Data API v3. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-28-planned-streams-design.md`

## Global Constraints

- No external dependencies. Follow the existing `YouTubeService` patterns: `authorizationScope()`/`checkAuthorization(_:)` around every await, `paginatedItems`, `resourceURL`, `YouTubeDiagnostics` logging, and a typed `YouTubeAPIOperation` for each request.
- Settings Save is local-only. YouTube is changed only in the Start preflight.
- **Hard requirement: no regression in the manual flow.** With "New stream" selected, the following behave as today:
  - Settings fields, Save, the Start preflight, Stop/auto-stop and Watch Start.
  - Signed-out use and a bare pasted key.

  Saved settings from the current version load unchanged. No migration resets the template, thumbnail or playlist.
- The only intended behaviour change in the manual flow is that "New stream" never adopts an upcoming broadcast Tubeist did not create.
- Existing tests must pass unchanged except where they assert adoption of a non-Tubeist upcoming broadcast (Task 2). Any other failing test is a regression and must be fixed in code, not in the test.
- List label format is `HH:mm – Title`, with a 24-hour clock, the phone's local time zone and an en dash, sorted by scheduled time.
- Picker row label: `Planned stream`. First entry: `New stream`. Restart entry: `Restart: <title>`.
- Unavailable-pick error text: `The planned stream '<title>' is no longer available. Choose another in Settings.`
- Picker footer: `Don't see a match? In YouTube Studio, open it and select this phone's stream key: <stream title>`. This uses the stream's YouTube title, never the secret key.
- Read-only banner: `Settings are locked while streaming. Stop the stream to change them.`
- Test command (one suite): `xcodebuild test -project Tubeist.xcodeproj -scheme Tubeist -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TubeistTests/<SuiteName>`. Use the full suite by dropping `-only-testing`.
- Commit messages follow the repo style: an imperative sentence, no `feat:` prefix. They end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Midnight and time zone.** A match at 00:30 local time is stored in UTC as the previous day. It must be listed on the local day it is played. A 23:59 local broadcast is today, and 00:00 tomorrow is not. Tested in Task 1.
2. **Studio broadcast without a custom thumbnail, or a failed thumbnail download.** Picking still works, the preview is empty, and Start uploads no thumbnail. Tested in Tasks 3 and 4.
3. **A pick deleted, completed or re-keyed in Studio after it was saved.** This includes a pick from a different signed-in account, whose bound stream doesn't match. Start throws the unavailable error and sends no write request. Tested in Task 4.
4. **Pick, edit, then Cancel.** Nothing is saved, and reopening shows the previously saved choice and template untouched. Pick a match, then switch back to "New stream": the template fields return exactly. Tested in Task 6.
5. **Changing the stream key in Settings while a planned match is selected.** The selection is dropped, because it belongs to the old stream. Tested in Task 6.

---

### Task 1: Planned-stream model and pure helpers

**Files:**
- Create: `Tubeist/PlannedStreams.swift`
- Modify: `Tubeist/YouTubeService.swift`:
  - `YouTubeBroadcast` (around line 17): add `var thumbnailURL: String? = nil` as the **last** stored property, so existing memberwise calls compile;
  - `YouTubeBroadcastResource.Snippet` and `.broadcast` (around lines 182–240): decode `thumbnails` and pick the best URL;
  - `YouTubeLiveStreamResource.Snippet` (around line 172): add `let title: String?`.
- Test: `TubeistTests/PlannedStreamTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  struct PlannedStreamDetails: Codable, Sendable, Equatable {
      var title: String; var privacyStatus: String; var selfDeclaredMadeForKids: Bool
      var enableDvr: Bool; var enableEmbed: Bool; var latencyPreference: String
      var playlistId: String?
      init(broadcast: YouTubeBroadcast, playlistId: String?)
  }
  struct YouTubePlaylistMembership: Codable, Sendable, Equatable { let playlistId: String; let itemId: String }
  struct PlannedStreamSelection: Codable, Sendable, Equatable {
      enum Kind: String, Codable, Sendable { case planned, restart }
      var kind: Kind
      let broadcastId: String          // planned: the target; restart: the ended broadcast
      let streamId: String
      let scheduledStartTime: String   // ISO 8601 from YouTube; drives the same-day rule
      var loaded: PlannedStreamDetails // values as loaded from YouTube
      var edited: PlannedStreamDetails // values in the fields at Save
      var loadedMembership: YouTubePlaylistMembership?
      var thumbnailChanged: Bool
      func restarting() -> PlannedStreamSelection
  }
  enum PlannedStreams {
      static func isScheduledToday(_ iso: String?, now: Date, calendar: Calendar) -> Bool
      static func today(_ broadcasts: [YouTubeBroadcast], streamId: String, excluding: Set<String>,
                        now: Date, calendar: Calendar) -> [YouTubeBroadcast]
      static func label(for broadcast: YouTubeBroadcast, calendar: Calendar) -> String
      static func restartLabel(for selection: PlannedStreamSelection) -> String
  }
  ```
- `restarting()` returns `kind = .restart`, `loaded = edited`, and `loadedMembership = nil`. It keeps `thumbnailChanged`, which is true when a planned thumbnail file exists (see Task 5).
- `today` keeps broadcasts that:
  - have `boundStreamId == streamId`;
  - have `lifeCycleStatus` of `ready` or `created`;
  - are not in `excluding`;
  - pass `isScheduledToday`.

  The result is sorted by scheduled time, then by `id`.
- `label` uses a `DateFormatter` with `dateFormat = "HH:mm"`, `locale = en_US_POSIX` and `timeZone = calendar.timeZone`.

- [ ] **Step 1: Write the failing tests** in `PlannedStreamTests` (a `struct` using `@Test`).
  - `todayUsesTheLocalCalendarDay`:
    - calendar time zone `Europe/Oslo`, `now = 2026-10-31T10:00:00Z`;
    - expect `isScheduledToday("2026-10-30T23:30:00Z") == true` (00:30 local on the 31st);
    - expect `"2026-10-31T22:59:00Z"` → true (23:59 local);
    - expect `"2026-10-31T23:00:00Z"` → false (00:00 local on the 1st);
    - expect `nil` → false.
  - `todayFiltersBoundUpcomingAndSortsByTime`. Input:
    - two ready broadcasts on `stream-1`, at 13:00 and 08:00;
    - one `complete` broadcast;
    - one ready broadcast bound to `stream-2`;
    - one ready broadcast scheduled for tomorrow;
    - one ready broadcast whose id is in `excluding`.

    Expect `ids == ["b-0800", "b-1300"]`.
  - `labelIsTwentyFourHourLocalTimeWithEnDash`: `label` for `"2026-10-31T09:30:00Z"`, `title: "Match 5"` in Oslo → `"10:30 – Match 5"`.
  - `restartingCopiesEditedDetailsAndDropsMembership`:
    - expect `kind == .restart`, `loaded == edited` and `loadedMembership == nil`;
    - expect `restartLabel == "Restart: <edited.title>"`.
  - `selectionRoundTripsThroughJSON`: encode, then decode, with an equal result.
  - `broadcastDecodesBestThumbnailURL`:
    - decode a `YouTubeBroadcastResource` JSON with `snippet.thumbnails` holding `default`, `high` and `maxres` → `thumbnailURL` is the `maxres` URL;
    - without `thumbnails` → `nil`.

- [ ] **Step 2: Run** `-only-testing:TubeistTests/PlannedStreamTests`. Expected: build failure, because the types are undefined.
- [ ] **Step 3: Implement** the types above in `Tubeist/PlannedStreams.swift` and the three `YouTubeService.swift` model additions. Thumbnail preference order: `maxres`, `standard`, `high`, `medium`, `default`.
- [ ] **Step 4: Run** the suite. Expected: PASS. Then run the full suite: still green, with no existing test touched.
- [ ] **Step 5: Commit** "Add planned-stream selection model and today filtering".

---

### Task 2: "New stream" never adopts a broadcast Tubeist did not create

**Files:**
- Modify: `Tubeist/YouTubeService.swift`:
  - `YouTubeBroadcastDiscovery.selectCurrentOrUpcoming` (line ~400);
  - `selectedBroadcast(forStreamKey:)` (line ~1072), together with the selection helper it calls for unknown streams (`matchingSelection`).
- Test: `TubeistTests/YouTubeServiceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum YouTubeUpcomingPolicy: Sendable, Equatable { case any; case only(String?) }
  static func selectCurrentOrUpcoming(from: [YouTubeBroadcast], upcoming: YouTubeUpcomingPolicy = .any) -> YouTubeBroadcast?
  ```
- Active broadcasts are always eligible. With `.only(id)`, a `ready`/`created` broadcast is eligible only when its `id == id`. `.only(nil)` admits no upcoming broadcast.
- `selectedBroadcast` passes `.only(discoveryCache.id("createdBroadcast", for: key))`. This one change covers Settings load, `findBroadcastForStreamKey`, `findHLSIngestionEndpoint` and the Start preflight.
- The default `.any` keeps the existing pure tests of `selectCurrentOrUpcoming` unchanged.

- [ ] **Step 1: Write the failing tests.**
  - `newStreamStartCreatesItsOwnBroadcastWhenAStudioMatchIsUpcoming`:
    - a planned Studio `ready` broadcast `"planned-1"` is bound to `stream-1`, and the discovery cache is empty;
    - `prepareForStreaming(streamKey: "test-key", preferences: setupPreferences())` sends `POST …/liveBroadcasts` (insert) and `POST …/liveBroadcasts/bind`;
    - no request has `id=planned-1` in a PUT body or the query;
    - `preparation.broadcast.id != "planned-1"`.
  - `newStreamStartStillReusesTheBroadcastTubeistCreated`: same responses, but the cache is seeded with `cache.setID("ready", kind: "createdBroadcast", for: YouTubeDiscoveryCache.key(scope: YouTubeDiscoveryCache.scope(refreshToken: "refresh-token"), streamKey: "test-key"))`. Expect `preparation.broadcast.id == "ready"`, and no insert.
  - `liveBroadcastIsStillResumedRegardlessOfOrigin`: an active (`liveStarting`) non-cached broadcast is still selected, and Start throws `broadcastNotReady("starting live stream")` as today.
- [ ] **Step 2: Run** `-only-testing:TubeistTests/YouTubeServiceTests`. Expected: the first new test fails, because the planned broadcast is adopted.
- [ ] **Step 3: Implement** the policy and wire it in `selectedBroadcast`.
- [ ] **Step 4: Run the full suite.** Some existing preflight and Settings-load tests will now fail only because they serve a non-cached `ready` broadcast and expect it to be reused (for example `streamingPreflightReusesReadyAndRejectsStillActiveBroadcasts` and `streamingPreflightAppliesSavedPreferencesWithoutCreatingAnotherBroadcast`).
  - Fix **only** those, by seeding the cache with that broadcast's id as `createdBroadcast` for the test key, as in the second new test. Do not change their assertions.
  - List every test you touched in the commit message body. Any other failure is a regression; fix the code.
- [ ] **Step 5: Commit** "Only reuse Tubeist-created upcoming broadcasts for New stream".

---

### Task 3: Service reads and playlist removal

**Files:**
- Modify: `Tubeist/YouTubeAPITransport.swift` (`YouTubeAPIOperation`, around line 50). Add:
  - `case deletePlaylistItem = "playlistItems.delete"`;
  - `case thumbnailDownload = "thumbnail download"`.

  Add both to the `.warning` failure-level list.
- Modify: `Tubeist/YouTubeService.swift` (new methods next to `listPlaylists` and `addToPlaylist`).
- Test: `TubeistTests/YouTubeServiceTests.swift`

**Interfaces:**
- Consumes: `PlannedStreams.today`, `YouTubePlaylistMembership` (Task 1).
- Produces (all on `YouTubeService`, `@MainActor`):
  ```swift
  struct YouTubePlannedStreams: Sendable, Equatable { let streamTitle: String?; let broadcasts: [YouTubeBroadcast] }
  func loadPlannedBroadcasts(forStreamKey: String, calendar: Calendar = .current) async throws -> YouTubePlannedStreams
  func playlistMembership(videoId: String, among: [YouTubePlaylist]) async throws -> YouTubePlaylistMembership?
  func downloadThumbnail(from url: String) async throws -> Data
  func removeFromPlaylist(itemId: String) async throws
  ```
- **`loadPlannedBroadcasts`:**
  - Resolve the stream the same way `selectedBroadcast` does, reusing that path rather than duplicating discovery.
  - Page `liveBroadcasts?part=snippet,contentDetails,status&broadcastStatus=upcoming&broadcastType=all&maxResults=50`.
  - Return `PlannedStreams.today(…, excluding: [cached createdBroadcast id])`, using `now()`.
  - `streamTitle` comes from the stream resource's `snippet.title` (via `streamByID`). `nil` is allowed.
- **`playlistMembership`:** for each playlist in order, call `playlistItems?part=id&playlistId=…&videoId=…&maxResults=1` and return the first hit with its item `id`. The fan-out is bounded by `among.count`.
- **`downloadThumbnail`:**
  - A plain GET through `requestExecutor` with no `Authorization` header and operation `.thumbnailDownload`.
  - HTTPS only, which the executor already enforces.
  - Reject bodies over 2,000,000 bytes with `YouTubeError.thumbnailTooLarge`.
- **`removeFromPlaylist`:** `DELETE {YOUTUBE_API_BASE}/playlistItems?id=…` via `authenticatedData`, with operation `.deletePlaylistItem`. A 204 with an empty body is success.

- [ ] **Step 1: Write the failing tests.**
  - `plannedListReturnsOnlyTodaysBroadcastsOnThisStreamAndNotTubeistsOwn`:
    - the upcoming page holds: today on `stream-1`, today on `stream-2`, tomorrow on `stream-1`, and the cached `createdBroadcast`;
    - expect one broadcast, and `streamTitle == "Court 1"`.
  - `membershipReturnsFirstPlaylistContainingTheBroadcast`:
    - three playlists, with a hit in the second;
    - expect 2 requests and `itemId == "item-9"`;
    - with no hits, expect `nil` and 3 requests.
  - `removeFromPlaylistSendsDeleteWithItemID`: `httpMethod == "DELETE"`, query `id=item-9`, and a 204 empty response doesn't throw.
  - `thumbnailDownloadSendsNoAuthorizationHeader`: the `Authorization` header is nil and the body is returned. A 2,000,001-byte body throws `.thumbnailTooLarge`.
- [ ] **Step 2: Run** the suite. Expected: compile failure, because the methods are undefined.
- [ ] **Step 3: Implement** the four methods.
- [ ] **Step 4: Run** the suite. Expected: PASS.
- [ ] **Step 5: Commit** "Add YouTube reads for planned broadcasts, playlist membership and thumbnails".

---

### Task 4: Start on a planned or restart selection

**Files:**
- Modify: `Tubeist/YouTubeService.swift`:
  - `prepareForStreaming` / `performStreamingPreparation` (lines ~915–1060);
  - `YouTubeStreamingPreparation` (around line 98): add `var warnings: [String] = []`;
  - `YouTubeError`: add `case plannedBroadcastUnavailable(String)`, with the exact message from Global Constraints.
- Test: `TubeistTests/YouTubeServiceTests.swift`

**Interfaces:**
- Consumes: `PlannedStreamSelection`, `PlannedStreams.isScheduledToday` (Task 1); `removeFromPlaylist`, `addToPlaylist`, `uploadThumbnail` (Task 3 and existing).
- Produces:
  ```swift
  func prepareForStreaming(streamKey: String, preferences: YouTubeBroadcastPreferences? = nil,
      thumbnailData: Data? = nil, endingPolicy: HLSStreamEndingPolicy = .automatic,
      plannedSelection: PlannedStreamSelection? = nil, plannedThumbnail: Data? = nil,
      calendar: Calendar = .current) async throws -> YouTubeStreamingPreparation
  ```
- With `plannedSelection == nil`, the code path is the existing one, unchanged.

**Behaviour, for `plannedSelection != nil`:**
1. Resolve the stream as today.
   - If an **active** broadcast exists on it, throw `broadcastNotReady`, as today.
   - If `selection.streamId != stream.id`, or `!isScheduledToday(selection.scheduledStartTime)`, throw `plannedBroadcastUnavailable(selection.edited.title)` before any write.
2. **`.planned`:**
   - GET `liveBroadcasts?id=<broadcastId>&part=snippet,status,contentDetails`.
   - If it is missing, has `boundStreamId != stream.id`, or has a lifecycle other than `ready`, throw `plannedBroadcastUnavailable`. Never fall back.
   - Build the prepared broadcast by applying **only fields where `edited != loaded`** onto the fetched broadcast.
   - Force `enableAutoStart = true`, `enableMonitorStream = false` and `broadcastStreamDelayMs = 0`, and set `enableAutoStop` from `endingPolicy`.
   - `updateBroadcast` only if the result differs from the fetched broadcast. Keep its `scheduledStartTime`.
3. **`.restart`:** call `createOrResumeBroadcast` with a template built from `selection.edited`, after `YouTubeBroadcast.draft(for:)` with those fields set. Apply the same forced go-live values.
4. **Thumbnail:**
   - Upload `plannedThumbnail` if `thumbnailChanged` is true (planned) or if it is non-nil (restart).
   - Failure is a warning, as today.
5. **Playlist:**
   - **Planned:** if `edited.playlistId != loaded.playlistId`:
     - if `loadedMembership` is set, `removeFromPlaylist(itemId:)`. On failure, append `"Could not remove '<title>' from its previous playlist. Check it in YouTube Studio."` to `warnings` and continue;
     - then, if `edited.playlistId` is set, `addToPlaylist`, with the existing warning-only failure.
   - **Restart:** `addToPlaylist(edited.playlistId)` if set.
6. Return the preparation, with `warnings`.

- [ ] **Step 1: Write the failing tests.** Fixtures are a planned `ready` broadcast `"m5"` on `stream-1`, scheduled today relative to the service `now`, and a selection whose `loaded` mirrors it.
  - `plannedStartSendsOnlyChangedFieldsAndForcesGoLive`:
    - edited title is `"Match 5 – Final"` and everything else is equal;
    - expect one PUT with `id` `m5`, the body containing the new title and `"enableAutoStart":true`, `"enableMonitorStream":false`, `"broadcastStreamDelayMs":0`;
    - the body's `privacyStatus` equals the fetched value;
    - no insert or bind request;
    - no thumbnail or playlist requests.
  - `plannedStartWithNoChangesAndGoLiveAlreadySetSendsNoWrite`: no PUT or POST at all.
  - `plannedStartIsRefusedWithoutAnyWrite`, parameterised over:
    - the broadcast missing (empty page);
    - `complete`;
    - bound to `stream-2`;
    - selection `streamId` of `"other"`;
    - scheduled yesterday.

    Each throws `.plannedBroadcastUnavailable("Match 5")`, and no request has method PUT, POST or DELETE.
  - `changingPlaylistRemovesTheOldItemThenAdds`: expect a DELETE `id=item-1`, then the insert POST with the new playlist id.
  - `failedRemovalWarnsButStillStarts`: the DELETE returns 500 → no throw, and `warnings.count == 1`.
  - `unchangedThumbnailIsNotUploaded` / `changedThumbnailIsUploaded`: check for presence of the `thumbnails/set` request.
  - `restartCreatesANewBroadcastWithTheEditedDetails`:
    - expect an insert POST whose body contains the edited title and `privacyStatus`, and then a bind;
    - `addToPlaylist` with the edited playlist;
    - a thumbnail upload when `plannedThumbnail != nil`.
  - `restartFromAnEarlierDayIsRefused`: throws `.plannedBroadcastUnavailable`.
- [ ] **Step 2: Run** the suite. Expected: compile failure, because the parameters and the error case are undefined.
- [ ] **Step 3: Implement** the branch as a separate private function called from `performStreamingPreparation` when `plannedSelection != nil`. The existing path stays byte-for-byte unchanged when it is nil.
- [ ] **Step 4: Run the full suite.** Expected: all green, with no further edits to existing tests.
- [ ] **Step 5: Commit** "Start on a picked planned broadcast or restart it with the same details".

---

### Task 5: Persist the selection and use it at Start

**Files:**
- Modify: `Tubeist/Settings.swift`:
  - the `Settings` statics near `youtubeBroadcastPreferences` (around line 1874) and the thumbnail file helpers (around line 1887);
  - `AppliedSettingsSnapshot` (around lines 231–345): capture and restore both new values.
- Modify: `Tubeist/Streamer.swift` (around lines 850–870, the signed-in branch that calls `prepareForStreaming`).
- Test: `TubeistTests/SettingsMigrationTests.swift`

**Interfaces:**
- Produces:
  ```swift
  static var plannedStreamSelection: PlannedStreamSelection?   // UserDefaults key "PlannedStreamSelection", JSON
  static func loadPlannedStreamThumbnailData() throws -> Data?  // file "planned-stream-thumbnail.jpg", same directory as the template thumbnail
  static func setPlannedStreamThumbnailData(_ data: Data?) throws
  ```
  Generalise `youtubeThumbnailURL` to take the file name. The existing template file name stays `youtube-broadcast-thumbnail.jpg`.
- **Streamer:**
  - Read `Settings.plannedStreamSelection` and the planned thumbnail, and pass them to `prepareForStreaming`.
  - After success, when a selection was used:
    - set `Settings.plannedStreamSelection = selection.restarting()`;
    - for each item in `preparation.warnings`, `await presentAlert(message)`.
  - On failure, leave the selection untouched so a retry works.
  - The existing preferences and thumbnail are still passed unchanged. The service ignores them when a selection is present.

- [ ] **Step 1: Write the failing tests.**
  - `existingSettingsWithoutAPlannedSelectionLoadUnchanged`:
    - with only the current keys present (`YouTubeBroadcastPreferences` and the template thumbnail file), `plannedStreamSelection == nil`;
    - the template preferences decode equal to what was written;
    - the template thumbnail data is unchanged.
  - `plannedSelectionAndThumbnailRoundTripAndClear`: write, then read back equal values; set `nil`, and the key and the file are gone.

  Use the same isolated-defaults approach the suite already uses.
- [ ] **Step 2: Run** `-only-testing:TubeistTests/SettingsMigrationTests`. Expected: compile failure.
- [ ] **Step 3: Implement** the statics, the snapshot fields and the Streamer wiring.
- [ ] **Step 4: Run the full suite.** Expected: PASS.
- [ ] **Step 5: Commit** "Persist the planned-stream choice and use it at Start".

---

### Task 6: Settings draft: choosing, editing and switching back

**Files:**
- Modify: `Tubeist/SettingsDraft.swift` (`YouTubeSettingsDraft`)
- Test: `TubeistTests/SettingsDraftTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces, on `YouTubeSettingsDraft`:
  ```swift
  enum PlannedStreamChoice: Hashable, Sendable { case newStream, planned(String), restart }
  private(set) var plannedBroadcasts: [YouTubeBroadcast]
  private(set) var plannedStreamTitle: String?
  private(set) var restartSelection: PlannedStreamSelection?
  private(set) var plannedChoice: PlannedStreamChoice            // default .newStream
  let plannedThumbnail = SettingsThumbnailDraft()
  var activeThumbnail: SettingsThumbnailDraft { get }            // plannedChoice == .newStream ? thumbnail : plannedThumbnail
  func applyPlanned(_ planned: YouTubePlannedStreams, saved: PlannedStreamSelection?, savedThumbnail: Data?, now: Date, calendar: Calendar)
  func choose(_ choice: PlannedStreamChoice)
  func loadPlannedDetails(for broadcastId: String, membership: YouTubePlaylistMembership?, thumbnail: Data?)
  func plannedSelection() -> PlannedStreamSelection?             // nil for .newStream
  ```

**Behaviour:**
- **Leaving `.newStream`:** stash the template field values (title, visibility, made-for-kids, DVR, embed, latency, playlist).
- **`choose(.newStream)`:** restore them exactly. `preferences()` must then equal its value from before the switch.
- **`loadPlannedDetails`:**
  - Fills the fields from the broadcast, with the playlist from `membership`.
  - Records them as `loaded`.
  - Puts the image into `plannedThumbnail` with no "new selection".
  - Ignored if `plannedChoice != .planned(broadcastId)`, which guards against a late response.
- **`applyPlanned`:**
  - With a `saved` planned selection whose `broadcastId` is in today's list, and `streamId` matching: restore the choice and its `edited` values, and set `loaded` from the saved value.
  - With a `saved` restart that `isScheduledToday`: set `restartSelection` and choose `.restart`.
  - Otherwise, leave `.newStream`.
- **`plannedSelection()`:**
  - Returns the selection with `edited` set to the current field values.
  - `thumbnailChanged` is true when `plannedThumbnail.hasNewSelection`, or when the saved selection had it set.
- **`useStreamKey(_:)` with a different key:** this already calls `reset()`. `reset()` also clears all planned state.

- [ ] **Step 1: Write the failing tests.**
  - `choosingAPlannedMatchThenNewStreamRestoresTheTemplateExactly`.
  - `plannedEditsDoNotChangeTemplatePreferences`: pick, edit the title, then check that `preferences()` is unchanged from before the pick.
  - `plannedSelectionRecordsLoadedAndEditedSeparately`.
  - `lateDetailsForAPreviousChoiceAreIgnored`.
  - `savedChoiceIsRestoredOnlyIfStillInTodaysList`: the saved broadcast is missing from the list → `.newStream`.
  - `savedRestartFromYesterdayIsNotOffered`.
  - `changingTheStreamKeyDropsThePlannedChoice`.
- [ ] **Step 2: Run** `-only-testing:TubeistTests/SettingsDraftTests`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the suite, then the full suite. Expected: PASS.
- [ ] **Step 5: Commit** "Let the Settings draft hold a planned match separately from the template".

---

### Task 7: Settings UI: picker, footer, load and save

**Files:**
- Modify: `Tubeist/Settings.swift`:
  - the YouTube section (lines ~503–657);
  - `loadYouTubeBroadcast` (around line 1355);
  - the Save action (around line 1021);
  - `saveYouTubePreferences` (around line 1410);
  - `thumbnailSelection` and `loadSelectedThumbnail` (around line 1192), so they target `youtubeDraft.activeThumbnail`.

**Interfaces:**
- Consumes: Task 3 service methods, Task 5 statics, Task 6 draft API.

**Behaviour:**
- **Picker:**
  - Shown when signed in and `youtubeDraft.broadcast != nil`, as the first row after the channel/status rows: `Picker("Planned stream", selection: …)`.
  - Entries:
    - `New stream`;
    - `Restart: <title>` if `restartSelection` is set;
    - then `PlannedStreams.label(for:calendar:)` for each planned broadcast.
  - If the loaded broadcast `isActive`, disable the picker.
- **Footer:**
  - Appended to the section's existing footer text when signed in: the Global Constraints footer, with `plannedStreamTitle`.
  - If there is no title, use the same sentence ending in "select this phone's stream key".
- **Load:**
  - After `loadSettingsConfiguration` succeeds, call `loadPlannedBroadcasts`, then `youtubeDraft.applyPlanned(…, saved: Settings.plannedStreamSelection, savedThumbnail: try? Settings.loadPlannedStreamThumbnailData(), …)`.
  - A failure in the planned load alone logs a warning and leaves the picker with just "New stream". It must not set `youtubeService.errorMessage` or block the template flow.
- **On choosing `.planned(id)`:**
  - Call `playlistMembership(videoId:among:)` and `downloadThumbnail(from:)`. The latter only if `thumbnailURL != nil`, and failure → `nil`.
  - Then call `loadPlannedDetails`.
  - Show the existing "Loading…" state while it runs, and disable Save until it finishes.
- **Save:**
  - **`.newStream`:** run the existing `saveYouTubePreferences()` unchanged, then `Settings.plannedStreamSelection = nil` and `setPlannedStreamThumbnailData(nil)`.
  - **Otherwise:** do **not** call `saveYouTubePreferences()`. Write `plannedSelection()` and the planned thumbnail data.
    - The data is the new pick, resized with the existing `scaledToFit(maxWidth: 1280, maxHeight: 720)` and `jpegDataWithinLimit(maxBytes: 2_000_000)`, or else the downloaded image.
  - Rollback on failure already restores both through `AppliedSettingsSnapshot` (Task 5).

- [ ] **Step 1: Build** `xcodebuild build -project Tubeist.xcodeproj -scheme Tubeist -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`. Expected: success.
- [ ] **Step 2: Run the full suite.** Expected: PASS, including all UI tests (`TubeistUITests`) unchanged.
- [ ] **Step 3: Simulator check while signed out.** Settings is unchanged: no picker row, and the footer text is identical to before.
- [ ] **Step 4: Commit** "Add the Planned stream picker to Settings".

---

### Task 8: Read-only Settings while streaming

**Files:**
- Modify: `Tubeist/Settings.swift`. In `SettingsView`:
  - an `isReadOnly: Bool = false` init parameter;
  - the toolbar (around line 1019);
  - the `.task(id: youtubeLoadContext)` load;
  - the YouTube section.
- Modify: `Tubeist/TubeistView.swift`:
  - the gear button (around line 651);
  - the sheet's `onDismiss` (around line 665);
  - `.onChange(of: showSettings)` (around line 1111).

**Interfaces:**
- Produces: `SettingsView(overlayManager:isReadOnly:)`.

**Behaviour:**
- **TubeistView:**
  - The gear always opens the sheet, and the dim-yellow tint stays while a session runs.
  - Add `@State private var settingsReadOnly = false`, set to `appState.isStreamSessionRunning` at the moment of opening, and pass it in.
  - In read-only mode:
    - `onDismiss` returns immediately: no overlay reload, no `YouTubeService` recreation, no status bootstrap, no `areSystemMetricsAtTop` reload;
    - `.onChange(of: showSettings)` does not set `isCameraReady = false`;
    - the `guard … !showSettings` in `prepareCamera` and `canPrepareCamera` must not tear down or re-prepare the camera. Confirm by reading those paths. Since `isCameraReady` stays true, `.task(id: canPrepareCamera)` returns at its guard.
- **SettingsView with `isReadOnly`:**
  - The first `Section` shows the read-only banner text.
  - `Form` is `.disabled(isSaving || isReadOnly)`.
  - Navigation items: a single trailing `Close` that dismisses. No Cancel and no Save.
  - Hide the `Planned stream` picker, `Stop YouTube Stream` and `Sign out of YouTube`.
  - The YouTube load shows the **broadcast in use**. `loadSettingsConfiguration` already returns the active broadcast first. Apply it with `savedPreferences: nil, savedThumbnail: nil`, so the fields show YouTube's values, then fill the playlist and thumbnail via `playlistMembership` and `downloadThumbnail`.
  - Nothing in read-only mode may write `Settings.*`, call `Streamer.shared.cycleSessions()`, or call any YouTube write. The only YouTube calls allowed are the reads above.
  - Code-review this by searching `SettingsView` for `Settings\.[a-zA-Z]+ =` and `Streamer.shared`. Every hit must sit in a path that can't run when `isReadOnly` is set.

- [ ] **Step 1: Build.** Expected: success.
- [ ] **Step 2: Run the full suite.** Expected: PASS.
- [ ] **Step 3: Simulator check.** Start a record-only session on the simulator (no YouTube needed), then open and close Settings five times.
  - Fields are greyed and there is no Save button.
  - The journal shows no camera re-prepare, overlay reload or session cycle entries.
  - The recording continues.
- [ ] **Step 4: Commit** "Open Settings read-only while a stream is running".

---

### Task 9: Acceptance and bookkeeping

**Files:**
- Modify: `PLAN.md`: add a short status entry for this feature with its test results, matching the existing entries' style.

- [ ] **Step 1: Run the full unit and UI suites.** Expected: all pass. Record the counts.
- [ ] **Step 2: Run** `Tools/check_youtube_only.sh`. Expected: exit 0.
- [ ] **Step 3: Release build:** `xcodebuild -project Tubeist.xcodeproj -scheme Tubeist -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`. Expected: success.
- [ ] **Step 4: Device acceptance, done by the user. List it in the hand-off; it is not run by the agent.** Do the steps in this order:
  1. **Manual flow first:**
     - Settings with "New stream" → Save → Start → Stop;
     - then Start from the Watch;
     - confirm the title, visibility, playlist and thumbnail match the template, exactly as before the update.
  2. **Planned flow:**
     - schedule two matches in Studio today, plus one tomorrow, on this phone's key, and one on another key;
     - only today's two show, in time order;
     - pick one, change its title and playlist, Save, Start;
     - YouTube shows the edited title, and it's removed from the old playlist and added to the new one;
     - Stop → Settings offers `Restart: <title>` → Start creates a new broadcast with the same details.
  3. **Never-hijack:** with a planned match on the key, choose "New stream" and Start. The planned match is untouched in Studio.
  4. **Read-only mid-stream:** during a YouTube stream, open and close Settings at least five times. Check:
     - no glitch in the YouTube preview;
     - no recording gap;
     - overlays unchanged;
     - Live Activity still updating;
     - the YouTube fields show the live broadcast.
- [ ] **Step 5: Commit** "Record planned-streams acceptance status".
