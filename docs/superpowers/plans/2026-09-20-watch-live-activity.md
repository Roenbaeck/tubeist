# Watch Live Activity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show live YouTube stream status on the Apple Watch (via an iOS Live Activity) with a configurable detail level, and alert on Bad / No Data health.

**Architecture:** A `TubeistLiveActivity` widget extension renders a Live Activity that watchOS 11+ mirrors to the Smart Stack. The running Tubeist app drives it locally through ActivityKit (no backend, no APNs). Pure, unit-tested logic (`StreamActivityPolicy`) decides what to show and when to alert; a thin `@MainActor` controller talks to ActivityKit and notifications; a coordinator polls YouTube and feeds snapshots in.

**Tech Stack:** Swift 6, SwiftUI, ActivityKit, WidgetKit, UserNotifications, Swift Testing (`import Testing`), YouTube Data API v3 (existing `YouTubeService`).

**Spec:** `docs/superpowers/specs/2026-09-20-watch-live-activity-design.md`

## Global Constraints

- Base commit `5e2d440`; all work on branch `feature/watch-live-activity`. Never commit to `main`, never push.
- Swift 6 (`SWIFT_VERSION = 6.0`), iOS deployment target 18.0 (app) / 18.0 (extension). No new third-party dependencies.
- Project uses Xcode synchronized folders (`objectVersion 77`): new files under `Tubeist/` and `TubeistTests/` join their targets automatically; do not hand-edit file lists in `project.pbxproj` for them.
- Nothing may block or disturb the media pipeline: all new work is off the pipeline and failures are logged with `LOG(...)`, never thrown into streaming.
- Update throttle 5 s; health poll 30 s; viewer poll 60 s (Full only); stale after 60 s; heartbeat push after 60 s; alert debounce 10 s; alert cooldown 60 s; Live Activity restart after 7.5 h. (The plan originally said 15 s / 30 s; the final review halved the polling cost in quota.)
- Settings keys (UserDefaults): `LiveActivityDetail` (`off|standard|full`, default `standard`), `AlertOnBadHealth` (default `true`), `AlertOnRecovery` (default `false`).
- Do NOT touch the author's local signing tweaks (they are stashed in `stash@{0}`; leave the stash alone).
- Every commit message ends with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.
- Build/test with signing disabled: `CODE_SIGNING_ALLOWED=NO`. The Xcode simulator name must be looked up with `xcrun simctl list devices available` (referred to below as `$SIM`, e.g. `platform=iOS Simulator,name=iPhone 17`).

## File Structure

