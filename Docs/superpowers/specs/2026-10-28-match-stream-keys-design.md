# Match stream keys: one YouTube stream key per planned match

- Date: 2026-10-28
- Status: approved 2026-10-28
- Builds on: `docs/superpowers/specs/2026-10-28-planned-streams-design.md`
  (planned streams, read-only Settings). Everything there still applies unless
  this document changes it.

## Why

On 2026-10-28 two planned matches were scheduled in YouTube Studio, 10:40 and
15:00, on the same stream key. The 10:40 match was streamed as a planned pick
and worked. Later a second phone streamed with **"New stream"**. Tubeist did
what it should: it created its own "Manual stream" broadcast and sent video to
the key. But the 15:00 planned broadcast was also bound to that key with
**auto-start** on, and YouTube streamed the video into the 15:00 broadcast
instead. The "Manual stream" broadcast was left upcoming, and the 15:00 match
was used up before it was played.

YouTube does not document which broadcast wins when several auto-start
broadcasts share a stream key, and it was not "the earliest scheduled". So the
app cannot rely on YouTube choosing correctly. The same risk applies to a
planned pick if another auto-start broadcast shares its key.

A stream key is just an address: video sent to key K can only reach broadcasts
bound to K. If each match has **its own key**, YouTube never has to choose.
This is also the model Google describes: one stream per broadcast, reused only
for broadcasts at different times.

The user wants this to be **absolutely solid**: a match must never be streamed
into the wrong broadcast, and a planned match must never be used up by another
stream.

## The user's flow

1. In YouTube Studio, schedule the matches as today: title, visibility,
   playlist, thumbnail, time. **Ignore stream keys.** Studio puts them all on
   its default key; that is fine.
2. In Tubeist Settings on one phone, press **"Assign match keys"**. Tubeist
   gives each planned match its own key and shows a summary.
3. On each phone, per match: pick the match in Settings, Save, Start, exactly
   as today. Tubeist streams to that match's key automatically.

If step 2 is forgotten, or a match is added later, Start catches it (see
"Start safety checks") and offers a one-tap fix.

## Goals

- Every planned match streams into exactly the broadcast that was picked.
- "New stream" can never stream into a planned match, and a planned match can
  never be taken over by "New stream" or by another match.
- Two phones can never stream to the same match at the same time without being
  told (see the residual window under "Start safety checks").
- Any phone can stream any of today's matches. The phone's own key no longer
  decides which matches it can pick.
- Problems (sign-in expired, no network, quota) surface when "Assign match keys"
  is pressed, ahead of the match, not seconds before going live.

## Hard requirement: no regression in the manual flow

Unchanged from the planned-streams design, and it remains the user's explicit
condition:

- "New stream" with the saved template, Save (local only), Start, Stop,
  auto-stop and Watch Start keep working as today.
- Signed-out use with a pasted key is not affected at all.
- Saved settings, including the saved planned pick or Restart entry from the
  current version, load unchanged after the update.
- Existing unit tests keep passing unchanged, except tests that encode the rule
  this design removes ("a planned pick must be bound to this phone's key").
  Those are updated, not deleted, and the change is called out in the plan.

The one intended behaviour change for "New stream": Start refuses when another
upcoming auto-start broadcast is bound to the phone's key (see below), instead
of going live and possibly streaming into it.

## Non-goals

- Planning or scheduling matches from Tubeist. Studio stays the planning tool.
- Changing a match's time, or anything else in Studio, apart from which stream
  key it is bound to.
- Showing or editing secret key values. Keys are referred to by their YouTube
  title only.
- Any of this when signed out.
- Streaming two matches at once from one phone. Still one stream at a time.

## Anti-goals (failure even if it "works")

- Tubeist must never rebind a broadcast that is live, testing or complete, or
  one that is not a planned match (for example a broadcast Tubeist created for
  "New stream").
- "Assign match keys" must never move a match onto a key that another upcoming
  broadcast already uses.
- Start must never silently fix a conflict by itself. A fix is always one
  visible tap with the consequence stated.
- Start must never fall back to another broadcast or another key if the picked
  match or its key is unusable. It fails with a clear message, as today.
- Secret stream keys must never appear in the UI, the journal, diagnostics or
  error messages. Use the stream's title.

## Concepts

