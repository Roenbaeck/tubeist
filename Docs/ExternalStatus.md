# External status on Apple Watch

Tubeist's Watch companion keeps stream controls and health on its first page.
An optional second page displays plain text supplied by the service of your
choice. The Smart Stack Live Activity and iPhone Live Activity layout do not
change. The companion supports watchOS 11 and later.

Enter the complete endpoint address in **Settings → Watch companion → External
status URL**, including its path and any query parameters. Leave it empty to
hide the page and stop fetching. The phone app must be active and streaming or
recording, with the Watch app installed on a paired Watch. The phone fetches and
forwards text through WatchConnectivity; the Watch does not poll the service.
No sport or provider data model is built into either app.

Both HTTP and HTTPS are supported. For an existing Scoreboard server, use its
normal host and port, for example
`http://192.168.1.50:8081/yourusername/api/status`. Replace the address and username
with your own; `localhost` on the iPhone means the iPhone, not your NAS. The server
must be reachable from the phone. A reverse proxy or certificate is not required
for HTTP. If you already serve it over HTTPS, use the final HTTPS endpoint instead.
For a server on your local network, allow Tubeist's Local Network access when iOS
asks. If previously denied, enable it in iPhone Settings → Privacy & Security →
Local Network. This permission applies to local HTTPS servers too.

HTTPS is recommended because it protects the text and URL from observation and
alteration in transit. HTTP sends both in clear text; do not put private tokens
or sensitive status information in an HTTP endpoint. The same content checks and
literal display rules apply with either protocol.

## Endpoint contract

- HTTP or HTTPS GET to the exact configured URL; no path is appended. Redirects are
  rejected. Supply the final address. URLs containing credentials or fragments
  are rejected. HTTPS still uses the system's normal TLS certificate validation;
  the client never accepts an invalid certificate or retries HTTPS over HTTP.
- Return HTTP 200 and `Content-Type: text/plain; charset=utf-8` (omitting the
  charset is also accepted, but the body must still be valid UTF-8).
- At most 4,096 UTF-8 bytes, 500 extended grapheme clusters, and 8 lines. The
  body must contain non-whitespace text. Tabs become spaces; CR/CRLF and Unicode
  line separators become LF; surrounding whitespace is removed.
- Control characters other than newlines and explicit Unicode bidi overrides
  and isolates are rejected. Ordinary Unicode scripts and emoji are supported.
- Text is rendered literally, including markup and URL-looking strings. It is
  never interpreted as HTML, Markdown, a link, a command, or executable code.
- Return an error status when no useful value is available. A successful fetch
  only proves that the endpoint was reached, not that its underlying data is
  recent. The service should make source outages evident in its response.

The phone uses an ephemeral URLSession without cookies, cached responses, or
stored credentials. A request times out after 8 seconds of inactivity and at
most 10 seconds total. The streaming reader cancels responses exceeding the
byte limit, including responses without a Content-Length. Query tokens and
response contents are not logged.

Fetching happens at most once every 5 seconds, with backoff on errors (up to
30 seconds). The relay resets on endpoint changes, session changes, foreground
loss, unpairing, or removal of the Watch app; late responses are discarded.
The Watch shows the last successful text with its receipt age, marks it out of
date after 30 seconds, and exposes refresh failures. Delivery through
WatchConnectivity is opportunistic: it is not a guaranteed real-time transport.
A phone-state heartbeat and Watch-side expiry also prevent stale green stream
health from persisting after the phone stops sending updates.

The existing Start, Stop, and Highlight command channel is separate from this
display data. Starting requires the phone to be active; Tubeist checks that
requirement itself when a Watch command arrives. Stop and Highlight commands
are tied to the session shown on the Watch, so a delayed tap cannot affect a
replacement session.

## Service example

A server can return any short text appropriate to its audience:

```text
Stage 2
Next speaker: Alex
Starting in 3 minutes
```

A sports service can instead format its teams and scores on the server. The
client contract and Watch layout stay the same. The revised Scoreboard PR adds
`http://your-host:8081/<username>/api/status` as one such provider, also available
over HTTPS when the server is behind an HTTPS reverse proxy.

## Transport configuration and verification

The iPhone app declares `NSAllowsArbitraryLoads` so URLSession can reach
user-configured HTTP servers, including arbitrary DNS hostnames. ATS exceptions
are configured in the app's Info.plist, not for an individual request. This is an
app-wide exception; normal HTTPS certificate trust checks still apply, but ATS's
additional transport requirements are relaxed. No certificate-trust override is
installed by the status client.

The `NSExceptionDomains` entries for `youtube.com`, `googleapis.com`, and
`google.com`, including their subdomains, restore full ATS defaults for Tubeist's
stream uploads, API, and sign-in services. Their HTTPS requirements remain in
place; the HTTP allowance is intended for user-configured services.

Do not combine this key with `NSAllowsArbitraryLoadsInWebContent`,
`NSAllowsArbitraryLoadsForMedia`, or `NSAllowsLocalNetworking`: their presence,
even with a false value, causes iOS to ignore `NSAllowsArbitraryLoads`. The broader
exception also preserves HTTP support for existing overlays. Apple requires an
App Review justification for this setting: Tubeist connects to user-selected
overlay and plain-text status servers that may only provide HTTP and whose
hostnames are not known when the app is built. See Apple's
[NSAllowsArbitraryLoads documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads).

`ExternalStatusTests` checks both URL schemes, the built app's ATS settings, and
rejection of invalid responses. To run its optional `liveServiceReturnsExpectedText`
integration test, set `TUBEIST_STATUS_TEST_URL` to a reachable service endpoint and
`TUBEIST_STATUS_TEST_TEXT` to its exact expected display text (including newlines)
in the test process environment. This uses the real URLSession without a mocked
response. Test against an HTTP Scoreboard endpoint and its current saved overlay;
the test only reads the endpoint and does not update the score.

No new background mode or remote-code capability is used. This design displays
remote content through standard URLSession and WatchConnectivity APIs; normal
App Review requirements for content, privacy, and background execution still
apply. Test delivery, launch from the Smart Stack, and controls on a paired
physical iPhone and Watch before release.

Apple documents the companion launch configuration in
[Launching your app from a Live Activity](https://developer.apple.com/documentation/activitykit/launching-your-app-from-a-live-activity)
and the array-valued
[WKSupportsLiveActivityLaunchAttributeTypes key](https://developer.apple.com/documentation/bundleresources/information-property-list/wksupportsliveactivitylaunchattributetypes).
