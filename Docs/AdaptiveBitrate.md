# Adaptive YouTube HLS delivery

The selected video bitrate is the ceiling. Presets derive an immutable ladder
at creation/decoding: `maximum × 0.8ⁿ`, rounded to 50 kbps with unique descending
rungs and exact endpoints. The quality floor remains
`min(maximum, max(250 kbps, width × height × fps × 0.015))`. The ladder is not
persisted separately. Audio bitrate is per-channel in Settings and multiplied
by channel count for the controller. Resolution, codec and audio stay fixed.

## Measurements and decisions

All controller times are monotonic. Each successful transaction measures media
bits divided by playlist-plus-segment transaction duration, including retries
and backoff. Queue waiting time is excluded. The uploader remains serial and
starts each transaction as soon as its predecessor completes; there is no
intentional delivery pacing.

The production uploader and transport were checked against a loopback HTTPS
server that paces reads at 1.3-20 Mbps. Samples were 98-100% of the true rate for
segments of 375 KB and larger, 9-33 second uploads included. The first, small
upload, which pays the TLS handshake, read 77-98%. Queued and uploaded bytes are both
MPEG-TS, so backlog and capacity are in the same units. With diagnostics
recording enabled, hashing and saving each body adds a few milliseconds to
the timed transaction, a negligible and conservative bias.

The controller keeps the latest sample and fast/slow EWMAs with 4/20-second time
constants. EWMA weight uses elapsed time between ACKs, capped by the segment's
media duration. A quick burst cannot replace the history instantly; an idle
gap cannot make one measurement dominate it. Recovery evidence is reset after
a long gap, and requires multiple samples spanning real wall-clock time.

Waiting bytes and media duration exclude the active upload. Its actual duration
is used to judge lateness. Two distinct completed uploads taking more than
1.25 times their media duration justify a reduction. A late active upload plus
waiting media can justify a cut before an ACK arrives; total in-flight bytes
/ elapsed time is an optimistic capacity bound, never evidence for an increase.
A cancellable 250 ms watchdog observes only the active transaction, including
when no new fragment or ACK arrives. Four seconds of waiting media bypasses the two-completion confirmation on fresh
capacity evidence. Eight seconds of waiting media bypasses the normal settling
period. Repeated timer polls do not count as completed uploads.

The reduction budget is:

```
C = min(latest throughput, fast EWMA, late in-flight bound if present)
video = (0.85 × C − waitingBits / 6 seconds) / 1.08 − totalAudioBitrate
```

Select the highest fitting rung, allowing multi-rung cuts. Report capacity below
the quality floor if the budget cannot sustain the minimum. Give ordinary cuts
two segment intervals to affect encoded output; do not ratchet down solely
because older, larger segments remain in a shrinking queue. Continued stalls,
further slow completions and emergency queue pressure can still demand cuts.
A lower target does not change bytes already encoded.

## Startup

A stream starts at the quality floor, not the ceiling. Segments encoded before
the first measurement cannot be cut, and late opening segments leave YouTube's
player starting at the live edge, where every later hiccup can show a spinner.
The first segment is encoded before any upload completes, so its rate is a guess;
the floor is the guess that is safe on any link that can sustain the floor.

The encoder asks for the target at its first frame, so the first segment already
uses the floor. Then, for 30 seconds after the first clear completion and until
the first congestion episode or overflow, every fresh clear completion may raise the target
without the wall-clock evidence below. The new rung must fit
`0.9 × latest throughput / 1.08 − audio`, and its wire rate must be at most four
times the media rate of the segment just measured. Small segments understate the
link because each transaction pays two requests, so this converges over a few
segments rather than in one step. It reaches the ceiling within about ten seconds
when the link has room, and stops near what the link sustains otherwise. Each
raise is an ordinary increase for failed-increase rollback. After the window,
normal recovery continues from wherever the ramp stopped.