- **Phone key**: the key in Settings today (`Settings.streamKey`). After this
  change it is only the key for **"New stream"**. Nothing else about it changes.
  **Each phone has its own phone key** (confirmed by the user: phones do not
  normally share a key). The existing "Set up stream key" action creates one.
- **Match key**: a reusable HLS stream that Tubeist creates for matches, titled
  `Tubeist match 1`, `Tubeist match 2`, and so on. Match keys are never used as a
  phone key.
- **Free match key**: a match key that no upcoming broadcast (`ready` or
  `created`, any date) is bound to, and that is not receiving video.
- **Conflict**: two or more upcoming broadcasts with auto-start on bound to the
  same key. Also a planned match bound to a phone key.

## Behaviour

### "Assign match keys"

- A button in the **YouTube Stream Configuration** section of Settings, under
  the planned-stream picker. Shown only when signed in. Hidden in read-only
  Settings. It acts immediately and does not wait for Save. This is the one
  exception to "Save is local-only", because it is an explicit action with its
  own result, like the existing "Set up stream key" action.
- It covers **all upcoming planned matches** (`ready` or `created`), not only
  today's, so a whole tournament weekend can be prepared once. *My call:* this
  differs from the picker, which shows only today. Cost if wrong: a few extra
  keys and bind calls for matches on later days.
- A planned match is any upcoming broadcast that Tubeist did not create (see
  "Telling Tubeist's broadcasts from Studio matches"). Persistent "stream now"
  broadcasts (`broadcastType` persistent) are never planned matches and are
  never rebound. *My call.*
- For each planned match:
  - already alone on a match key: leave it;
  - otherwise (on the Studio default key, on a phone key, sharing a key, or not
    bound at all): bind it to a free match key, creating a new match key only
    when no free one exists.
- After binding, Tubeist lists the broadcasts again and **verifies** that every
  planned match is alone on a match key. This catches two phones pressing the
  button at the same moment. Any match that fails the check is fixed in a
  second pass; if it still fails, the summary says so.
- The summary names the outcome, for example "12 matches, each with its own
  key. 3 moved, 9 already set up." Failures name the match:
  "Could not give 'Match 5 – Team X' its own key: <reason>."
- Matches that are live, testing or complete are never touched and not counted.

### Telling Tubeist's broadcasts from Studio matches

The existing record of Tubeist-created broadcasts is per phone, so phone B
cannot see a "Manual stream" broadcast that phone A created. Treating it as a
match would let B's Assign rebind it, and B's picker list it.

*My call:* a broadcast counts as **Tubeist's** if it is in this phone's record,
**or** its `scheduledStartTime` is within 60 seconds of its `publishedAt`
(creation time). Tubeist always schedules its own broadcasts 10 seconds after
creating them; Studio matches are scheduled ahead of time. Tubeist's
broadcasts are never listed as matches and never rebound. The "New stream"
create path is not changed. Cost if wrong: a Studio match created to start
"right now" is ignored by Assign and the picker; the operator uses "New
stream" for it.

### The picker

- Lists **today's planned matches on the channel**, whatever key they are
  bound to. Same entries, labels, sorting, "New stream" default, live-match
  auto-selection and Restart entry as today.
- Each entry carries the stream it is bound to, so Start knows where to send
  video.
- A match with a conflict is still listed, with a short marker such as
  "shares a key". Picking it is allowed; Start will offer the fix.
- The footer replaces "select this phone's stream key" with a line about
  "Assign match keys", for example "New match in Studio? Press Assign match keys,
  or Start will offer to set it up."

### Start safety checks

Before going live, in this order, after the existing checks (pick still
exists, still upcoming, scheduled today):

1. **Key is a usable HLS key.** As today. A non-HLS key fails with a clear
   message.
2. **No other device is streaming to this key.** If any broadcast bound to the
   key is live or testing (`live`, `liveStarting`, `testing`, `testStarting`),
   Start fails: "Another device is already streaming to '<match>'." For "New
   stream", the same check on the phone key. *My call:* the check uses the
   broadcasts' lifecycle, not the stream's `streamStatus`, because YouTube can
   report a key as active for a while after ingest stops, which would block
   this phone's own quick Restart. The existing "YouTube is still finishing the
   previous stream" guard keeps covering this phone's own previous broadcast.
