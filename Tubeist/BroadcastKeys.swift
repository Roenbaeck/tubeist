//
//  BroadcastKeys.swift
//  Tubeist
//
//  Pure rules for giving each planned YouTube broadcast its own stream key.
//

import Foundation

struct BroadcastKeyStream: Sendable, Equatable {
    let id: String
    let title: String
}

enum BroadcastKeys {
    static let titlePrefix = "Tubeist stream "
    // Recognize keys from early builds without creating more under that name.
    private static let legacyTitlePrefix = "Tubeist match "

    /// Shared between phones through YouTube. Creation and schedule times
    /// cannot distinguish a Studio broadcast scheduled for now from our broadcasts.
    static let broadcastDescription = "Created with Tubeist."

    static func isBroadcastKey(title: String?) -> Bool {
        number(in: title) != nil
    }

    static func title(number: Int) -> String {
        "\(titlePrefix)\(number)"
    }

    static func nextNumber(existingTitles: [String]) -> Int {
        (existingTitles.compactMap { number(in: $0) }.max() ?? 0) + 1
    }

    static func isTubeistOwn(_ b: YouTubeBroadcast, remembered: Set<String>) -> Bool {
        remembered.contains(b.id) || b.broadcastDescription == broadcastDescription
    }

    static func isPlannedBroadcast(_ b: YouTubeBroadcast, remembered: Set<String>) -> Bool {
        (b.lifeCycleStatus == "ready" || b.lifeCycleStatus == "created")
            && !b.isDefaultBroadcast
            && !isTubeistOwn(b, remembered: remembered)
    }

    static func freeKeys(
        _ streams: [BroadcastKeyStream], upcoming: [YouTubeBroadcast], active: [YouTubeBroadcast]
    ) -> [BroadcastKeyStream] {
        let bound = Set((upcoming + active).compactMap(\.boundStreamId))
        return streams
            .filter { !bound.contains($0.id) }
            .compactMap { stream in number(in: stream.title).map { ($0, stream) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    static func broadcastsNeedingOwnKey(
        upcoming: [YouTubeBroadcast], streams: [BroadcastKeyStream], remembered: Set<String>
    ) -> [YouTubeBroadcast] {
        let broadcastKeyIds = Set(streams.filter { isBroadcastKey(title: $0.title) }.map(\.id))
        return upcoming.filter { broadcast in
            guard isPlannedBroadcast(broadcast, remembered: remembered) else { return false }
            guard let key = broadcast.boundStreamId, broadcastKeyIds.contains(key) else { return true }
            return upcoming.contains { $0.id != broadcast.id && $0.boundStreamId == key }
        }
    }

    private static func number(in title: String?) -> Int? {
        guard let title,
              let prefix = [titlePrefix, legacyTitlePrefix].first(where: { title.hasPrefix($0) }) else { return nil }
        return Int(title.dropFirst(prefix.count))
    }
}