| File | Responsibility |
|------|----------------|
| `Tubeist/StreamActivityAttributes.swift` (moves to `Shared/` in Task 4) | Shared ActivityKit types: `StreamActivityAttributes`, `ContentState`, `YouTubeStreamHealth`, `LinkQuality`, `ThermalLevel`, `StreamPhase` |
| `Tubeist/StreamActivityPolicy.swift` | Pure logic: `LiveActivityDetail`, `StreamSnapshot`, `StreamAlert`, `StreamActivityPolicy` |
| `Tubeist/StreamActivityController.swift` | ActivityKit wrapper + local-notification fallback |
| `Tubeist/StreamActivityCoordinator.swift` | Polls YouTube / device metrics, builds snapshots, drives policy + controller |
| `Tubeist/YouTubeService.swift` | + `fetchStreamHealth`, `fetchConcurrentViewers`, resources, operations |
| `Tubeist/Settings.swift` | + three settings and their UI section |
| `TubeistLiveActivity/` | Widget extension (bundle, Live Activity views) |
| `TubeistTests/StreamActivityPolicyTests.swift` | Policy unit tests |
| `TubeistTests/YouTubeServiceTests.swift` | + health/viewer fetch tests (uses the file's private mocks) |

---

### Task 1: Shared types and pure policy (with tests)

**Files:**
- Create: `Tubeist/StreamActivityAttributes.swift`
- Create: `Tubeist/StreamActivityPolicy.swift`
- Test: `TubeistTests/StreamActivityPolicyTests.swift`

**Interfaces:**
- Produces (used by every later task):
  - `enum YouTubeStreamHealth: String, Codable, Sendable { case good, ok, bad, noData, unknown; init(apiValue: String?); var isAlarming: Bool }`
  - `enum LinkQuality: String, Codable, Sendable { case unknown, good, degraded, poor }`
  - `enum ThermalLevel: String, Codable, Sendable { case nominal, fair, serious, critical }`
  - `enum StreamPhase: String, Codable, Sendable { case connecting, live, stopping, ended }`
  - `struct StreamActivityAttributes: ActivityAttributes { var startedAt: Date; struct ContentState: Codable, Hashable { phase, health, isStale, warning, viewers, bitrateKbps, link, thermal, batteryPercent } }`
  - `enum LiveActivityDetail: String, CaseIterable, Sendable { case off, standard, full }`
  - `struct StreamSnapshot: Equatable, Sendable`
  - `enum StreamAlert: Equatable, Sendable { case degraded(YouTubeStreamHealth), recovered; var title: String; var body: String }`
  - `struct StreamActivityPolicy { init(detail:alertOnBad:alertOnRecovery:); mutating func evaluate(_ snapshot: StreamSnapshot, now: Date) -> Decision; struct Decision: Equatable { var content: StreamActivityAttributes.ContentState?; var alert: StreamAlert? } }`

- [ ] **Step 1: Create the shared types**

Create `Tubeist/StreamActivityAttributes.swift`:

```swift
//
//  StreamActivityAttributes.swift
//  Tubeist
//
//  Types shared by the app and the TubeistLiveActivity widget extension.
//  Keep this file free of app-only dependencies.
//

import ActivityKit
import Foundation

enum YouTubeStreamHealth: String, Codable, Sendable {
    case good, ok, bad, noData, unknown

    /// Maps YouTube's `status.healthStatus.status` value.
    init(apiValue: String?) {
        switch apiValue {
        case "good": self = .good
        case "ok": self = .ok
        case "bad": self = .bad
        case "noData": self = .noData
        default: self = .unknown
        }
    }

    var isAlarming: Bool { self == .bad || self == .noData }

    var label: String {
        switch self {
        case .good: "Good"
        case .ok: "OK"
        case .bad: "Bad"
        case .noData: "No data"
        case .unknown: "Unknown"
        }
    }
}

enum LinkQuality: String, Codable, Sendable {
    case unknown, good, degraded, poor
}

enum ThermalLevel: String, Codable, Sendable {
    case nominal, fair, serious, critical
}

enum StreamPhase: String, Codable, Sendable {
    case connecting, live, stopping, ended
}

struct StreamActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: StreamPhase
        var health: YouTubeStreamHealth
        /// True when the health value is older than the stale threshold.
        var isStale: Bool
        var warning: String?
        // Full detail only; nil means "do not show".
        var viewers: Int?
        var bitrateKbps: Int?
        var link: LinkQuality?
        var thermal: ThermalLevel?
        var batteryPercent: Int?
    }

    /// When the stream went live; drives the elapsed-time timer.
    var startedAt: Date
}
```

- [ ] **Step 2: Write the failing policy tests**

Create `TubeistTests/StreamActivityPolicyTests.swift`:

```swift
//
//  StreamActivityPolicyTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct StreamActivityPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(
        health: YouTubeStreamHealth = .good,
        healthAge: TimeInterval? = 0,
        at now: Date,
        phase: StreamPhase = .live,
        viewers: Int? = 42
    ) -> StreamSnapshot {
        StreamSnapshot(
            phase: phase,
            youtubeHealth: health,
            healthUpdatedAt: healthAge.map { now.addingTimeInterval(-$0) },
            viewers: viewers,
            bitrateKbps: 6000,
            link: .good,
            thermal: .nominal,
            batteryPercent: 80,
            warning: nil
        )
    }

    private func policy(
        detail: LiveActivityDetail = .standard,
        alertOnBad: Bool = true,
        alertOnRecovery: Bool = false
    ) -> StreamActivityPolicy {
        StreamActivityPolicy(detail: detail, alertOnBad: alertOnBad, alertOnRecovery: alertOnRecovery)
    }

    @Test func healthMapsApiValues() {
        #expect(YouTubeStreamHealth(apiValue: "good") == .good)
        #expect(YouTubeStreamHealth(apiValue: "ok") == .ok)
        #expect(YouTubeStreamHealth(apiValue: "bad") == .bad)
        #expect(YouTubeStreamHealth(apiValue: "noData") == .noData)
        #expect(YouTubeStreamHealth(apiValue: "revoked") == .unknown)
        #expect(YouTubeStreamHealth(apiValue: nil) == .unknown)
    }

    @Test func standardOmitsFullFieldsAndFullIncludesThem() {
        var standard = policy(detail: .standard)
        var full = policy(detail: .full)

        let s = standard.evaluate(snapshot(at: t0), now: t0).content
        let f = full.evaluate(snapshot(at: t0), now: t0).content

        #expect(s?.health == .good)
        #expect(s?.viewers == nil)
        #expect(s?.bitrateKbps == nil)
        #expect(s?.batteryPercent == nil)
        #expect(f?.viewers == 42)
        #expect(f?.bitrateKbps == 6000)
        #expect(f?.thermal == .nominal)
        #expect(f?.batteryPercent == 80)
        #expect(f?.link == .good)
    }

    @Test func offProducesNoContentButStillAlerts() {
        var p = policy(detail: .off)
        _ = p.evaluate(snapshot(health: .bad, at: t0), now: t0)
        let later = t0.addingTimeInterval(10)
        let decision = p.evaluate(snapshot(health: .bad, at: later), now: later)

        #expect(decision.content == nil)
        #expect(decision.alert == .degraded(.bad))
    }

    @Test func updatesAreThrottledToFiveSeconds() {
        var p = policy(detail: .full)
        #expect(p.evaluate(snapshot(at: t0, viewers: 1), now: t0).content != nil)

        let t2 = t0.addingTimeInterval(2)
        #expect(p.evaluate(snapshot(at: t2, viewers: 2), now: t2).content == nil)

        let t5 = t0.addingTimeInterval(5)
        #expect(p.evaluate(snapshot(at: t5, viewers: 3), now: t5).content?.viewers == 3)
    }

    @Test func phaseChangeBypassesThrottle() {
        var p = policy()
        _ = p.evaluate(snapshot(at: t0, phase: .connecting), now: t0)
        let t1 = t0.addingTimeInterval(1)
        #expect(p.evaluate(snapshot(at: t1, phase: .live), now: t1).content?.phase == .live)
    }

    @Test func badHealthAlertsOnlyAfterDebounce() {
        var p = policy()
        #expect(p.evaluate(snapshot(health: .bad, at: t0), now: t0).alert == nil)
        let t9 = t0.addingTimeInterval(9)
        #expect(p.evaluate(snapshot(health: .bad, at: t9), now: t9).alert == nil)
        let t10 = t0.addingTimeInterval(10)
        let decision = p.evaluate(snapshot(health: .bad, at: t10), now: t10)
        #expect(decision.alert == .degraded(.bad))
        #expect(decision.content?.health == .bad)  // alert forces a content push
    }

    @Test func shortBlipDoesNotAlert() {
        var p = policy()
        _ = p.evaluate(snapshot(health: .bad, at: t0), now: t0)
        let t5 = t0.addingTimeInterval(5)
        _ = p.evaluate(snapshot(health: .good, at: t5), now: t5)
        let t20 = t0.addingTimeInterval(20)
        #expect(p.evaluate(snapshot(health: .bad, at: t20), now: t20).alert == nil)
        let t30 = t0.addingTimeInterval(30)
        #expect(p.evaluate(snapshot(health: .bad, at: t30), now: t30).alert == .degraded(.bad))
    }

    @Test func sustainedBadAlertsOnce() {
        var p = policy()
        _ = p.evaluate(snapshot(health: .noData, at: t0), now: t0)
        let t10 = t0.addingTimeInterval(10)
        #expect(p.evaluate(snapshot(health: .noData, at: t10), now: t10).alert == .degraded(.noData))
        for offset in [15.0, 60, 300] {
            let t = t0.addingTimeInterval(offset)
            #expect(p.evaluate(snapshot(health: .noData, at: t), now: t).alert == nil)
        }
    }

    @Test func cooldownDelaysRepeatAlerts() {
        var p = policy()
        _ = p.evaluate(snapshot(health: .bad, at: t0), now: t0)
        let t10 = t0.addingTimeInterval(10)
        #expect(p.evaluate(snapshot(health: .bad, at: t10), now: t10).alert != nil)
        let t12 = t0.addingTimeInterval(12)
        _ = p.evaluate(snapshot(health: .good, at: t12), now: t12)
        let t15 = t0.addingTimeInterval(15)
        _ = p.evaluate(snapshot(health: .bad, at: t15), now: t15)
        let t26 = t0.addingTimeInterval(26)  // debounce met, cooldown (60 s from t10) not
        #expect(p.evaluate(snapshot(health: .bad, at: t26), now: t26).alert == nil)
        let t70 = t0.addingTimeInterval(70)
        #expect(p.evaluate(snapshot(health: .bad, at: t70), now: t70).alert == .degraded(.bad))
    }

    @Test func recoveryAlertOnlyWhenEnabled() {
        for enabled in [false, true] {
            var p = policy(alertOnRecovery: enabled)
            _ = p.evaluate(snapshot(health: .bad, at: t0), now: t0)
            let t10 = t0.addingTimeInterval(10)
            _ = p.evaluate(snapshot(health: .bad, at: t10), now: t10)
            let t20 = t0.addingTimeInterval(20)
            let decision = p.evaluate(snapshot(health: .good, at: t20), now: t20)
            #expect((decision.alert == .recovered) == enabled)
        }
    }

    @Test func alertsCanBeDisabled() {
        var p = policy(alertOnBad: false)
        _ = p.evaluate(snapshot(health: .bad, at: t0), now: t0)
        let t60 = t0.addingTimeInterval(60)
        #expect(p.evaluate(snapshot(health: .bad, at: t60), now: t60).alert == nil)
    }

    @Test func staleHealthIsFlaggedAndNeverAlerts() {
        var p = policy()
        let stale = snapshot(health: .bad, healthAge: 120, at: t0)
        #expect(p.evaluate(stale, now: t0).content?.isStale == true)
        let t30 = t0.addingTimeInterval(30)
        #expect(p.evaluate(snapshot(health: .bad, healthAge: 150, at: t30), now: t30).alert == nil)
    }

    @Test func missingHealthTimestampCountsAsStale() {
        var p = policy()
        let decision = p.evaluate(snapshot(healthAge: nil, at: t0), now: t0)
        #expect(decision.content?.isStale == true)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run (first command only if `$SIM` is unknown):
```bash
xcrun simctl list devices available | grep -i iphone | head -3
cd <repo-root>
xcodebuild test -project Tubeist.xcodeproj -scheme Tubeist -destination "$SIM" \
  -only-testing:TubeistTests/StreamActivityPolicyTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Expected: build FAILS with "cannot find 'StreamSnapshot' / 'StreamActivityPolicy' in scope".

- [ ] **Step 4: Implement the policy**

Create `Tubeist/StreamActivityPolicy.swift`:

```swift
//
//  StreamActivityPolicy.swift
//  Tubeist
//
//  Pure decision logic for the watch Live Activity: which fields to show for a
//  detail level, update throttling, stale detection and the Bad/NoData alert
//  state machine. No ActivityKit or UIKit dependencies, so it is unit-tested.
//

import Foundation

enum LiveActivityDetail: String, CaseIterable, Sendable {
    case off, standard, full

    var label: String {
        switch self {
        case .off: "Off"
        case .standard: "Standard"
        case .full: "Full"
        }
    }
}

struct StreamSnapshot: Equatable, Sendable {
    var phase: StreamPhase
    var youtubeHealth: YouTubeStreamHealth
    /// When `youtubeHealth` was last fetched successfully; nil = never.
    var healthUpdatedAt: Date?
    var viewers: Int?
    var bitrateKbps: Int?
    var link: LinkQuality
    var thermal: ThermalLevel
    var batteryPercent: Int?
    var warning: String?
}

enum StreamAlert: Equatable, Sendable {
    case degraded(YouTubeStreamHealth)
    case recovered

    var title: String {
        switch self {
        case .degraded(let health): "Stream health: \(health.label)"
        case .recovered: "Stream health recovered"
        }
    }

    var body: String {
        switch self {
        case .degraded(.noData): "YouTube is receiving no data from your stream."
        case .degraded: "YouTube reports problems with your stream."
        case .recovered: "YouTube reports your stream is healthy again."
        }
    }
}

struct StreamActivityPolicy {
    static let updateInterval: TimeInterval = 5
    static let staleAfter: TimeInterval = 60
    static let alertDebounce: TimeInterval = 10
    static let alertCooldown: TimeInterval = 60

    struct Decision: Equatable {
        /// nil = do not touch the Live Activity (off, or throttled).
        var content: StreamActivityAttributes.ContentState?
        var alert: StreamAlert?
    }

    var detail: LiveActivityDetail
    var alertOnBad: Bool
    var alertOnRecovery: Bool

    private var lastPushed: StreamActivityAttributes.ContentState?
    private var lastPushedAt: Date?
    private var badSince: Date?
    private var alertActive = false
    private var lastAlertAt: Date?

    init(detail: LiveActivityDetail, alertOnBad: Bool, alertOnRecovery: Bool) {
        self.detail = detail
        self.alertOnBad = alertOnBad
        self.alertOnRecovery = alertOnRecovery
    }

    mutating func evaluate(_ snapshot: StreamSnapshot, now: Date) -> Decision {
        let stale = snapshot.healthUpdatedAt
            .map { now.timeIntervalSince($0) > Self.staleAfter } ?? true
        let alert = nextAlert(health: snapshot.youtubeHealth, stale: stale, now: now)

        var content: StreamActivityAttributes.ContentState?
        if detail != .off {
            let candidate = makeContent(snapshot, stale: stale)
            let phaseChanged = candidate.phase != lastPushed?.phase
            let due = lastPushedAt.map { now.timeIntervalSince($0) >= Self.updateInterval } ?? true
            let changed = candidate != lastPushed
            if (changed && (due || phaseChanged)) || alert != nil {
                content = candidate
                lastPushed = candidate
                lastPushedAt = now
            }
        }
        return Decision(content: content, alert: alert)
    }

    private func makeContent(
        _ snapshot: StreamSnapshot,
        stale: Bool
    ) -> StreamActivityAttributes.ContentState {
        let full = detail == .full
        return StreamActivityAttributes.ContentState(
            phase: snapshot.phase,
            health: snapshot.youtubeHealth,
            isStale: stale,
            warning: snapshot.warning,
            viewers: full ? snapshot.viewers : nil,
            bitrateKbps: full ? snapshot.bitrateKbps : nil,
            link: full ? snapshot.link : nil,
            thermal: full ? snapshot.thermal : nil,
            batteryPercent: full ? snapshot.batteryPercent : nil
        )
    }

    private mutating func nextAlert(
        health: YouTubeStreamHealth,
        stale: Bool,
        now: Date
    ) -> StreamAlert? {
        guard !stale else { return nil }

        if health.isAlarming {
            guard alertOnBad else { return nil }
            let since = badSince ?? now
            badSince = since
            guard !alertActive,
                  now.timeIntervalSince(since) >= Self.alertDebounce else { return nil }
            if let last = lastAlertAt, now.timeIntervalSince(last) < Self.alertCooldown {
                return nil
            }
            alertActive = true
            lastAlertAt = now
            return .degraded(health)
        }

        badSince = nil
        guard alertActive, health != .unknown else { return nil }
        alertActive = false
        return alertOnRecovery ? .recovered : nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run the same `xcodebuild test` command as Step 3.
Expected: `** TEST SUCCEEDED **`, all `StreamActivityPolicyTests` pass. If a test fails, fix the implementation (not the test) unless the test contradicts the spec.

- [ ] **Step 6: Commit**

```bash
cd <repo-root>
git add Tubeist/StreamActivityAttributes.swift Tubeist/StreamActivityPolicy.swift TubeistTests/StreamActivityPolicyTests.swift
git commit -m "Add Live Activity types and pure alert/throttle policy

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: YouTube stream health and viewer fetches

**Files:**
- Modify: `Tubeist/YouTubeAPITransport.swift` (`YouTubeAPIOperation`, ~line 49-66)
- Modify: `Tubeist/YouTubeService.swift` (resources near line 158; fetch methods after `fetchBroadcastStatus`, ~line 1005)
- Test: `TubeistTests/YouTubeServiceTests.swift` (append at end of file, before the private helper declarations is fine; the helpers are file-private)

**Interfaces:**
- Consumes: `YouTubeStreamHealth(apiValue:)` from Task 1; existing `apiGet`, `getValidAccessToken`.
- Produces:
  - `func fetchStreamHealth(streamId: String) async throws -> YouTubeStreamHealth` (returns `.unknown` when the stream is not found)
  - `func fetchConcurrentViewers(videoId: String) async throws -> Int?` (nil when YouTube does not report a count)

- [ ] **Step 1: Write the failing tests**

Append to `TubeistTests/YouTubeServiceTests.swift` (file end):

```swift
struct YouTubeStreamHealthFetchTests {
    @Test @MainActor
    func streamHealthDecodesEveryStatusAndQueriesStatusPart() async throws {
        let statuses = ["good", "ok", "bad", "noData"]
        let responses = statuses.map { status in
            YouTubeAPIResponse(
                data: Data(#"{"items":[{"id":"s1","status":{"streamStatus":"active","healthStatus":{"status":"\#(status)"}}}]}"#.utf8),
                statusCode: 200
            )
        }
        let transport = MockYouTubeAPITransport(responses: responses)
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore())

        var results: [YouTubeStreamHealth] = []
        for _ in statuses {
            results.append(try await service.fetchStreamHealth(streamId: "s1"))
        }

        #expect(results == [.good, .ok, .bad, .noData])
        let request = try #require(await transport.requests.first)
        let components = try #require(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false))
        #expect(components.path.hasSuffix("/liveStreams"))
        #expect(components.queryItems?.contains(URLQueryItem(name: "part", value: "status")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "id", value: "s1")) == true)
    }

    @Test @MainActor
    func streamHealthIsUnknownWhenStreamOrStatusMissing() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data(#"{"items":[]}"#.utf8), statusCode: 200),
            YouTubeAPIResponse(data: Data(#"{"items":[{"id":"s1","status":{"streamStatus":"inactive"}}]}"#.utf8), statusCode: 200),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore())

        #expect(try await service.fetchStreamHealth(streamId: "s1") == .unknown)
        #expect(try await service.fetchStreamHealth(streamId: "s1") == .unknown)
    }

    @Test @MainActor
    func concurrentViewersParsesStringCountAndHandlesAbsence() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data(#"{"items":[{"id":"b1","liveStreamingDetails":{"concurrentViewers":"1234"}}]}"#.utf8), statusCode: 200),
            YouTubeAPIResponse(data: Data(#"{"items":[{"id":"b1","liveStreamingDetails":{}}]}"#.utf8), statusCode: 200),
            YouTubeAPIResponse(data: Data(#"{"items":[]}"#.utf8), statusCode: 200),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore())

        #expect(try await service.fetchConcurrentViewers(videoId: "b1") == 1234)
        #expect(try await service.fetchConcurrentViewers(videoId: "b1") == nil)
        #expect(try await service.fetchConcurrentViewers(videoId: "b1") == nil)

        let request = try #require(await transport.requests.first)
        let components = try #require(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false))
        #expect(components.path.hasSuffix("/videos"))
        #expect(components.queryItems?.contains(URLQueryItem(name: "part", value: "liveStreamingDetails")) == true)
    }

    @Test @MainActor
    func quotaErrorSurfacesAsApiError() async throws {
        let transport = MockYouTubeAPITransport(responses: [
            YouTubeAPIResponse(data: Data(#"{"error":{"message":"quota exceeded"}}"#.utf8), statusCode: 403),
        ])
        let service = YouTubeService(transport: transport, tokenStore: validMemoryTokenStore())

        do {
            _ = try await service.fetchStreamHealth(streamId: "s1")
            Issue.record("Expected quota error")
        } catch let error as YouTubeError {
            #expect(error == .apiError(403, "quota exceeded"))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Tubeist.xcodeproj -scheme Tubeist -destination "$SIM" \
  -only-testing:TubeistTests/YouTubeStreamHealthFetchTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Expected: build FAILS ("value of type 'YouTubeService' has no member 'fetchStreamHealth'").

- [ ] **Step 3: Add operations**

In `Tubeist/YouTubeAPITransport.swift`, add two cases after `case broadcastStatus` and make them log at debug on success:

```swift
    case streamHealth = "liveStreams.list (health)"
    case videoLiveDetails = "videos.list (liveStreamingDetails)"

    var successLevel: LogLevel {
        (self == .broadcastStatus || self == .streamHealth || self == .videoLiveDetails) ? .debug : .info
    }
```
(Replace the existing one-line `successLevel`.)

- [ ] **Step 4: Add resources and fetch methods**

In `Tubeist/YouTubeService.swift`, after `YouTubeLiveStreamResource` add:

```swift
struct YouTubeStreamHealthResource: Decodable, Sendable {
    struct Status: Decodable, Sendable {
        struct Health: Decodable, Sendable { let status: String? }
        let streamStatus: String?
        let healthStatus: Health?
    }
    let id: String?
    let status: Status?
}

struct YouTubeVideoLiveDetailsResource: Decodable, Sendable {
    struct Details: Decodable, Sendable {
        /// YouTube returns this as a JSON string; absent until viewers are counted.
        let concurrentViewers: String?
    }
    let id: String?
    let liveStreamingDetails: Details?
}
```

After `fetchBroadcastStatus` add:

```swift
    // MARK: - YouTube API: Stream Health and Viewers (lightweight, 1 unit each)

    func fetchStreamHealth(streamId: String) async throws -> YouTubeStreamHealth {
        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/liveStreams?part=status&id=\(streamId)"
        let response: YouTubeListResponse<YouTubeStreamHealthResource> = try await apiGet(
            url: url,
            token: token,
            operation: .streamHealth
        )
        return YouTubeStreamHealth(apiValue: response.items.first?.status?.healthStatus?.status)
    }

    /// `videoId` is the broadcast id (a YouTube broadcast is a video).
    func fetchConcurrentViewers(videoId: String) async throws -> Int? {
        let token = try await getValidAccessToken()
        let url = "\(YOUTUBE_API_BASE)/videos?part=liveStreamingDetails&id=\(videoId)"
        let response: YouTubeListResponse<YouTubeVideoLiveDetailsResource> = try await apiGet(
            url: url,
            token: token,
            operation: .videoLiveDetails
        )
        return response.items.first?.liveStreamingDetails?.concurrentViewers.flatMap { Int($0) }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Re-run Step 2's command. Expected: `** TEST SUCCEEDED **`. Also run the whole `YouTubeServiceTests` suite to confirm nothing regressed:
```bash
xcodebuild test -project Tubeist.xcodeproj -scheme Tubeist -destination "$SIM" \
  -only-testing:TubeistTests/YouTubeServiceTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

- [ ] **Step 6: Commit**

```bash
git add Tubeist/YouTubeAPITransport.swift Tubeist/YouTubeService.swift TubeistTests/YouTubeServiceTests.swift
git commit -m "Add YouTube stream health and concurrent viewer fetches

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: Track the YouTube stream id in AppState

The health call needs the bound stream id; today only the broadcast id is stored.

**Files:**
- Modify: `Tubeist/TubeistApp.swift` (`AppState`, near `youtubeBroadcastId`, line ~118)
- Modify: `Tubeist/Streamer.swift` (`setYouTubeBroadcast` at line ~157; call sites at ~632 and ~638)
- Modify: `Tubeist/Settings.swift` and `Tubeist/TubeistView.swift` only if they assign `youtubeBroadcastId` (grep first; keep `youtubeStreamId` in step with it)

**Interfaces:**
- Produces: `AppState.youtubeStreamId: String?` (nil when no YouTube broadcast).

- [ ] **Step 1: Add the property**

In `AppState`, below `var youtubeBroadcastId: String? = nil`:
```swift
    var youtubeStreamId: String? = nil
```

- [ ] **Step 2: Thread it through `setYouTubeBroadcast`**

Change the signature and body in `Streamer.swift`:
```swift
    func setYouTubeBroadcast(id: String?, streamId: String?, status: String?) async {
        let appState = self.appState
        await MainActor.run {
            appState?.isYouTubeSignedIn = id != nil
            appState?.youtubeBroadcastId = id
            appState?.youtubeStreamId = streamId
            appState?.youtubeStatus = status
        }
    }
```
Update the two call sites (~632 and ~638):
```swift
            await streamingActor.setYouTubeBroadcast(
                id: preparation.broadcast.id,
                streamId: preparation.broadcast.boundStreamId,
                status: preparation.broadcast.lifeCycleStatus
            )
        ...
            await streamingActor.setYouTubeBroadcast(id: nil, streamId: nil, status: nil)
```

- [ ] **Step 3: Build and run existing tests**

Run: `grep -rn "setYouTubeBroadcast\|youtubeBroadcastId = " Tubeist TubeistTests` and fix any other caller so it compiles (set `youtubeStreamId` to nil wherever `youtubeBroadcastId` is cleared; set `broadcast.boundStreamId` wherever it is set, e.g. `Settings.swift:1013` and `:983`).
```bash
xcodebuild test -project Tubeist.xcodeproj -scheme Tubeist -destination "$SIM" \
  -only-testing:TubeistTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **` (same tests as baseline; if there were failures on the base commit, record them in `CHANGES.md` and do not fix unrelated ones).

- [ ] **Step 4: Commit**

```bash
git add -A Tubeist TubeistTests
git commit -m "Track the bound YouTube stream id in AppState

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: Widget extension target and Live Activity UI

**Files:**
- Move: `Tubeist/StreamActivityAttributes.swift` → `Shared/StreamActivityAttributes.swift`
- Create: `TubeistLiveActivity/TubeistLiveActivityBundle.swift`
- Create: `TubeistLiveActivity/StreamLiveActivity.swift`
- Create: `TubeistLiveActivity/Info.plist`
- Modify: `Tubeist.xcodeproj/project.pbxproj` (new extension target, `Shared` and `TubeistLiveActivity` synchronized groups, embed phase, `INFOPLIST_KEY_NSSupportsLiveActivities = YES` on the app target)

**Interfaces:**
- Consumes: `StreamActivityAttributes` and its enums (Task 1).
- Produces: a buildable `TubeistLiveActivity` appex embedded in `Tubeist.app`.

- [ ] **Step 1: Create the extension target with the `xcodeproj` gem**

The pbxproj uses synchronized root groups (objectVersion 77), which hand-editing gets wrong easily. Use the `xcodeproj` gem:
```bash
gem install xcodeproj --user-install
ruby -e 'require "xcodeproj"; puts Xcodeproj::VERSION'
```
Write `scratchpad/add_widget_target.rb` (scratchpad, not the repo) that: opens `Tubeist.xcodeproj`; adds an `app_extension` target `TubeistLiveActivity` (iOS 18.0, Swift 6.0, product bundle id `com.subside.Tubeist.LiveActivity`, `GENERATE_INFOPLIST_FILE = YES`, `INFOPLIST_FILE = TubeistLiveActivity/Info.plist`, `SKIP_INSTALL = YES`, `TARGETED_DEVICE_FAMILY = 1`, `SWIFT_VERSION = 6.0`); adds `PBXFileSystemSynchronizedRootGroup` entries for `TubeistLiveActivity` and `Shared` to the main group; attaches `Shared` to both the app and the extension targets and `TubeistLiveActivity` to the extension only; adds the extension as a target dependency of `Tubeist` and an "Embed Foundation Extensions" copy-files phase (`dstSubfolderSpec` PlugIns); sets `INFOPLIST_KEY_NSSupportsLiveActivities = YES` on both `Tubeist` build configurations; saves.

If the gem cannot express synchronized groups or the resulting project fails to open (`xcodebuild -list -project Tubeist.xcodeproj` errors), STOP, `git checkout Tubeist.xcodeproj`, and ask the user to add the target manually in Xcode (File > New > Target > Widget Extension, name `TubeistLiveActivity`, tick "Include Live Activity", untick "Include Configuration App Intent"), then continue from Step 2 against their result. Do not hand-write pbxproj sections.

- [ ] **Step 2: Move the shared file**

```bash
mkdir -p Shared TubeistLiveActivity
git mv Tubeist/StreamActivityAttributes.swift Shared/StreamActivityAttributes.swift
```

- [ ] **Step 3: Write the extension sources**

`TubeistLiveActivity/TubeistLiveActivityBundle.swift`:
```swift
import SwiftUI
import WidgetKit

@main
struct TubeistLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        StreamLiveActivity()
    }
}
```

`TubeistLiveActivity/StreamLiveActivity.swift`:
```swift
import ActivityKit
import SwiftUI
import WidgetKit

