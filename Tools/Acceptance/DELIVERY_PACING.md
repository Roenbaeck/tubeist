# Delivery timing and acceptance

The former twenty-second delivery pacer has been removed. All ready segments
now upload continuously in order. Rate adaptation reserves capacity by reducing
future encoded media, and waits for a drained queue before increasing quality.

See [adaptive YouTube HLS delivery](../../Docs/AdaptiveBitrate.md) for the current
ladder, estimator, recovery, overflow, and test policy. Acceptance report fields
retain `rate=unpaced`, `pacingReason=workConserving`, and `pacingWait=0` for
compatibility with previously captured sessions.

ACKs prove ingest receipt, not replay completeness. For field acceptance, repeat
the physical-phone countdown with exact-upload diagnostics enabled and compare
accepted media with the local recording and YouTube replay. Check transient dips,
sustained bandwidth changes, and long interruptions separately. Local recording
should remain complete even when the upload queue exceeds its ten-second limit
and resumes with a discontinuity.