3. **No conflict on this key.** A planned pick must sit alone on a **match
   key**. If it shares its key with any other upcoming auto-start broadcast, or
   sits on a key that is not a match key (for example Studio's default key or a
   phone key), Start stops and offers one action. For "New stream", a conflict
   is any planned match bound to the phone key:
   - planned pick: "'<match>' shares its key with '<other>'. Give this match its
     own key?" → binds the picked match to a free match key, then continues
     Start;
   - "New stream": "'<other>' is planned on this phone's key and could take
     over this stream. Move it to its own key?" → binds the conflicting
     match(es) to free match keys, then continues Start.
   - If the other broadcast is Tubeist's (another phone's or a leftover "New
     stream" broadcast), no fix is offered, since Tubeist's broadcasts are never
     rebound: "'<other>' is waiting on this key. End or delete it in YouTube
     Studio, then try again." With one key per phone this should only happen
     if a phone key was copied to a second phone.
   Cancel leaves everything as it was.
4. Then the existing preparation (apply edits, auto-start on, thumbnail,
   playlist) runs as today.

**Source of truth for the key.** Start always reads the picked broadcast's
*current* binding from YouTube and streams to that key. If the match was moved
to another key after it was picked (by Assign or another phone's fix), Start
follows it. It is still the same broadcast, so this is not a fallback.
*My call.* Restart uses the ended broadcast's key as YouTube reports it.

Residual window: check 2 only sees video that has already reached YouTube. Two
phones pressing Start on the same match within a few seconds of each other can
both pass it. *My call:* accept and document this; it requires two operators
picking the same match at the same moment, and a later stream would show the
match already live. Cost if wrong: one match with mixed video for a few
seconds until an operator notices.

### Start from the Watch

The Watch cannot show the conflict prompt. If check 3 fails, Watch Start fails
with "Open Tubeist on the phone to set up '<match>'." Checks 1 and 2 fail as on
the phone.

### Restart

A Restart entry recreates the match on **the same match key** as the ended
broadcast. That key is free once the original is complete. The existing rules
(reuse a still-ready original, never fall back) are unchanged. Checks 2 and 3
run as for a planned pick.

### Read-only Settings

Shows the key of the broadcast actually in use by its title (for example
"Tubeist match 4"), so the operator can confirm where video is going.

## Constraints

- Swift 6, no external dependencies. Follow the existing `YouTubeService`
  patterns: authorization scope checks, `paginatedItems`, `YouTubeDiagnostics`,
  typed `YouTubeAPIOperation` cases (`liveBroadcasts.bind` and
  `liveStreams.insert` already exist).
- **API quota.** Binding and creating streams cost about 50 units each against
  a 10,000-unit daily project quota. Reuse free match keys before creating new
  ones, bind only matches that need it, and do not re-check keys on every
  Settings open beyond what the picker already loads.
- Match keys are created as reusable HLS streams with the same settings as the
  existing "Set up stream key" action.

## Decided by the user

- One stream key per match, assigned by Tubeist (instead of temporarily turning
  off auto-start on other broadcasts).
- Flow: schedule in Studio ignoring keys → "Assign match keys" in Tubeist →
  pick, Save, Start per match on any phone.
- Keep an explicit button rather than only fixing keys silently at Start, so
  problems show up ahead of the match.
- Start refuses a shared key and offers a one-tap "own key" fix.
- "New stream" uses the phone's key, which no planned match may use.
- Each phone has its own phone key; phones do not normally share one.
- The picker lists all of today's matches on the channel, not only those on this
  phone's key.

## Left to the builder

- How match keys are recognised (title prefix, remembered stream IDs, or both)
  and how numbering continues when keys are deleted in Studio.
- The API calls and paging used to list upcoming broadcasts and streams, and to
  read a stream's status for check 2.
- How the conflict prompt is presented (alert or confirmation dialog) and its
  exact wording, within the meaning above.
- Migration of a saved pick from the current version: its `streamId` stays
  valid; only the "must be this phone's stream" check goes away.
- Tests: assignment (already alone, shared, unbound, on a phone key, reuse of a
  free key, verification pass), each Start check for planned, Restart and "New
  stream", never rebinding live/complete/Tubeist-created broadcasts, Watch
  failure message, and secret keys absent from all messages.
