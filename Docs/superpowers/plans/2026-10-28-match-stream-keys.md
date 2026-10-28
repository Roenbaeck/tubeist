# Match Stream Keys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every planned YouTube match its own stream key, so video can only reach the broadcast that was picked, and make Start refuse (with a one-tap fix) whenever a key is shared or already in use.

**Architecture:** Pure rules (what is a match, what is Tubeist's own, which key is free, what conflicts) live in a new `Tubeist/MatchKeys.swift` with no I/O. `YouTubeService` gains one assignment routine (`assignMatchKeys` / `moveToOwnMatchKeys`) and one pre-flight check (`checkKeySafety`) used by all three Start paths. Settings gets the button, the picker changes and the read-only key title; the camera screen gets the conflict prompt; the Watch path maps the conflict to a message.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`, `#expect`), YouTube Live Streaming API v3. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-28-match-stream-keys-design.md` (builds on `docs/superpowers/specs/2026-10-28-planned-streams-design.md`). Read both.

## Global Constraints

- No regression in the manual flow: "New stream" + saved template, Save (local only), Start, Stop, auto-stop, Watch Start, signed-out pasted key. The only intended "New stream" change: Start refuses when a planned match or a foreign broadcast waits on the phone key.
- Existing tests keep their **assertions**. Allowed changes: response fixtures that must now answer extra requests or put the planned match on a match key, and tests that encode a removed rule (listed per task). Any other changed assertion is a bug.
- Secret stream keys never appear in UI, journal, diagnostics or errors; use the stream's YouTube title.
- Match key titles: `Tubeist match 1`, `Tubeist match 2`, … (prefix `"Tubeist match "`). Created as reusable HLS streams with the same `cdn`/`contentDetails` body as `performStreamSetup` (`Tubeist/YouTubeService.swift`, `liveStreams?part=snippet,cdn,contentDetails`).
- Tubeist's own broadcast: in this phone's `createdBroadcast` record, **or** `|scheduledStartTime − publishedAt| ≤ 60 s`.
- Persistent ("stream now") broadcasts (`snippet.isDefaultBroadcast == true`) are never matches and never rebound.
- Never rebind a broadcast that is live/testing/complete/revoked, Tubeist's own, or persistent.
- Exact copy (spec): "Another device is already streaming to '<match>'." · "'<match>' shares its key with '<other>'. Give this match its own key?" · "'<other>' is planned on this phone's key and could take over this stream. Move it to its own key?" · "'<other>' is waiting on this key. End or delete it in YouTube Studio, then try again." · "Open Tubeist on the phone to set up '<match>'." · Summary: "12 matches, each with its own key. 3 moved, 9 already set up." · Failure: "Could not give '<match>' its own key: <reason>."
- Follow `YouTubeService` patterns: `checkAuthorization(scope)` after every await, `paginatedItems`, typed `YouTubeAPIOperation` (`.bindBroadcast`, `.createStream`, `.broadcasts`, `.streams` exist), `YouTubeDiagnostics` logging.
- Unit test command: `xcodebuild test -project Tubeist.xcodeproj -scheme Tubeist -destination 'platform=iOS Simulator,id=894A0599-2AF5-49F7-8160-0BC445B4E21E' -only-testing:TubeistTests/<Suite>` (≈3 min for the full `TubeistTests`). Baseline: 674 passed, 2 known failures in `OverlayRecoveryTests` (`initialOverlayScaleIsAppliedBeforeItsFirstSnapshot`, `scaleChangesLiveContentAndSnapshotWithoutReloadingAndSurvivesReload`).

## Review Focus

1. **A crashed phone restarting its own live "New stream" broadcast.** Today Start resumes it; check 2 must not call that "another device". → test in Task 4 (`newStreamStillResumesItsOwnLiveBroadcast`).
2. **Studio match scheduled for "right now" or with missing `publishedAt`.** Missing timestamps must count as *not* Tubeist's (so the match is protected), not crash. → test in Task 1 (`missingTimestampsAreNotTubeistsOwn`).
3. **Two phones pressing Assign at once** → both bind different matches to the same free key; verification pass must move one again. → test in Task 2 (`verificationMovesAMatchThatEndedUpSharingAKey`).
4. **Saved pick from the previous version** whose match sits on the phone key: Settings must still show it picked, and Start must offer the fix rather than fail "unavailable". → tests in Task 3 (`savedPickIsMatchedByBroadcastIdOnly`) and Task 4 (`plannedPickOnThePhoneKeyOffersOwnKey`).
5. **User deleted or renamed match keys in Studio** → numbering continues after the highest remaining number; a renamed key is no longer a match key and its matches get moved. → test in Task 1 (`nextNumberContinuesAfterHighestRemaining`).

---

### Task 1: Match-key rules (pure)

**Files:**
- Create: `Tubeist/MatchKeys.swift`
- Modify: `Tubeist/YouTubeService.swift` (`YouTubeBroadcastResource.Snippet` add `isDefaultBroadcast: Bool?`; `YouTubeBroadcast` add `var isDefaultBroadcast: Bool = false`, mapped in `broadcast`)
- Test: `TubeistTests/MatchKeysTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct MatchKeyStream: Sendable, Equatable { let id: String; let title: String }
  enum MatchKeys {
      static let titlePrefix = "Tubeist match "
      static func isMatchKey(title: String?) -> Bool
      static func title(number: Int) -> String                       // "Tubeist match \(number)"
      static func nextNumber(existingTitles: [String]) -> Int        // max matching number + 1, or 1
      static func isTubeistOwn(_ b: YouTubeBroadcast, remembered: Set<String>) -> Bool
      static func isPlannedMatch(_ b: YouTubeBroadcast, remembered: Set<String>) -> Bool
          // lifeCycleStatus ready|created && !isDefaultBroadcast && !isTubeistOwn
      static func freeKeys(_ streams: [MatchKeyStream], upcoming: [YouTubeBroadcast], active: [YouTubeBroadcast]) -> [MatchKeyStream]
          // match-key titles with no upcoming or active broadcast bound; sorted by number
      static func matchesNeedingOwnKey(upcoming: [YouTubeBroadcast], streams: [MatchKeyStream], remembered: Set<String>) -> [YouTubeBroadcast]
          // planned matches not alone on a match key (alone = no other upcoming broadcast of any kind bound to it)
  }
  ```

- [ ] **Step 1: Write failing tests** in `MatchKeysTests` (Swift Testing, build broadcasts with the `YouTubeBroadcast` memberwise init):
  - `matchKeyTitlesAreRecognisedByPrefix`: `isMatchKey(title: "Tubeist match 3") == true`; `"Tubeist – Jans Duo"`, `"Default stream key"`, `nil` → false.
  - `nextNumberContinuesAfterHighestRemaining`: titles `["Tubeist match 1", "Tubeist match 4", "Court 2"]` → 5; `[]` → 1.
  - `tubeistOwnByRecordOrTenSecondSchedule`: published `T`, scheduled `T+10s` → true; scheduled `T+61s` → false; scheduled `T+3h` but id in `remembered` → true.
  - `missingTimestampsAreNotTubeistsOwn`: `publishedAt == nil` or `scheduledStartTime == nil` → false.
  - `plannedMatchExcludesPersistentLiveAndTubeists`: ready Studio match → true; `isDefaultBroadcast` → false; `live`, `complete` → false; Tubeist's → false; `created` Studio match → true.
  - `freeKeysSkipKeysWithAnyUpcomingOrActiveBroadcast`: three match keys; one bound by an upcoming Tubeist broadcast, one by a live broadcast → only the third is free; non-match-key streams never free.
  - `matchesNeedingOwnKey`: match alone on match key → not listed; two matches sharing a match key → both listed; match on a non-match key (alone) → listed; match with `boundStreamId == nil` → listed; match sharing a match key with a Tubeist broadcast → listed.
- [ ] **Step 2: Run** `-only-testing:TubeistTests/MatchKeysTests` → FAIL (types not defined).
- [ ] **Step 3: Implement** `MatchKeys.swift` and the `isDefaultBroadcast` decoding. Reuse the ISO-8601 parsing in `PlannedStreams` (make its `parse` `static func` internal rather than duplicating).
- [ ] **Step 4: Run** the suite → PASS. Run `PlannedStreamTests` and `YouTubeServiceTests` → still PASS.
- [ ] **Step 5: Commit** `git add Tubeist/MatchKeys.swift Tubeist/YouTubeService.swift Tubeist/PlannedStreams.swift TubeistTests/MatchKeysTests.swift && git commit -m "Add match-key rules"`

### Task 2: Assign match keys (service)

**Files:**
- Modify: `Tubeist/YouTubeService.swift`
- Test: `TubeistTests/YouTubeServiceTests.swift` (new `// MARK: - Match keys` section; use `RoutingYouTubeAPITransport` like `PlannedStartFixture`)

**Interfaces:**
- Consumes: Task 1 `MatchKeys`, `MatchKeyStream`.
- Produces:
  ```swift
  struct MatchKeyAssignmentResult: Sendable, Equatable {
      let total: Int; let moved: Int; let alreadySet: Int
      let failures: [MatchKeyFailure]
      var summary: String   // spec copy; failures appended one per line
  }
  struct MatchKeyFailure: Sendable, Equatable { let title: String; let reason: String }
  extension YouTubeService {
      func assignMatchKeys() async throws -> MatchKeyAssignmentResult
      func moveToOwnMatchKeys(broadcastIDs: [String]) async throws   // throws on first failure; used by Start fixes
  }
  ```
  `remembered` = this phone's `createdBroadcast` IDs across its keys (`discoveryCache`); add `func rememberedCreatedBroadcastIDs(scope:) -> Set<String>` to `YouTubeDiscoveryCache` if no such accessor exists.

Behaviour: list **all** upcoming broadcasts (`broadcastStatus=upcoming&broadcastType=all`, all pages), active broadcasts, and `liveStreams?mine=true` (all pages, `part=snippet,cdn,status`). Compute `matchesNeedingOwnKey`; pair each with a free key in order, creating `Tubeist match N` streams (from `nextNumber`) only when free keys run out; `liveBroadcasts/bind` each (existing request shape in `createOrResumeBroadcast`; verify the response's `boundStreamId`). Then re-list upcoming and re-run `matchesNeedingOwnKey`; a second pass moves anything still listed; whatever remains is a failure with reason "still shares a key". Per-match API errors become `MatchKeyFailure` (reason = `YouTubeDiagnostics.failure(error)`), not a thrown error; sign-in/authorization errors throw.

- [ ] **Step 1: Write failing tests:**
  - `assignMovesSharedAndUnboundMatchesAndKeepsAloneOnes`: upcoming = m1+m2 on Studio default stream, m3 alone on `Tubeist match 1`, m4 unbound; streams include `Tubeist match 1`, `Tubeist match 2` (free) → binds m1→match 2, creates `Tubeist match 3` for m2 and `Tubeist match 4` for m4; result `total 4, moved 3, alreadySet 1`; exactly 2 `POST liveStreams` with titles `"Tubeist match 3"`, `"Tubeist match 4"` and `"ingestionType":"hls"`, `"isReusable":true`.
  - `assignNeverRebindsTubeistsPersistentOrActiveBroadcasts`: upcoming includes a Tubeist-own (scheduled = published + 10 s), a persistent one, and the default list includes a `live` match → no bind request carries their IDs.
  - `verificationMovesAMatchThatEndedUpSharingAKey`: routing returns, on the re-list, m1 and an unexpected m9 both on `Tubeist match 2` → a second bind moves one of them; `failures` empty.
  - `assignReportsPerMatchFailureAndContinues`: bind for m2 returns 403 → `failures == [MatchKeyFailure(title: "m2 title", reason: …)]`, m1 still bound, `summary` contains "Could not give 'm2 title' its own key:".
  - `summaryCopy`: `MatchKeyAssignmentResult(total: 12, moved: 3, alreadySet: 9, failures: []).summary == "12 matches, each with its own key. 3 moved, 9 already set up."`
  - `assignNeverLogsOrReturnsSecretKeys`: no `summary`, failure reason or diagnostics line contains the fixture's `streamName` values.
- [ ] **Step 2: Run** `-only-testing:TubeistTests/YouTubeServiceTests` → new tests FAIL.
- [ ] **Step 3: Implement** `assignMatchKeys`, `moveToOwnMatchKeys`, a private `createMatchKey(number:token:scope:) -> MatchKeyStream` and a private `bind(broadcastID:to streamID:) -> YouTubeBroadcast` (refactor `createOrResumeBroadcast` to call the same bind helper; its behaviour must not change).
- [ ] **Step 4: Run** `YouTubeServiceTests` and `MatchKeysTests` → PASS (all pre-existing tests unchanged).
- [ ] **Step 5: Commit** `git commit -m "Assign each planned match its own stream key"`

### Task 3: Planned list across the channel

**Files:**
- Modify: `Tubeist/PlannedStreams.swift` (`today`), `Tubeist/YouTubeService.swift` (`loadPlannedBroadcasts`, `YouTubePlannedStreams`), `Tubeist/SettingsDraft.swift:148-170` (`applyPlanned` saved-pick matching)
- Test: `TubeistTests/PlannedStreamTests.swift`, `TubeistTests/YouTubeServiceTests.swift`, `TubeistTests/SettingsDraftTests.swift`

**Interfaces:**
- Consumes: `MatchKeys.isPlannedMatch`, `MatchKeys.matchesNeedingOwnKey`.
- Produces:
  - `PlannedStreams.today(_ broadcasts: [YouTubeBroadcast], remembered: Set<String>, now: Date, calendar: Calendar) -> [YouTubeBroadcast]` (keeps the `ready`-only filter and sorting; drops the `streamId` filter; uses `isPlannedMatch`).
  - `YouTubePlannedStreams` gains `let needsOwnKey: Set<String>` (broadcast IDs) and `let keyTitles: [String: String]` (stream ID → title, for read-only and labels). `streamTitle` stays (phone key title).
  - `PlannedStreams.label(for:calendar:needsOwnKey:) -> String` appends `" · shares a key"` when true.

Removed rule (tests updated, called out in the commit message): "the picker lists only broadcasts on this phone's stream" — `plannedListReturnsOnlyTodaysBroadcastsOnThisStreamAndNotTubeistsOwn` becomes `plannedListReturnsTodaysChannelMatchesButNotTubeistsOwn` with `other-stream` now **included**; its other expectations stay.

- [ ] **Step 1: Write/adjust failing tests:**
  - `PlannedStreamTests`: `todayListsMatchesOnAnyKey` (two streams → both listed, sorted by time); `todayExcludesTubeistsOwnByTiming`.
  - `YouTubeServiceTests`: the renamed list test above, plus `plannedListMarksMatchesThatNeedTheirOwnKey` (two matches on one key → both IDs in `needsOwnKey`; a match alone on `Tubeist match 1` → not).
  - `SettingsDraftTests`: `savedPickIsMatchedByBroadcastIdOnly` — a saved pick with `streamId: "stream-1"` whose broadcast is now bound to `"match-7"` is still selected after `applyPlanned`.
- [ ] **Step 2: Run** the three suites → new/renamed tests FAIL.
- [ ] **Step 3: Implement.** `loadPlannedBroadcasts` additionally fetches `liveStreams?mine=true` (titles, all pages) to build `keyTitles` and `needsOwnKey`; it still resolves the phone stream for `streamTitle`. `applyPlanned` matches a saved pick by `broadcastId` only.
- [ ] **Step 4: Run** → PASS; full `TubeistTests` → baseline.
- [ ] **Step 5: Commit** `git commit -m "List today's planned matches on every key"`

### Task 4: Start safety checks

**Files:**
- Modify: `Tubeist/YouTubeAPITransport.swift` (`YouTubeError`), `Tubeist/YouTubeService.swift` (`performStreamingPreparation`, `performPlannedPreparation`)
- Test: `TubeistTests/YouTubeServiceTests.swift`

**Interfaces:**
- Consumes: Task 1 rules, Task 2 `moveToOwnMatchKeys`.
- Produces:
  ```swift
  struct YouTubeKeyConflict: Sendable, Equatable {
      enum Kind: Sendable, Equatable { case plannedNeedsOwnKey, newStreamKeyTaken }
      let kind: Kind
      let matchTitle: String          // the pick, or the phone key's title for New stream
      let otherTitle: String?         // nil when the pick is alone on a non-match key
      let broadcastIDsToMove: [String]
      var prompt: String              // spec copy for the phone
      var watchMessage: String        // "Open Tubeist on the phone to set up '<matchTitle>'."
  }
  // YouTubeError new cases:
  case keyInUse(String)               // "Another device is already streaming to '<title>'."
  case keyConflict(YouTubeKeyConflict) // errorDescription == conflict.prompt
  case keyBlocked(String)             // "'<other>' is waiting on this key. End or delete it in YouTube Studio, then try again."
  ```
  Private `checkKeySafety(streamID:, pick: YouTubeBroadcast?, kind:, remembered:, token:, scope:) async throws` — lists active + upcoming broadcasts bound to `streamID` and the stream's title, then applies checks 2 and 3 in spec order.

Rules:
- **Planned / Restart:** fetch the pick (existing `plannedBroadcast(id:)`), use its **current** `boundStreamId` (not `selection.streamId`), `streamByID` → `hlsEndpoint` (check 1). Check 2: any `live|liveStarting|testing|testStarting` broadcast bound to the key → `keyInUse(pick.title)`. Check 3: the key is not a match key, or another upcoming auto-start broadcast is bound to it → if every other is a planned match: `keyConflict(.plannedNeedsOwnKey, broadcastIDsToMove: [pick.id])`; if any other is Tubeist's own: `keyBlocked(otherTitle)`. Remove the `planned.streamId == stream.id` guard (the removed rule). Restart creates on the ended broadcast's current key and runs checks 2–3 with `pick: nil`.
- **New stream:** after `selectedBroadcast`: an active broadcast on the phone key that is in this phone's record → resume as today (no check 2); any other active one → `keyInUse(phoneKeyTitle)`. Check 3: planned matches bound to the phone key → `keyConflict(.newStreamKeyTaken, broadcastIDsToMove: their IDs)`; a foreign Tubeist broadcast with auto-start on (not in this phone's record) → `keyBlocked`.
- None of these checks writes anything. The fix is only ever `moveToOwnMatchKeys` called by the UI (Task 6).

Fixture changes allowed: `PlannedStartFixture` puts `m5` on `"match-1"` titled `"Tubeist match 1"` and routes `GET liveStreams?id=match-1`; `selection.streamId` stays as saved data. `plannedStartStillRefusesWhileABroadcastIsActive` now expects `keyInUse("Match 5")` (encodes the changed error, assertion intent unchanged: refused, no writes). The `.boundElsewhere` refusal case is **removed** (removed rule) and replaced by `plannedPickFollowsTheMatchToItsNewKey`.

- [ ] **Step 1: Write failing tests:**
  - `plannedPickFollowsTheMatchToItsNewKey`: saved `streamId "stream-1"`, broadcast now on `match-1` → preparation endpoint is `match-1`'s ingestion address.
  - `plannedPickOnThePhoneKeyOffersOwnKey`: m5 alone on the phone stream → throws `keyConflict` with `kind .plannedNeedsOwnKey`, `otherTitle nil`, `broadcastIDsToMove ["m5"]`; no PUT/POST sent.
  - `plannedPickSharingAKeyOffersOwnKey`: m5 + m6 (planned) on `match-1` → `keyConflict`, `otherTitle "Match 6"`, prompt == "'Match 5' shares its key with 'Match 6'. Give this match its own key?".
  - `plannedPickBlockedByATubeistBroadcast`: m5 + a Tubeist-own broadcast on `match-1` → `keyBlocked("Manual stream")`.
  - `plannedPickRefusedWhileAnotherDeviceStreams`: a `live` broadcast on `match-1` → `keyInUse("Match 5")`.
  - `restartRunsTheSameChecksOnTheEndedBroadcastsKey`: Restart with a planned match waiting on the ended broadcast's key → `keyConflict`.
  - `newStreamOffersToMovePlannedMatchesOffThePhoneKey`: the 15:00 scenario — planned "15:00 match" with auto-start on the phone key → `keyConflict(.newStreamKeyTaken)`, prompt == "'15:00 match' is planned on this phone's key and could take over this stream. Move it to its own key?"; no broadcast created.
  - `newStreamStillResumesItsOwnLiveBroadcast`: live broadcast on the phone key whose ID is in this phone's `createdBroadcast` record → resumed exactly as before (same requests as the existing resume test).
  - `newStreamWithACleanKeyIsUnchanged`: existing "New stream" create test's expectations hold with the extra list requests answered.
  - `keyErrorsNeverContainSecretKeys`.
- [ ] **Step 2: Run** `YouTubeServiceTests` → new tests FAIL.
- [ ] **Step 3: Implement** the error cases (copy exactly as in Global Constraints), `YouTubeKeyConflict`, `checkKeySafety`, and the three call sites.
- [ ] **Step 4: Run** `YouTubeServiceTests`, `StreamerTests`, `PlannedStreamTests` → PASS; full `TubeistTests` → baseline. Diff the test file: only the fixture/removed-rule changes listed above touch existing tests.
- [ ] **Step 5: Commit** `git commit -m "Refuse Start on a shared or busy stream key"`

### Task 5: Settings — Assign button, picker, read-only key

**Files:**
- Modify: `Tubeist/Settings.swift` (YouTube Stream Configuration section near the planned picker; `plannedStreamFooter` at ~1348; `loadBroadcastInUse` at ~1637), `Tubeist/SettingsDraft.swift` if labels are built there
- Test: `TubeistTests/SettingsDraftTests.swift`

**Interfaces:**
- Consumes: `assignMatchKeys()`, `YouTubePlannedStreams.needsOwnKey/keyTitles`, `PlannedStreams.label(for:calendar:needsOwnKey:)`.
- Produces: nothing for later tasks.

Behaviour:
- Button **"Assign match keys"** below the picker; shown only when signed in and not read-only; disabled while `youtubeService.isLoading`. Acts immediately (no Save). Shows a progress state, then an alert titled "Match keys" with `result.summary`; then reloads the planned list.
- Picker labels use the "shares a key" marker.
- Footer replaces the "select this phone's stream key" prompt with: "New match in Studio? Press Assign match keys, or Start will offer to set it up."
- Read-only Settings loads the broadcast **in use** by `appState.youtubeBroadcastId` (not by the phone key) and shows a row "Stream key: <key title>".

- [ ] **Step 1: Write failing test** `SettingsDraftTests.plannedLabelsMarkSharedKeys` (draft built from a `YouTubePlannedStreams` with `needsOwnKey: ["m2"]` → m2's label ends with " · shares a key", m1's does not).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `SettingsDraftTests` → PASS; build succeeds.
- [ ] **Step 5: Manual check on the iPhone 17 Pro simulator**: signed-out Settings unchanged; read-only Settings still scrolls (commit `4f5c3fc`).
- [ ] **Step 6: Commit** `git commit -m "Add Assign match keys to Settings"`

### Task 6: Start prompt and Watch message

**Files:**
- Modify: `Tubeist/TubeistView.swift` (Start button handler ~line 930), `Tubeist/WatchSessionManager.swift:222-236`
- Test: `TubeistTests/WatchSessionManagerTests.swift`

**Interfaces:**
- Consumes: `YouTubeError.keyConflict(YouTubeKeyConflict)`, `moveToOwnMatchKeys(broadcastIDs:)`.

Behaviour:
- Phone Start: `catch YouTubeError.keyConflict(let conflict)` → store in `@State pendingKeyConflict`, show a `.confirmationDialog` with `conflict.prompt`, buttons "Give it its own key" (planned) / "Move it" (New stream) and Cancel. Confirm → `Task { try await YouTubeService().moveToOwnMatchKeys(broadcastIDs: conflict.broadcastIDsToMove); try await Streamer.shared.startStream(streamID: Streamer.makeStreamID()) }`; errors fade like today. Cancel → nothing changes. Other errors: unchanged handling.
- Watch Start: in `handleStart`'s catch, `YouTubeError.keyConflict(let c)` → `appState.activeAlert = c.watchMessage`; all other errors unchanged.

- [ ] **Step 1: Write failing test** `WatchSessionManagerTests.keyConflictFromWatchStartAsksForThePhone` (inject a start that throws `.keyConflict` → `activeAlert == "Open Tubeist on the phone to set up 'Match 5'."`). If `handleStart` has no injection point, add a `startStream: (String) async throws -> Void` parameter defaulting to `Streamer.shared.startStream`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** both. **Step 4: Run** `WatchSessionManagerTests` → PASS; full `TubeistTests` → baseline.
- [ ] **Step 5: Commit** `git commit -m "Offer the key fix at Start and explain it on the Watch"`

### Task 7: Device acceptance checklist

**Files:**
- Modify: `PLAN.md` (append a "Match stream keys — device acceptance" section)

- [ ] **Step 1: Write the checklist**, in this order: (1) manual flow on each phone — Save → Start → Stop, Watch Start — with no planned matches; (2) schedule 3 matches in Studio on the default key, press Assign → summary "3 matches, each with its own key. 3 moved, 0 already set up."; Studio shows three `Tubeist match N` keys; (3) pick match 1 on phone A, Start, Stop → only match 1 used; (4) the bug-2 repro: one planned auto-start match left on phone B's key, "New stream" on B → prompt, "Move it", stream goes to B's new broadcast and the match stays upcoming on its own key; (5) phone A streaming match 2, phone B picks match 2 → "Another device is already streaming to 'Match 2'."; (6) new Studio match after Assign, pick it, Start → "shares its key…" prompt → stream lands in it; (7) Watch Start with a conflict → phone shows "Open Tubeist on the phone…"; (8) read-only Settings mid-stream shows "Stream key: Tubeist match N" and scrolls.
- [ ] **Step 2: Commit** `git commit -m "Add match-key device acceptance checklist"`