struct StreamLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StreamActivityAttributes.self) { context in
            StreamActivityView(state: context.state, startedAt: context.attributes.startedAt)
                .padding()
                .activityBackgroundTint(.black.opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HealthBadge(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StreamDetailRows(state: context.state)
                }
            } compactLeading: {
                HealthDot(state: context.state)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                HealthDot(state: context.state)
            }
        }
        // Opt in to the compact Smart Stack layout used on Apple Watch.
        .supplementalActivityFamilies([.small])
    }
}

struct StreamActivityView: View {
    @Environment(\.activityFamily) private var family
    let state: StreamActivityAttributes.ContentState
    let startedAt: Date

    var body: some View {
        switch family {
        case .small:
            VStack(alignment: .leading, spacing: 2) {
                HealthBadge(state: state)
                Text(startedAt, style: .timer).monospacedDigit().font(.caption)
                if let viewers = state.viewers {
                    Label("\(viewers)", systemImage: "eye").font(.caption2)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HealthBadge(state: state)
                    Spacer()
                    Text(startedAt, style: .timer).monospacedDigit()
                }
                StreamDetailRows(state: state)
            }
        }
    }
}

struct StreamDetailRows: View {
    let state: StreamActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let warning = state.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                if let viewers = state.viewers { Label("\(viewers)", systemImage: "eye") }
                if let kbps = state.bitrateKbps { Label("\(kbps / 1000) Mbps", systemImage: "arrow.up") }
                if let battery = state.batteryPercent { Label("\(battery)%", systemImage: "battery.75") }
                if let thermal = state.thermal, thermal != .nominal {
                    Label(thermal.rawValue.capitalized, systemImage: "thermometer.medium")
                        .foregroundStyle(thermal == .fair ? .yellow : .red)
                }
            }
            .font(.caption)
        }
    }
}

