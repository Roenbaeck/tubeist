# Planned streams: pick a pre-scheduled YouTube broadcast in Settings

- Date: 2026-10-28
- Status: approved 2026-10-28

## Why

Tubeist is mainly used to stream volleyball. At a tournament weekend there can be
twelve or more matches already scheduled, plus finals whose teams are not yet
known. Between matches there is little time, and typing a title, visibility,
playlist and thumbnail for each one on the phone is slow and error-prone.

Some opposing teams object to public streams. The team's approach is to stream
**unlisted** and add each match to a **playlist** that their own followers have
saved. If a match goes out with the wrong visibility, the wrong title or no
playlist, that approach fails.

So the whole weekend should be planned ahead of time in YouTube Studio. At each
match the operator picks the right planned broadcast in Tubeist, checks it,
optionally edits it, and presses Start.

## Goals

- Plan matches in **YouTube Studio**, each with a title, visibility, playlist,
  thumbnail and expected start time. Tubeist does no planning of its own.
- In Tubeist **Settings**, choose one of **today's** planned broadcasts from a
  drop-down list that shows `HH:mm – Title`, sorted by scheduled time.
- Choosing a planned broadcast loads its details into the existing YouTube
  fields (title, visibility, playlist, thumbnail, and the other existing
  controls). The operator can edit any of them before Start.
- Start goes live on **the chosen broadcast**, whether it starts early or late.
  The scheduled time is only used to filter and sort the list.
- Keep today's behaviour as the explicit default choice, **"New stream"**,
  which uses the saved Tubeist settings.

## Hard requirement: no regression in the manual flow

The existing flow, where everything is set manually in Tubeist Settings and
"New stream" is used, must keep working exactly as it does today. The user
made this an explicit condition of approval.

- With "New stream" selected, the following are unchanged:
  - the Settings fields, their saved values and Save (local only);
  - the Start preflight: create or reuse a Tubeist broadcast, apply the saved
    template, playlist and thumbnail;
  - Stop and auto-stop behaviour;
  - Start from the Watch.
- The only intended difference is that "New stream" no longer takes over a
  broadcast scheduled elsewhere (see Anti-goals).
- Signed-out use and a pasted key on its own are not affected at all.
- Saved settings from the current version load unchanged after the update. No
  migration may reset the user's template, thumbnail or playlist.
- Existing unit tests keep passing unchanged. New tests specifically cover
  "New stream" Start with and without planned broadcasts present on the key.
- Device acceptance includes a full manual-flow stream (Settings → Start →
  Stop, plus a Start from the Watch) before the planned-streams flow is
  tested.

## Non-goals

- Creating or scheduling broadcasts from Tubeist.
- Switching between several stream keys, or showing broadcasts bound to other
  keys. The rule is **one stream key per phone**. When two phones stream on the
  same day (for example two courts), each match is scheduled in Studio against
  the key of the phone that will stream it, and each phone lists only its own.
- Changing the scheduled start time from Tubeist.
- Any of this when the user is not signed in to Google. The picker appears
  only when signed in. A pasted key on its own keeps working as it does today.

## Anti-goals (failure even if it "works")

- **Start must never take over or overwrite a planned broadcast the operator
  did not pick.** Today, Start without a pick chooses the upcoming broadcast
  bound to the key with the *latest* time (`YouTubeBroadcastDiscovery.selectCurrentOrUpcoming`,
  `Tubeist/YouTubeService.swift:400`). It then writes the saved Settings
  template over it (`performStreamingPreparation`, `Tubeist/YouTubeService.swift:948`).
  With twelve planned matches on the key, "New stream" would silently overwrite
  the last match of the weekend. This must not happen.
- Picking a planned match and editing it must not overwrite the saved
  "New stream" template. The reverse also holds.
- A planned broadcast's Studio details must not be overwritten by stale local
  values. Only fields the operator actually changed in Tubeist are sent.
- Start must never silently fall back to a different broadcast if the chosen
  one is no longer available.

## Constraints

- Swift 6, no external dependencies. Follow the existing `YouTubeService`
  patterns: authorization scope checks, `paginatedItems`, `YouTubeDiagnostics`
  logging, and the typed `YouTubeAPIOperation` cases.
