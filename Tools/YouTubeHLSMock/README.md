# YouTube HLS uploader socket validation

`validate_uploader_socket.sh` runs Tubeist's production `URLSession` transport
against a development-only HTTPS server on `127.0.0.1`. A temporary self-signed
certificate is trusted only by the validation executable and is never installed
in a keychain.

The scenarios verify:

- exact POST paths with an unencoded filename after `file=`;
- playlist/segment request order, content types, and body bytes;
- final playlist publication with `#EXT-X-ENDLIST` after the final segment;
- reuse of one persistent HTTP/1.1 connection during normal delivery;
- retrying identical bytes on a replacement connection after a socket close;
- request timeout recovery;
- prompt uploader stop and Swift task cancellation without a follow-up request.

Run from any directory:

```sh
Tools/YouTubeHLSMock/validate_uploader_socket.sh
```

The script requires Xcode command-line tools, Python 3, and OpenSSL. Validation
artifacts are written to a unique temporary directory printed by the script.

The uploader normally retains the latest 15 entries in a rolling playlist,
including in the final ENDLIST playlist. Short segments can require a larger
window to preserve three target durations. Only acknowledged entries can be
removed. Compact session filenames and a bounded history keep playlist work
and upload traffic small during long streams. Uploader and sink unit tests
verify sequence continuity through shutdown and the independent limit of five
outstanding segments.
ENDLIST now waits until ten seconds after the last successful media upload.
Unit tests use an injected monotonic clock to check the acknowledgement-based
deadline and cancellation; this socket runner skips sleeping while checking the
same request order. After ENDLIST succeeds, the app observes health and broadcast
status every five seconds. Two consecutive post-ENDLIST `inactive` responses
allow completion of the broadcast selected at Start; 120 seconds is the fallback.
Other stream statuses or failed health lookups reset the consecutive count.
If YouTube has already completed it automatically, the app skips the transition.
This is a shutdown timing heuristic; inactivity does not prove that the final
media was processed.
This socket check verifies delivery to the mock; compare a finished YouTube replay
with the local recording and acceptance report to assess missing footage.