struct HealthBadge: View {
    let state: StreamActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            HealthDot(state: state)
            Text(label).font(.headline)
        }
    }

    private var label: String {
        switch state.phase {
        case .connecting: "Connecting"
        case .stopping: "Stopping"
        case .ended: "Ended"
        case .live: state.isStale ? "Live ?" : "Live · \(state.health.label)"
        }
    }
}

struct HealthDot: View {
    let state: StreamActivityAttributes.ContentState

    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }

    private var color: Color {
        if state.phase != .live || state.isStale { return .gray }
        switch state.health {
        case .good: return .green
        case .ok: return .yellow
        case .bad, .noData: return .red
        case .unknown: return .gray
        }
    }
}
```

`TubeistLiveActivity/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.widgetkit-extension</string>
	</dict>
</dict>
</plist>
```

- [ ] **Step 4: Build the app and extension**

```bash
xcodebuild build -project Tubeist.xcodeproj -scheme Tubeist -destination "$SIM" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
find ~/Library/Developer/Xcode/DerivedData -name "TubeistLiveActivity.appex" -path "*iphonesimulator*" | head -1
```
Expected: `** BUILD SUCCEEDED **`, and the `.appex` exists (embedded under `Tubeist.app/PlugIns`). If `.supplementalActivityFamilies` or `\.activityFamily` fail to compile on the installed SDK, read the compiler message and adjust to the SDK's actual API (both are iOS 18); do not remove the small-family layout without recording why in `CHANGES.md`.

- [ ] **Step 5: Run the full unit test suite**

`xcodebuild test ... -only-testing:TubeistTests CODE_SIGNING_ALLOWED=NO`. Expected: success (confirms the moved shared file still compiles into the app target).

- [ ] **Step 6: Commit**

```bash
git add -A Shared TubeistLiveActivity Tubeist Tubeist.xcodeproj
git commit -m "Add TubeistLiveActivity widget extension and Live Activity UI

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: Controller, notifications and coordinator

