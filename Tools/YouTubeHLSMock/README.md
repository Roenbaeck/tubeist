# YouTube HLS uploader socket validation

`validate_uploader_socket.sh` runs Tubeist's production `URLSession` transport
against a development-only HTTPS server on `127.0.0.1`. A temporary self-signed
certificate is trusted only by the validation executable and is never installed
in a keychain.

The scenarios verify:

- exact POST paths with an unencoded filename after `file=`;
- playlist/segment request order, content types, and body bytes;
- terminal playlist publication with `#EXT-X-ENDLIST` after the final segment;
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
