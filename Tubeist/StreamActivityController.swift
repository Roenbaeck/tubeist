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

/// The slice of the controller that `StreamActivityCoordinator` drives, so the tick
/// loop can be exercised in tests without ActivityKit.
@MainActor
protocol StreamActivitySink: AnyObject {
    func apply(_ decision: StreamActivityPolicy.Decision, streamStartedAt: Date, now: Date) async
    func end() async
}

@MainActor
final class StreamActivityController: StreamActivitySink {
    static let maxActivityAge: TimeInterval = 7.5 * 3600
    private static let staleInterval: TimeInterval = 90

    /// `Activity` is a plain non-Sendable class whose `update`/`end` are async and
    /// run off the caller's actor, so Swift 6 refuses to send a main-actor-isolated
    /// activity into them. ActivityKit is documented as safe to drive from any
    /// isolation, so the handle is boxed as `@unchecked Sendable` and every call
    /// goes through the box, which keeps the activity out of the main actor region.
    private struct ActivityHandle: @unchecked Sendable {
        let activity: Activity<StreamActivityAttributes>

        func update(
            _ content: ActivityContent<StreamActivityAttributes.ContentState>,
            alertConfiguration: AlertConfiguration?
        ) async {
            await activity.update(content, alertConfiguration: alertConfiguration)
        }

        func end() async {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        /// True once the activity has been dismissed by the user or ended by iOS, at
        /// which point `update` is silently a no-op. `.stale` is deliberately not
        /// counted: it only says the content outlived its stale date, and the
        /// activity is still on screen and still updatable.
        var isGone: Bool {
            switch activity.activityState {
            case .ended, .dismissed: true
            default: false
            }
        }
    }

    private var handle: ActivityHandle?
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
        handle = nil
        activityStartedAt = nil
        // Ending every activity of this type, not just the tracked handle: an
        // activity the app lost track of (a previous launch, a dropped handle) would
        // otherwise stay on screen with its elapsed timer running and nothing to end
        // it. There is never more than one Tubeist activity in normal operation.
        await Self.endAllActivities()
    }

    /// Ends Live Activities left behind by a crash, a force-quit or a lost handle.
    /// Call at launch while no stream is live: ActivityKit keeps activities alive
    /// across app launches, so a killed app leaves a permanent "live and good"
    /// activity whose timer keeps counting.
    static func endOrphanedActivities() async {
        let orphans = Activity<StreamActivityAttributes>.activities.count
        guard orphans > 0 else { return }
        LOG("Ending \(orphans) leftover Live Activity/Activities from a previous session", level: .info)
        await endAllActivities()
    }

    private static func endAllActivities() async {
        for activity in Activity<StreamActivityAttributes>.activities {
            await ActivityHandle(activity: activity).end()
        }
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
        if let gone = handle, gone.isGone {
            // Updating a dismissed activity does nothing, which would also swallow the
            // alert riding on it. End it before dropping the handle — an ended but
            // still visible activity would otherwise sit beside the new one — and
            // request a fresh activity below.
            LOG("Live Activity was dismissed; requesting a new one", level: .debug)
            handle = nil
            activityStartedAt = nil
            await gone.end()
        }
        if handle == nil {
            do {
                handle = ActivityHandle(activity: try Activity.request(
                    attributes: StreamActivityAttributes(startedAt: streamStartedAt),
                    content: .init(state: content, staleDate: now.addingTimeInterval(Self.staleInterval)),
                    pushType: nil
                ))
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
        await handle?.update(
            .init(state: content, staleDate: now.addingTimeInterval(Self.staleInterval)),
            alertConfiguration: alertConfiguration
        )
        return alert != nil
    }
}

/// A notification-centre delegate has to be a reference type that outlives the
/// call, so this is a class singleton rather than an enum of static functions.
@MainActor
final class StreamAlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StreamAlertNotifier()

    private static var didRequestAuthorization = false

    /// Installs the delegate so alerts show while Tubeist is in the foreground.
    /// Idempotent, and deliberately silent: asking for authorization here would put
    /// a system modal over the camera UI at every stream start.
    static func prepare() {
        UNUserNotificationCenter.current().delegate = shared
    }

    /// Asks for notification permission at a moment that is not go-live. Only when
    /// the user has never answered, and at most once per launch.
    static func requestAuthorizationIfNeeded() async {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .notDetermined else { return }
        await requestAuthorization()
    }

    private static func requestAuthorization() async {
        // No `.timeSensitive` option: it was deprecated in iOS 15 in favour of the
        // com.apple.developer.usernotifications.time-sensitive entitlement, which
        // Tubeist now carries.
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    static func post(_ alert: StreamAlert) async {
        // Last resort for a user who turned alerts on and went live before ever
        // being asked: an unauthorized post is dropped silently, so ask now rather
        // than swallow the alert. Only when the question has never been answered.
        if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined {
            didRequestAuthorization = true
            await requestAuthorization()
        }
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