**Files:**
- Create: `Tubeist/StreamActivityController.swift`
- Create: `Tubeist/StreamActivityCoordinator.swift`
- Modify: `Tubeist/TubeistView.swift` (`.onChange(of: appState.streamSessionState)` at ~line 1183, and the `soonGoingToBackground` handler ~1166)
- Modify: `Tubeist/Tubeist.entitlements` (add Time Sensitive Notifications)
- Modify: `Tubeist/Settings.swift` (only the three static settings; UI is Task 6)

**Interfaces:**
- Consumes: `StreamActivityPolicy`, `StreamSnapshot`, `StreamAlert`, `LiveActivityDetail`, `StreamActivityAttributes` (Tasks 1, 4); `YouTubeService.fetchStreamHealth/fetchConcurrentViewers` (Task 2); `AppState.youtubeStreamId/youtubeBroadcastId/streamHealth/streamSessionState` (Task 3 and existing).
- Produces:
  - `Settings.liveActivityDetail: LiveActivityDetail`, `Settings.alertOnBadHealth: Bool`, `Settings.alertOnRecovery: Bool`
  - `@MainActor final class StreamActivityController { func apply(_ decision: StreamActivityPolicy.Decision, streamStartedAt: Date, now: Date) async; func end() async }`
  - `@MainActor final class StreamActivityCoordinator { func start(appState: AppState, youtubeService: YouTubeService); func stop() }`

