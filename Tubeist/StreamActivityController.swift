import ActivityKit
import Foundation
import UIKit
import UserNotifications

@MainActor
protocol StreamActivitySink: AnyObject {
    func begin(sessionID: UUID?) async
    func publish(_ content: StreamActivityAttributes.ContentState, alert: StreamActivityAlert?, now: Date) async
    func finish(_ content: StreamActivityAttributes.ContentState?, now: Date) async
}

/// Only the coordinator calls this sink, serially across session changes.
@MainActor
final class StreamActivityController: StreamActivitySink {
    // ActivityKit's async APIs accept calls across isolation domains, but Activity
    // isn't Sendable in every SDK. The immutable handle contains that boundary;
    // all ownership and lifecycle decisions stay on the main actor.
    private struct Handle: @unchecked Sendable {
        let activity: Activity<StreamActivityAttributes>
        func update(_ content: ActivityContent<StreamActivityAttributes.ContentState>, alert: AlertConfiguration?) async {
            await activity.update(content, alertConfiguration: alert)
        }
        func end(_ content: ActivityContent<StreamActivityAttributes.ContentState>?, policy: ActivityUIDismissalPolicy) async {
            await activity.end(content, dismissalPolicy: policy)
        }
        var dismissed: Bool { activity.activityState == .dismissed }
        var ended: Bool { activity.activityState == .ended }
    }
    private var handle: Handle?
    private var sessionID: UUID?
    private var suppressed = false
    private var createdAt: Date?
    private var retryAfter = Date.distantPast

    func begin(sessionID: UUID?) async {
        guard self.sessionID != sessionID || sessionID == nil else { return }
        // Sweep orphans before starting a session, never in an unstructured launch
        // task which could finish after a newly started activity.
        for activity in Activity<StreamActivityAttributes>.activities {
            await Handle(activity: activity).end(nil, policy: .immediate)
        }
        handle = nil
        createdAt = nil
        retryAfter = .distantPast
        suppressed = false
        self.sessionID = sessionID
        StreamActivityNotifications.installDelegate()
    }

    func publish(_ state: StreamActivityAttributes.ContentState, alert: StreamActivityAlert?, now: Date) async {
        if handle?.dismissed == true {
            // User dismissal applies to the rest of this session.
            suppressed = true
            LOG("Live Activity dismissed; hidden for the rest of this session", level: .debug)
            handle = nil
        }
        if handle?.ended == true {
            handle = nil
        }
        if let createdAt, now.timeIntervalSince(createdAt) >= 7.5 * 3600, !suppressed {
            await handle?.end(nil, policy: .immediate)
            handle = nil
        }
        let content = ActivityContent(state: state, staleDate: StreamActivityFreshness.deadline(state, now: now))
        // Re-entering the view after a completed session must not create a new
        // activity just to show Ended. Terminal failures can still notify.
        if state.phase.isTerminal, handle == nil {
            if let alert { await StreamActivityNotifications.post(alert) }
            return
        }
        if handle == nil, !suppressed, let sessionID,
           ActivityAuthorizationInfo().areActivitiesEnabled,
           UIApplication.shared.applicationState == .active, now >= retryAfter {
            do {
                handle = Handle(activity: try Activity.request(attributes: StreamActivityAttributes(sessionID: sessionID),
                    content: content, pushType: nil))
                createdAt = now
                LOG("Live Activity started", level: .debug)
            } catch {
                retryAfter = now.addingTimeInterval(60)
                LOG("Live Activity unavailable: \(error.localizedDescription)", level: .debug)
            }
        }
        if let handle {
            let configuration = alert.map {
                AlertConfiguration(title: LocalizedStringResource(stringLiteral: $0.title),
                    body: LocalizedStringResource(stringLiteral: $0.body), sound: .default)
            }
            await handle.update(content, alert: configuration)
            if alert != nil { LOG("Live Activity alert requested", level: .debug) }
        } else if let alert {
            // Ordinary notification fallback respects Focus and notification
            // settings. It cannot promise a Watch haptic while iPhone is unlocked.
            await StreamActivityNotifications.post(alert)
        }
    }

    func finish(_ state: StreamActivityAttributes.ContentState?, now: Date) async {
        guard let ending = handle else { return }
        if ending.dismissed { suppressed = true }
        handle = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        await ending.end(content, policy: state == nil ? .immediate : .after(now.addingTimeInterval(60)))
        LOG("Live Activity ended", level: .debug)
    }
}

@MainActor
final class StreamActivityNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StreamActivityNotifications()

    static func installDelegate() { UNUserNotificationCenter.current().delegate = shared }

    /// Called only in response to enabling alerts in Settings, never at startup,
    /// while starting a stream, or as a consequence of an error.
    static func requestPermission() async -> Bool {
        installDelegate()
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    static func post(_ alert: StreamActivityAlert) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "tubeist.stream-health", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}


enum StreamActivityFreshness {
    static func deadline(_ state: StreamActivityAttributes.ContentState, now: Date) -> Date {
        let heartbeatDeadline = now.addingTimeInterval(90)
        guard state.phase == .streaming, state.healthTracked, let healthDeadline = state.healthValidUntil else {
            return heartbeatDeadline
        }
        return min(heartbeatDeadline, healthDeadline)
    }
}
