# Delivery pacing: model, safety and verification

## Objective and what is observable

Prefer smooth delivery while removing accumulated local delay within a bounded
recovery episode. Do not sacrifice queue safety or the shutdown budget for that
preference. Pacing changes request timing only; the encoded media, PTS/DTS and
playlist order do not change. Local recordings are independent of upload pacing.

We observe queued media duration/count, monotonic time, completed uploads and
actual request duration. We cannot observe YouTube's playable reserve, processing
speed or future network availability. An HTTP acknowledgement is not confirmation
that the media is in the replay. No causal sender can guarantee both zero loss and
bounded latency/memory through arbitrary outages; no universal optimal upload
rate or safe YouTube burst limit is known.

## Recovery equation

Let Q be queued media seconds beyond the next ready segment, r the delivered
media seconds per wall-clock second, and assume ongoing capture produces 1x.
The fluid approximation is Q' = 1 - r. Clearing Q within T requires an average
rate of at least `r = 1 + Q/T`. This is the minimum constant rate satisfying that
local objective, assuming sufficient capacity and no further interruptions.

At the first observed backlog, set a recovery deadline twenty seconds ahead.
Subsequent decisions use the **time remaining to that same deadline**. Ten
seconds of backlog initially asks for 1.5x. If five seconds remain after ten
seconds, it still asks for 1.5x. If ten seconds remain after fifteen seconds, it
asks for 3x. There is no hard 2x ceiling.

The previous moving twenty-second horizon instead approximated Q' = -Q/20,
which decays exponentially and continually postpones full recovery. A fixed
deadline increases urgency when progress falls short. Reset the episode only
when no excess queue remains. Expiry makes delivery work-conserving (no
intentional wait) until that backlog clears.

Segment quantization, variable durations and request/acknowledgement time mean
this is feedback control, not an exact prediction of completion. The deadline
is an urgency policy, not a promise to clear a queue when capacity is inadequate.
The twenty seconds is a tunable engineering choice, not a YouTube buffer estimate.

## Safety overrides

- Start the first upload immediately. Transfer time consumes the spacing between
  starts, and slow transfers receive no extra sleep. Anchor each interval to the
  actual previous upload start, so an outage does not accrue burst credit.
- A growing queue wakes an existing wait to recalculate the rate.
- Stop pacing at 50 queued seconds or 28 queued fragments: the sixty-second /
  thirty-fragment bounds retain space for two five-second HLS segments. Both
  limits matter; many short segments can hit the count bound first. This margin
  cannot protect against an arbitrarily long in-flight network stall.
- If capacity still cannot drain the queue, the existing overflow policy drops
  whole unadvertised segments to the six-second recovery window. The next upload
  signals discontinuity. Never discard/rename a request already advertised or
  in flight merely to satisfy pacing.
- Stop reserves the final ten-second ACK-to-ENDLIST grace before calculating
  pacing slack. If the remaining queued media would exhaust that slack at real
  time, send without deliberate waits. The overall shutdown deadline still
  bounds network stalls, and failures remain explicit.
- Session replacement and cancellation interrupt sleeps and discard stale
  worker results; waits occur off the UI and capture paths.

Bitrate control uses actual upload time, excluding intentional waits, and shares
the **remaining** recovery horizon. It retains its audio/transport allowance,
user-selected ceiling and quality floor. Lowering future encoding bitrate cannot
shrink already-encoded segments or manufacture bandwidth during an outage.

## Deterministic verification

`HLSDeliveryPacerTests` includes a packet/segment queue simulation with independent
transfer work and media duration, rather than treating byte throughput as media
speed. It covers repeated short connectivity windows, a long outage, a sustained
unrecoverable deficit, variable-duration / variable-bitrate segments, and seeded
changing networks. Each produced segment must be accounted for exactly once as
accepted, deliberately dropped, in flight or queued, with accepted IDs ordered.

The repeated-outage case compares the old hard cap against the new deadline
controller on identical capacity/arrival traces. Sink integration tests separately
exercise request serialization, queue pressure during a sleep, unchanged media
bodies, cancellation, session replacement, overflow discontinuities and Stop.
Uploader tests preserve the final-ACK grace and prevent an early ENDLIST.

These tests establish local behavior for the tested traces, not YouTube replay
completeness. Repeat the physical-phone countdown with exact-upload diagnostics
enabled and compare the accepted media with the local recording and replay.