- [ ] **Step 1: Add the settings accessors**

Next to `static var stream: Bool` in `Settings.swift` (the private `bool(forKey:default:)` helper is in the same type):
```swift
    static var liveActivityDetail: LiveActivityDetail {
        get {
            UserDefaults.standard.string(forKey: "LiveActivityDetail")
                .flatMap(LiveActivityDetail.init(rawValue:)) ?? .standard
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "LiveActivityDetail") }
    }
    static var alertOnBadHealth: Bool {
        get { bool(forKey: "AlertOnBadHealth", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "AlertOnBadHealth") }
    }
    static var alertOnRecovery: Bool {
        get { bool(forKey: "AlertOnRecovery", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "AlertOnRecovery") }
    }
```

- [ ] **Step 2: Write the controller**

`Tubeist/StreamActivityController.swift`:
```swift
//
//  StreamActivityController.swift
//  Tubeist
//
//  Thin ActivityKit wrapper. Starts/updates/ends the Live Activity, restarts it
//  before iOS's 8-hour limit, and falls back to a local notification for alerts
//  when Live Activities are unavailable. All failures are logged, never thrown.
//

import ActivityKit
import Foundation
import UserNotifications

@MainActor
final class StreamActivityController {
    static let maxActivityAge: TimeInterval = 7.5 * 3600
    private static let staleInterval: TimeInterval = 90

    private var activity: Activity<StreamActivityAttributes>?
    private var activityStartedAt: Date?

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func apply(
        _ decision: StreamActivityPolicy.Decision,
        streamStartedAt: Date,
        now: Date
    ) async {
        var alertDelivered = false
        if let content = decision.content, isAvailable {
            alertDelivered = await push(
                content,
                alert: decision.alert,
                streamStartedAt: streamStartedAt,
                now: now
            )
        }
        if let alert = decision.alert, !alertDelivered {
            await StreamAlertNotifier.post(alert)
        }
    }

    func end() async {
        guard let activity else { return }
        self.activity = nil
        activityStartedAt = nil
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    /// Returns true when the alert was attached to a Live Activity update.
    private func push(
        _ content: StreamActivityAttributes.ContentState,
        alert: StreamAlert?,
        streamStartedAt: Date,
        now: Date
    ) async -> Bool {
        if let started = activityStartedAt, now.timeIntervalSince(started) > Self.maxActivityAge {
            LOG("Live Activity reached its age limit; restarting", level: .info)
            await end()
        }
        if activity == nil {
            do {
                activity = try Activity.request(
                    attributes: StreamActivityAttributes(startedAt: streamStartedAt),
                    content: .init(state: content, staleDate: now.addingTimeInterval(Self.staleInterval)),
                    pushType: nil
                )
                activityStartedAt = now
            } catch {
                LOG("Could not start Live Activity: \(error.localizedDescription)", level: .warning)
                return false
            }
        }
        let alertConfiguration = alert.map {
            AlertConfiguration(
                title: LocalizedStringResource(stringLiteral: $0.title),
                body: LocalizedStringResource(stringLiteral: $0.body),
                sound: .default
            )
        }
        await activity?.update(
            .init(state: content, staleDate: now.addingTimeInterval(Self.staleInterval)),
            alertConfiguration: alertConfiguration
        )
        return alert != nil
    }
}

final class StreamAlertNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = StreamAlertNotifier()

    /// Call once at stream start when alerts are enabled.
    static func prepare() async {
        UNUserNotificationCenter.current().delegate = shared
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .timeSensitive])
    }

    static func post(_ alert: StreamAlert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "tubeist.stream-health", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            LOG("Could not post stream alert: \(error.localizedDescription)", level: .warning)
        }
    }

    // Show banners even while Tubeist is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
```
(Both types go in `StreamActivityController.swift`; put `final class StreamAlertNotifier` in the same file directly after the controller, inside the same code listing above — a plain `enum` cannot be a notification delegate, hence the class singleton.)

