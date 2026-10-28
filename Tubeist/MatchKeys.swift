//
//  MatchKeys.swift
//  Tubeist
//
//  Pure rules for giving each planned YouTube match its own stream key.
//

import Foundation

struct MatchKeyStream: Sendable, Equatable {
    let id: String
    let title: String
}

enum MatchKeys {
    static let titlePrefix = "Tubeist match "

    /// How close scheduled start and creation time are for a broadcast Tubeist
    /// created itself (it schedules about 10 s after creating).
    private static let tubeistScheduleTolerance: TimeInterval = 60

    static func isMatchKey(title: String?) -> Bool {
        number(in: title) != nil
    }

    static func title(number: Int) -> String {
        "\(titlePrefix)\(number)"
    }

    static func nextNumber(existingTitles: [String]) -> Int {
        (existingTitles.compactMap { number(in: $0) }.max() ?? 0) + 1
    }

    static func isTubeistOwn(_ b: YouTubeBroadcast, remembered: Set<String>) -> Bool {
        if remembered.contains(b.id) { return true }
        guard let published = b.publishedAt.flatMap(PlannedStreams.parse),
              let scheduled = b.scheduledStartTime.flatMap(PlannedStreams.parse) else { return false }
        return abs(scheduled.timeIntervalSince(published)) <= tubeistScheduleTolerance
    }

    static func isPlannedMatch(_ b: YouTubeBroadcast, remembered: Set<String>) -> Bool {
        (b.lifeCycleStatus == "ready" || b.lifeCycleStatus == "created")
            && !b.isDefaultBroadcast
            && !isTubeistOwn(b, remembered: remembered)
    }

    static func freeKeys(
        _ streams: [MatchKeyStream], upcoming: [YouTubeBroadcast], active: [YouTubeBroadcast]
    ) -> [MatchKeyStream] {
        let bound = Set((upcoming + active).compactMap(\.boundStreamId))
        return streams
            .filter { !bound.contains($0.id) }
            .compactMap { stream in number(in: stream.title).map { ($0, stream) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    static func matchesNeedingOwnKey(
        upcoming: [YouTubeBroadcast], streams: [MatchKeyStream], remembered: Set<String>
    ) -> [YouTubeBroadcast] {
        let matchKeyIds = Set(streams.filter { isMatchKey(title: $0.title) }.map(\.id))
        return upcoming.filter { match in
            guard isPlannedMatch(match, remembered: remembered) else { return false }
            guard let key = match.boundStreamId, matchKeyIds.contains(key) else { return true }
            return upcoming.contains { $0.id != match.id && $0.boundStreamId == key }
        }
    }

    private static func number(in title: String?) -> Int? {
        guard let title, title.hasPrefix(titlePrefix) else { return nil }
        return Int(title.dropFirst(titlePrefix.count))
    }
}