- Keep the current Settings model. **Save is local-only.** YouTube is changed
  only during the Start preflight (`Tubeist/Settings.swift:503` footer and
  `YouTubeBroadcastPreferences` doc comment).
- Start can come from the phone or the Apple Watch. Both read the saved
  Settings, so the chosen planned broadcast must live in saved Settings rather
  than in view state.
- Respect API quota. Listing today's broadcasts and their details on opening
  Settings is fine. Calls per playlist should be bounded, given the existing
  50-per-page playlist list.

## Behaviour

### The list

- Shown as the first row of the **YouTube Stream Configuration** section in
  Settings. The label is "Planned stream".
- The first entry is **"New stream"**, which is the default.
- After that come broadcasts that:
  - are bound to this phone's stream (the same stream that Tubeist resolves
    for the stored key today),
  - are upcoming and not complete (`ready`/`created` lifecycle),
  - have a `scheduledStartTime` on today's date in the phone's local time zone.
- Each entry is shown as `HH:mm – Title` (24-hour, local time) and sorted by
  scheduled time.
- A broadcast that is currently **live** on this key is shown and selected
  automatically. This keeps today's resume-a-live-broadcast behaviour.
- Finished matches disappear once YouTube marks them complete.
- Finals: if they're scheduled in Studio once the teams are known, they show
  up when Settings is next opened. Otherwise the operator picks "New stream" and
  types the title.

### Choosing a planned broadcast

- The fields below fill with that broadcast's current YouTube values:
  - title, visibility, made-for-kids, DVR, embedding and latency;
  - **thumbnail**: the broadcast's current thumbnail, as a preview. It is not
    re-uploaded unless the operator picks a new image;
  - **playlist**: the playlist from the user's own list that already contains
    this broadcast, if any. If it is in more than one, the first one found.
- Any edit applies to **this broadcast only**. Save stores the chosen broadcast
  ID plus the operator's changes locally. The saved "New stream" template is
  left alone.
- Switching back to "New stream" shows the saved template again, as today.

### Start with a planned broadcast

- Use the chosen broadcast ID. Do not run automatic selection.
- Check the broadcast still exists, is still bound to this phone's stream, and
  is not complete. If any check fails, Start fails with a clear message, for
  example "The planned stream 'Match 5…' is no longer available. Choose
  another in Settings." It does **not** fall back to another broadcast.
- Send only the changed fields. Upload the thumbnail only if a new one was
  picked. Add the broadcast to the chosen playlist only if it differs from
  the one loaded.
- *My call:* when the operator changes the playlist, or sets it to None,
  Start also **removes** the broadcast from the playlist it was in when loaded.
  This keeps the item ID from the lookup and calls `playlistItems.delete`. As
  with other playlist failures, a failed removal does not block Start, but it
  shows a visible warning in addition to the journal entry, because playlist
  membership is how the team controls who finds the stream.
- *My call:* a saved pick is honoured only on the day it was scheduled. If the
  chosen broadcast's scheduled date is not today, Start fails with the same
  "no longer available, choose another in Settings" message. It does not fall
  back to anything. This also covers a Start from the Watch, where the
  operator can't see Settings.
- Make Start in Tubeist actually go live: auto-start on, monitor stream off,
  and no stream delay. This matches what Tubeist already forces for broadcasts
  it creates. Keep the existing auto-stop and ending-policy handling.
- Leave the scheduled start time unchanged.

### Start with "New stream"

- Resume a live broadcast on this key, as today.
- Otherwise use a broadcast that **Tubeist itself** created and that is still
  `ready`. This keeps today's reuse behaviour. Failing that, create a new one
  from the saved template.
- **Never** pick a broadcast that was scheduled elsewhere, such as a planned
  match. *How* to tell them apart is the builder's call. One option is
  remembering the IDs of broadcasts Tubeist created.

### After a planned stream stops

Any stop ends the YouTube broadcast for good: a deliberate Stop, an upload
failure or a crash. With the normal ending policy, Tubeist completes it, and
YouTube cannot reopen a completed broadcast.

- The selection does **not** go back to "New stream". It becomes a
  **"Restart: <title>"** entry, selected by default, which carries that match's
  details as they were at Start: title, visibility, playlist, made-for-kids,
  DVR, embedding, latency and thumbnail.
