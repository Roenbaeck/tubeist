//
//  PlannedStreams.swift
//  Tubeist
//
//  Model and pure helpers for choosing a planned (pre-created) YouTube broadcast.
//

import Foundation

struct PlannedStreamDetails: Codable, Sendable, Equatable {
    var title: String
    var privacyStatus: String
    var selfDeclaredMadeForKids: Bool
    var enableDvr: Bool
    var enableEmbed: Bool
    var latencyPreference: String
    var playlistId: String?

    init(broadcast: YouTubeBroadcast, playlistId: String?) {
        title = broadcast.title
        privacyStatus = broadcast.privacyStatus
        selfDeclaredMadeForKids = broadcast.selfDeclaredMadeForKids ?? false
        enableDvr = broadcast.enableDvr
        enableEmbed = broadcast.enableEmbed
        latencyPreference = broadcast.latencyPreference
        self.playlistId = playlistId
    }
}

struct YouTubePlaylistMembership: Codable, Sendable, Equatable {
    let playlistId: String
    let itemId: String
}

struct PlannedStreamSelection: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case planned, restart }

    var kind: Kind
    /// Planned: the target broadcast. Restart: the ended broadcast.
    let broadcastId: String
    /// May be absent until the user gives an unbound Studio broadcast its own key.
    let streamId: String?
    /// ISO 8601 from YouTube; drives the same-day rule.
    let scheduledStartTime: String
    /// Values as loaded from YouTube.
    var loaded: PlannedStreamDetails
    /// Values in the fields at Save.
    var edited: PlannedStreamDetails
    var loadedMembership: YouTubePlaylistMembership?
    var thumbnailChanged: Bool

    func restarting() -> PlannedStreamSelection {
        var copy = self
        copy.kind = .restart
        copy.loaded = edited
        copy.loadedMembership = nil
        return copy
    }

    /// The Restart entry once Start has gone live on `applied`: it carries the
    /// details actually in effect, including Studio changes made since the pick.
    func restarting(after applied: YouTubeBroadcast) -> PlannedStreamSelection {
        let details = PlannedStreamDetails(broadcast: applied, playlistId: edited.playlistId)
        return PlannedStreamSelection(
            kind: .restart, broadcastId: applied.id, streamId: applied.boundStreamId ?? streamId,
            scheduledStartTime: scheduledStartTime, loaded: details, edited: details,
            loadedMembership: nil, thumbnailChanged: thumbnailChanged)
    }
}

enum PlannedStreams {
    static func parse(_ iso: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: iso) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso)
    }

    static func isScheduledToday(_ iso: String?, now: Date, calendar: Calendar) -> Bool {
        guard let iso, let date = parse(iso) else { return false }
        return calendar.isDate(date, inSameDayAs: now)
    }

    static func today(_ broadcasts: [YouTubeBroadcast], remembered: Set<String>,
                      now: Date, calendar: Calendar) -> [YouTubeBroadcast] {
        broadcasts
            .filter {
                BroadcastKeys.isPlannedBroadcast($0, remembered: remembered)
                    && isScheduledToday($0.scheduledStartTime, now: now, calendar: calendar)
            }
            .sorted {
                let lhs = $0.scheduledStartTime.flatMap(parse) ?? .distantFuture
                let rhs = $1.scheduledStartTime.flatMap(parse) ?? .distantFuture
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }
    }

    static func label(for broadcast: YouTubeBroadcast, calendar: Calendar, needsOwnKey: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        let suffix = needsOwnKey ? " · shares a key" : ""
        guard let date = broadcast.scheduledStartTime.flatMap(parse) else { return broadcast.title + suffix }
        return "\(formatter.string(from: date)) – \(broadcast.title)\(suffix)"
    }

    static func restartLabel(for selection: PlannedStreamSelection) -> String {
        "Restart: \(selection.edited.title)"
    }

    /// Save drops the saved pick only once it is known not to apply: the key
    /// changed, or the list loaded for this key and "New stream" is chosen.
    /// Before or after a failed load, "New stream" is just the default.
    static func shouldClearSavedSelection(choice: PlannedStreamChoice, plannedListLoaded: Bool,
                                          streamKeyChanged: Bool) -> Bool {
        streamKeyChanged || (plannedListLoaded && choice == .newStream)
    }
}