Add to `Tubeist/Tubeist.entitlements` inside the top-level `<dict>`:
```xml
	<key>com.apple.developer.usernotifications.time-sensitive</key>
	<true/>
```

- [ ] **Step 3: Write the coordinator**

`Tubeist/StreamActivityCoordinator.swift`:
```swift
//
//  StreamActivityCoordinator.swift
//  Tubeist
//
//  Runs while a stream is live: every 5 s builds a StreamSnapshot from AppState,
//  device metrics and the latest YouTube polls, asks StreamActivityPolicy what
//  to do, and hands the decision to StreamActivityController. Runs entirely off
//  the media pipeline; failures keep the last known values (which then go stale).
//

import Foundation
import UIKit

@MainActor
final class StreamActivityCoordinator {
    private static let tick: Duration = .seconds(5)
    private static let healthInterval: TimeInterval = 15
    private static let viewerInterval: TimeInterval = 30
    private static let quotaBackoff: TimeInterval = 300

    private let controller = StreamActivityController()
    private var task: Task<Void, Never>?

    func start(appState: AppState, youtubeService: YouTubeService) {
        task?.cancel()
        let detail = Settings.liveActivityDetail
        let alertOnBad = Settings.alertOnBadHealth
        guard detail != .off || alertOnBad else { return }

        task = Task { [controller] in
            if alertOnBad || Settings.alertOnRecovery { await StreamAlertNotifier.prepare() }
            UIDevice.current.isBatteryMonitoringEnabled = true

            var policy = StreamActivityPolicy(
                detail: detail,
                alertOnBad: alertOnBad,
                alertOnRecovery: Settings.alertOnRecovery
            )
            let startedAt = Date()
            var health = YouTubeStreamHealth.unknown
            var healthUpdatedAt: Date?
            var viewers: Int?
            var nextHealthPoll = Date.distantPast
            var nextViewerPoll = Date.distantPast

            while !Task.isCancelled {
                let now = Date()

                if now >= nextHealthPoll, let streamId = appState.youtubeStreamId {
                    do {
                        health = try await youtubeService.fetchStreamHealth(streamId: streamId)
                        healthUpdatedAt = now
                        nextHealthPoll = now.addingTimeInterval(Self.healthInterval)
                    } catch {
                        LOG("Stream health poll failed: \(error.localizedDescription)", level: .debug)
                        nextHealthPoll = now.addingTimeInterval(Self.backoff(after: error))
                    }
                }
                if detail == .full, now >= nextViewerPoll, let videoId = appState.youtubeBroadcastId {
                    do {
                        viewers = try await youtubeService.fetchConcurrentViewers(videoId: videoId)
                        nextViewerPoll = now.addingTimeInterval(Self.viewerInterval)
                    } catch {
                        LOG("Viewer poll failed: \(error.localizedDescription)", level: .debug)
                        nextViewerPoll = now.addingTimeInterval(Self.backoff(after: error))
                    }
                }

                let bitrate = await EncodedOutputRouter.shared.recommendedVideoBitrate()
                let snapshot = Self.snapshot(
                    appState: appState,
                    health: health,
                    healthUpdatedAt: healthUpdatedAt,
                    viewers: viewers,
                    bitrateKbps: bitrate.map { $0 / 1000 }
                )
                let decision = policy.evaluate(snapshot, now: now)
                await controller.apply(decision, streamStartedAt: startedAt, now: now)

                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        Task { await controller.end() }
    }

    private static func backoff(after error: Error) -> TimeInterval {
        if case YouTubeError.apiError(403, _) = error { return quotaBackoff }
        return healthInterval
    }

    private static func snapshot(
        appState: AppState,
        health: YouTubeStreamHealth,
        healthUpdatedAt: Date?,
        viewers: Int?,
        bitrateKbps: Int?
    ) -> StreamSnapshot {
        let phase: StreamPhase = switch appState.streamSessionState {
        case .preparing: .connecting
        case .live: .live
        case .stopping: .stopping
        case .idle, .failed: .ended
        }
        let (link, warning): (LinkQuality, String?) = switch appState.streamHealth {
        case .pristine: (.good, nil)
        case .degraded: (.degraded, "Upload degraded")
        case .unusable: (.poor, "Upload problem")
        case .awaiting, .silenced: (.unknown, nil)
        }
        let thermal: ThermalLevel = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
        let level = UIDevice.current.batteryLevel
        return StreamSnapshot(
            phase: phase,
            youtubeHealth: health,
            healthUpdatedAt: healthUpdatedAt,
            viewers: viewers,
            bitrateKbps: bitrateKbps,
            link: link,
            thermal: thermal,
            batteryPercent: level < 0 ? nil : Int(level * 100),
            warning: warning
        )
    }
}
```
Before building, confirm `EncodedOutputRouter.shared.recommendedVideoBitrate()` signature (`grep -n "func recommendedVideoBitrate" Tubeist/EncodedOutputRouter.swift`); it returns `Int?` in bits per second at line ~336. If it returns a different unit, adjust the `/ 1000`.

- [ ] **Step 4: Wire into `TubeistView`**

Add `@State private var streamActivityCoordinator = StreamActivityCoordinator()` beside the other `@State` properties. In `.onChange(of: appState.streamSessionState)` (~line 1183):
```swift
            if state.isLive {
                startYouTubePolling()
                streamActivityCoordinator.start(appState: appState, youtubeService: youtubeService)
            } else {
                stopYouTubePolling()
                streamActivityCoordinator.stop()
            }
```
In the `soonGoingToBackground` handler's `if isBackgrounded` branch add `streamActivityCoordinator.stop()`; in `.onAppear`'s `if appState.isStreamActive` branch add the `start(...)` call.

- [ ] **Step 5: Build and test**

```bash
xcodebuild build -project Tubeist.xcodeproj -scheme Tubeist -destination "$SIM" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
xcodebuild test -project Tubeist.xcodeproj -scheme Tubeist -destination "$SIM" -only-testing:TubeistTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```
Expected: both succeed. Fix Swift 6 concurrency diagnostics properly (do not add `@preconcurrency` or `nonisolated(unsafe)` without a comment explaining why).

- [ ] **Step 6: Commit**