- Start with "Restart: …" **creates a new broadcast** from those details,
  forces the same go-live settings as a planned Start, adds it to the
  playlist, and uploads the thumbnail. *Builder's call:* how to carry the
  Studio thumbnail across, either by downloading it at pick time or by
  re-uploading it at restart.
- Choosing another planned match, or "New stream", replaces the Restart entry.
  It is never a silent fallback, and the stale-pick rule still applies: a
  Restart entry from an earlier day fails Start with the "choose another"
  message.
- The worst case after an interruption is therefore an outdated title. It is
  never the wrong visibility or a missing playlist.
- Only one stream runs at a time. The next match is picked after the current
  one stops (see read-only Settings below). No pick can be queued during a
  live stream.

## Read-only Settings while streaming

### Why

Today the gear button does nothing while a stream session is running. It only
dims to yellow (`Tubeist/TubeistView.swift:651`). The operator cannot
double-check during a match which title, visibility, playlist or quality preset
is in use. With planned streams, that check matters more.

### Behaviour

- While a stream session is running, the gear button opens Settings in
  **read-only** mode.
- Every value is visible, but no control can be changed. That covers pickers,
  toggles, text fields, the photo picker, overlay add/remove/reorder, sign-in
  and sign-out, credential removal, and in-app purchases. The only way out is
  Close or swipe-down. There is no Save.
- A short banner at the top explains that settings are locked while streaming
  and can be changed after the stream stops.
- The YouTube section shows the details of the **broadcast actually in use**:
  the planned match picked, or the one "New stream" produced. It should not
  show whatever is in the saved draft.
- *My call:* "Stop YouTube Stream" (the existing button in the YouTube section)
  is hidden in read-only mode. Stopping happens from the main screen as it
  does today.

### Must not disturb the running stream

Opening and closing Settings currently has side effects that are fine when
idle and harmful mid-stream:

- **Camera pipeline.** Opening the sheet sets `isCameraReady = false`, and
  `canPrepareCamera` turns false while Settings is shown
  (`Tubeist/TubeistView.swift:89`, `:1111`).
- **Dismiss handler.** Dismissing reloads all overlays and recreates
  `YouTubeService` and the status bootstrap (`Tubeist/TubeistView.swift:665`).

In read-only mode none of these may interrupt or alter the outgoing stream, the
local recording, overlays, health and viewer polling, or the Live Activity. The
builder must verify this on a device, mid-stream. Opening and closing Settings
several times must produce no stream glitch and no change in the journal.

## Decided by the user

- Planning happens in YouTube Studio. The choice happens in Tubeist.
- The picker goes in Settings, not on the camera screen.
- The list shows only today's planned streams, as "Scheduled time – Name".
- Details can be edited in the normal Tubeist fields after loading.
- One stream key per phone. Multi-key picking is out of scope for now.
- Settings can be opened read-only while streaming, to double-check values.
- After an interruption, a "Restart: <match>" choice recreates the match with
  the same details. The selection does not fall back to "New stream".
- One stream at a time. The next match cannot be picked while one is live.

## Planning in Studio (confirmed by the user)

YouTube Studio lets you choose the stream key for a scheduled stream. It is a
**separate step after creating the scheduled stream**, so it is easy to
forget. A broadcast left on the wrong key, or on none, does not appear in
Tubeist's list.

- *My call:* the picker's footer says: "Don't see a match? In YouTube Studio,
  open it and select this phone's stream key: <key name>". The name is the
  stream's title in YouTube, never the secret key.

## Left to the builder

- The API calls and caching used to list today's broadcasts and to resolve
  each broadcast's playlist.
- How to tell broadcasts Tubeist created apart from ones planned elsewhere.
- The local storage format for the chosen broadcast ID and its edits, and how it
  sits alongside `YouTubeBroadcastPreferences` and the saved thumbnail.
- Loading and error states for the picker, such as a refresh while Settings is
  open.
- Tests: unit tests for today-filtering and sorting (including time zones and
  midnight), for the never-hijack rule, for sending only changed fields, and
  for the unavailable-broadcast error.