The cost is about ten seconds below the ceiling at the start of a stream on a
fast link, which also applies to a local recording made with the stream. A
custom preset can turn the startup ramp off in Settings ("Ramp up at stream
start"), for connections known to sustain the selected bitrate; the stream then
starts at the ceiling as before. Built-in presets always ramp, and presets saved
before the option existed decode with it on. The collapse ramp is unaffected. The
ten percent headroom is deliberate: a ceiling within about fifteen percent of
measured transaction throughput stays one rung lower than before, where
uploads previously ran near saturation.

## Recovery

No increase is allowed while work remains. A successful final ACK proves the
queue drained. Only subsequent fresh, clear completions can build evidence.

* **Restore:** remember a rung sustained with 25% capacity headroom for 20 seconds.
  After a congestion episode lasting at most six seconds, return toward that
  rung if it was proven within the last 30 seconds. Require at least three good
  uploads spanning four seconds, fast-EWMA support, and 25% headroom on every
  supporting sample. Multi-rung restoration is allowed. Recurrent congestion
  within 20 seconds disables this path.
* **Explore:** require both EWMAs and every supporting sample to cover the next
  rung with 30% headroom for ten seconds, with at least three completions. Move
  one rung, then collect new evidence.
* **Failed increase:** renewed congestion within 20 seconds rolls back at least
  to the prior rung, invalidates optimistic restoration, and blocks increases
  for 20 seconds. It never blocks reductions.
* **Collapse ramp:** explore alone needs a minute or two to climb back from the
  floor, long after the link has recovered. A congestion episode that cuts to at
  most half the rate it started at arms the startup ramp again, with that
  starting rate as its ceiling. It opens at the first clear completion after the
  episode and stays open, however long the link stays poor, until it reaches that
  ceiling or any congestion ends it. Each raise needs two completions at least
  half a segment apart that both show room. A brief peak or a burst of tiny uploads
  therefore cannot trigger one. It respects the post-overflow increase block. It
  is not armed when the collapse follows a ramp raise within 20 seconds, since
  the ramp overshot, or within 180 seconds of the previous collapse, since the
  link is unstable. Then explore earns the quality back. In simulation, quality
  returns 10-16 seconds after bandwidth does, instead of 98-122. On a link
  collapsing every 30-100 seconds, the one fast recovery costs two extra dropped
  segments over the cautious path.

Normal arrivals do not count as congestion merely because one segment is ready
for its first upload. A stalled active transaction prevents recovery even if
there is no waiting media.

## Overflow and retry

The local waiting queue permits at most ten seconds or 30 fragments (the count
cap protects against unusually short fragments). An arrival that would exceed
it discards older unannounced media and selects the floor. Media duration alone
understates latency when segments were encoded far above capacity, as after a
sudden collapse, or at startup if the ramp is disabled. The queue
therefore also overflows when its bytes, plus the unsent part of the active
upload, would take more than ten seconds at the larger EWMA. While a reduction
is under way, the estimate instead uses the cut's capacity, min(latest, fast
EWMA): after a collapse the slow EWMA still remembers the faster link, and the
segments encoded before the cut are the ones that cannot arrive in time. Waiting
for the duration cap would keep them and discard the smaller, newer media. Steady
state keeps the optimistic estimate, so a brief dip drops nothing. The same estimate
is checked after each ACK, before the next upload is announced, and keeps only
the newest complete segment. It is unknown until the first ACK, so a stalled
first request alone drops nothing. That first sample includes connection setup,
which understates the link; starting at the floor keeps the opening segments
small enough that this rarely matters. Preserve the current
announced/in-flight transaction and its stable retry bytes/filename. After it
finishes, trim again to the newest complete queued segment before resuming.
Signal the gap in both the HLS playlist and MPEG-TS adaptation fields. Preserve
capture timestamps and monotonic playlist sequence numbers. Local recording
retains its own complete encoded output.

Overflow blocks increases for 20 seconds and invalidates proven-quality memory.
It does not reset throughput history. Production transport uses a 10-second
idle request timeout and transient-error backoff; permanent HTTP failures remain
visible. Retries resend the same announced bytes, so a slow but progressing
upload must never time out, or one ceiling segment over a slow link would never
be acknowledged. URLSession's idle timer can expire while a large body is still
draining from the socket buffer. On loopback, 12-16 second uploads failed
reproducibly at 10 seconds while the server was still reading. Each request
therefore gets `max(10 s, 1.5 × body bits / floor wire rate)`, enough for any
segment to finish on a link that can sustain the quality floor. Playlists and
floor-rate segments keep the short dead-connection timeout. The 120-second
resource timeout bounds a whole transfer. Stop enforces its own deadline.

This is a local latency policy, not a claim about YouTube's ingest/playback
buffer. YouTube's five-outstanding-segment playlist limit is separate:
https://developers.google.com/youtube/v3/live/guides/hls-ingestion

## Verification and tuning

Controller tests include an independent continuous-link simulation with 80 ms
transaction overhead, VBR sizes, a full segment of encoder response delay, and
the production observation cadence (arrivals, ACKs and a 250 ms watchdog).
It covers two-second dips at four phases, sustained halving, brief peaks versus
an otherwise identical trace, complete outages, starting at a ceiling five
times the link's capacity, and collapses to a fifth of capacity, either as a
step or as a ramp over four or eight seconds. Full-session simulations run with
both ramps. The startup ramp separately must never delay an opening segment and must
settle at the ceiling or near capacity within fifteen seconds. The collapse ramp
must restore quality within twenty seconds after a twenty-second drop, which the
cautious path cannot do within forty. On links flapping every 15 or 30 seconds,
it may cost at most two extra drops. Unit tests for the slow-path rules disable
both ramps. Target invariants include
bounded backlog, no drops on modest transient/sustained changes, stable settled
quality, and eventual restoration after sustained recovery. Unit tests separately
exercise sample freshness, wall-clock confirmation, rollback, floors and invalid
observations. Sink integration tests cover exact payload ordering, no upload
spacing, duration/count overflow, discontinuities, cancellation and shutdown.

Trend-based variants were evaluated in the same simulation and rejected for now.
These included projecting a declining capacity a segment ahead (overshooting the
cut) and treating consecutive uploads that are slower than real time, and slowing,
as congestion. On slow ramps they cut earlier, but they also fired on noisy links
near the encoded rate and on a two-second dip, and overshot partial declines.
Because restoration deliberately climbs one rung per ten seconds, each false cut
costs far more quality than the latency it saves. On fast collapses the first cut
already reaches the floor; the damage there is media encoded before the cut.

The constants above are initial engineering settings. Live YouTube/device
acceptance should compare maximum queue age, drop count, quality-switch count,
time to drain, and time to restore quality, including request retries and high
motion encoder overshoot. An ACK establishes ingest receipt, not playback health.