```bash
git add -A Tubeist
git commit -m "Drive the Live Activity from the running stream and add alerts

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 6: Settings UI

**Files:**
- Modify: `Tubeist/Settings.swift` (settings snapshot struct ~lines 186-275, `@State` properties ~299, view body — new Section after the "Monitoring" section at ~733)

**Interfaces:**
- Consumes: `Settings.liveActivityDetail/alertOnBadHealth/alertOnRecovery` (Task 5), `LiveActivityDetail`.

- [ ] **Step 1: Follow the existing staged-settings pattern**

Settings are staged: values are held in a snapshot struct (see `captureRemuxFixtures` at lines 206, 230, 275) and `@State` (line 299), and written on save. Mirror that exactly for three new fields: `liveActivityDetail: LiveActivityDetail`, `alertOnBadHealth: Bool`, `alertOnRecovery: Bool` — add to the snapshot struct, its loader (`Settings.liveActivityDetail` etc.), its saver, and to the `@State` declarations.

- [ ] **Step 2: Add the section**

After the `Section(header: Text("Monitoring")) { ... }` block:
```swift
                Section(
                    header: Text("Apple Watch"),
                    footer: Text("Shows stream status as a Live Activity that appears on your Apple Watch. Full also shows viewers, bitrate, upload quality, temperature and battery, and uses a little more YouTube API quota.")
                ) {
                    Picker("Live Activity detail", selection: $liveActivityDetail) {
                        ForEach(LiveActivityDetail.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Alert on Bad / No Data", isOn: $alertOnBadHealth)
                    Toggle("Alert when recovered", isOn: $alertOnRecovery)
                        .disabled(!alertOnBadHealth)
                }
```

- [ ] **Step 3: Build, run unit and settings-migration tests**

```bash
xcodebuild test -project Tubeist.xcodeproj -scheme Tubeist -destination "$SIM" \
  -only-testing:TubeistTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```
Expected: success (includes `SettingsMigrationTests`).

- [ ] **Step 4: Commit**

```bash
git add Tubeist/Settings.swift
git commit -m "Add Apple Watch Live Activity and alert settings

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 7: Docs, verification and delivery zip

**Files:**
- Modify: `PLAN.md` (new phase before `## Regression matrix`)
- Modify: `README.md` (short feature note)
- Create: `CHANGES.md` (repo root; also copied into the zip)
- Create (outside repo): `<repo-root>/../yt_status/tubeist-watch-live-activity.zip`

- [ ] **Step 1: Add the `PLAN.md` phase**

Insert before `## Regression matrix`:
```markdown
### Phase 11 — Apple Watch Live Activity

Spec: `docs/superpowers/specs/2026-09-20-watch-live-activity-design.md`.
Plan: `docs/superpowers/plans/2026-09-20-watch-live-activity.md`.

Acceptance:
- [ ] Unit tests pass for `StreamActivityPolicy` and the YouTube health/viewer fetches.
- [ ] App and `TubeistLiveActivity` build for iOS Simulator.
- [ ] Device: Live Activity appears on the paired watch Smart Stack during a stream, including with the iPhone unlocked and Tubeist in the foreground (key risk; see spec).
- [ ] Device: Bad / No Data health produces a watch alert and haptic; recovery alert respects its toggle.
- [ ] Device: Off/Standard/Full change what is shown; Live Activities disabled in iOS Settings falls back to notifications.
- [ ] Device: a stream longer than 8 h keeps a Live Activity (restart path).
```
Add two lines to `README.md` describing the Apple Watch setting.

- [ ] **Step 2: Final verification**

```bash
xcodebuild test -project Tubeist.xcodeproj -scheme Tubeist -destination "$SIM" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25
```
Run the full `Tubeist` test action (not just `TubeistTests`) and record the exact pass/fail counts. If UI tests cannot run in this environment, say so in `CHANGES.md` rather than claiming they passed. Compare failures against the base commit (`git stash` is NOT to be used; use `git worktree add ../tubeist-base 5e2d440` for a baseline run if needed, then remove it).

- [ ] **Step 3: Write `CHANGES.md`**

Contents: summary of the feature; file list (added/modified); the base commit `5e2d440`; how to apply (`git am patches/*.patch`); build/test commands and their actual results; decisions (foreground app, no backend, dropped frames replaced by local pipeline health); manual device checklist (copied from the `PLAN.md` phase); notes for the lead dev: the extension bundle id must be prefixed by the app's bundle id, the Time Sensitive Notifications capability must be enabled for the App ID, and the `xcodeproj`-generated pbxproj changes should be reviewed.

- [ ] **Step 4: Commit docs**

```bash
git add PLAN.md README.md CHANGES.md
git commit -m "Document the Apple Watch Live Activity work

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Build the zip**

```bash
cd <repo-root>
OUT=$(mktemp -d)/tubeist-watch-live-activity
mkdir -p "$OUT/patches" "$OUT/source"
git format-patch 5e2d440..HEAD -o "$OUT/patches"
git archive HEAD | tar -x -C "$OUT/source"
cp CHANGES.md "$OUT/CHANGES.md"
echo "base: 5e2d440" > "$OUT/BASE_COMMIT.txt"
( cd "$(dirname "$OUT")" && zip -qr <repo-root>/../yt_status/tubeist-watch-live-activity.zip tubeist-watch-live-activity )
unzip -l <repo-root>/../yt_status/tubeist-watch-live-activity.zip | tail -5
```
Then prove the patches apply to the base: in a temp clone, `git clone <repo-root> tmp && cd tmp && git checkout -q 5e2d440 && git am "$OUT"/patches/*.patch`. Expected: all patches apply cleanly. Confirm the zip contains no signing tweaks: `grep -r "<local app bundle id>\|<DEVELOPMENT_TEAM>" "$OUT/source"` returns nothing.

- [ ] **Step 6: Restore the author's local signing tweaks**

The stash is left intact. On the feature branch, reapply only the signing/entitlement parts (skip the `YouTubeService.swift` hunk, per the user):
```bash
git stash show -p stash@{0} -- Tubeist.xcodeproj/project.pbxproj Tubeist/Info.plist Tubeist/Tubeist.entitlements | git apply --3way
```
Resolve any conflicts by keeping both my additions (Time Sensitive entitlement, extension target, `NSSupportsLiveActivities`) and the user's local removals. The extension's bundle id must also be prefixed with the user's local app id (`<local app bundle id>` → `<local app bundle id>.LiveActivity`) and it needs `DEVELOPMENT_TEAM = <DEVELOPMENT_TEAM>`; make those edits to the working tree only and do NOT commit them. Confirm `git status` shows these as uncommitted modifications and `git log` is unchanged.

---

## Self-Review

- **Spec coverage:** detail levels (Tasks 1, 6); alerts + debounce/cooldown/recovery (Tasks 1, 5); YouTube health/viewers + polling intervals + backoff + stale (Tasks 2, 5); widget + watch layout (Task 4); 8 h restart (Task 5 controller); notification fallback + Time Sensitive (Task 5); settings (Tasks 5, 6); delivery zip, `PLAN.md`, `CHANGES.md` (Task 7); key foreground/watch-delivery risk recorded as a manual acceptance item (Task 7 `PLAN.md` phase). Stream id plumbing needed by the spec's health poll is Task 3.
- **Placeholders:** none intended; Task 4 Step 1 intentionally describes the gem script's contents in prose because it must be adapted to the gem's API, with an explicit stop-and-ask fallback.
- **Type consistency:** `StreamSnapshot`, `StreamActivityPolicy.Decision`, `StreamAlert`, `LiveActivityDetail`, `YouTubeStreamHealth`, `fetchStreamHealth(streamId:)`, `fetchConcurrentViewers(videoId:)`, `setYouTubeBroadcast(id:streamId:status:)` are used identically across tasks.
