//
//  HLSMediaPlaylist.swift
//  Tubeist
//

import Foundation

enum HLSPlaylistError: Error, Equatable, CustomStringConvertible {
    case invalidSessionIdentifier
    case invalidDuration(Double)
    case tooManyOutstandingSegments
    case unknownSequence(Int)

    var description: String {
        switch self {
        case .invalidSessionIdentifier: "The HLS session identifier is not URL-safe"
        case .invalidDuration(let duration): "Invalid HLS segment duration: \(duration)"
        case .tooManyOutstandingSegments: "The HLS upload queue already contains five segments"
        case .unknownSequence(let sequence): "Unknown HLS media sequence: \(sequence)"
        }
    }
}

struct HLSPlaylistEntry: Sendable, Equatable {
    let sequence: Int
    let filename: String
    let duration: Double
    let discontinuity: Bool
    fileprivate var acknowledged: Bool
}

struct HLSMediaPlaylist: Sendable, Equatable {
    static let maximumOutstandingSegments = 5

    let sessionIdentifier: String
    let playlistFilename: String
    private(set) var targetDuration: Int = 1
    private(set) var entries: [HLSPlaylistEntry] = []
    private(set) var nextSequence: Int = 0
    private let acknowledgedTailCount: Int

    init(sessionIdentifier: String, acknowledgedTailCount: Int = 2) throws {
        guard Self.isSafeFilenameComponent(sessionIdentifier),
              !sessionIdentifier.isEmpty,
              acknowledgedTailCount >= 0 else {
            throw HLSPlaylistError.invalidSessionIdentifier
        }
        self.sessionIdentifier = sessionIdentifier
        self.playlistFilename = "tubeist_\(sessionIdentifier).m3u8"
        self.acknowledgedTailCount = acknowledgedTailCount
    }

    var mediaSequence: Int {
        entries.first?.sequence ?? nextSequence
    }

    var outstandingCount: Int {
        entries.lazy.filter { !$0.acknowledged }.count
    }

    var queuedDuration: Double {
        entries.lazy.filter { !$0.acknowledged }.reduce(0) { $0 + $1.duration }
    }

    mutating func append(duration: Double, discontinuity: Bool = false) throws -> HLSPlaylistEntry {
        guard duration.isFinite, duration > 0, duration <= 5 else {
            throw HLSPlaylistError.invalidDuration(duration)
        }
        guard outstandingCount < Self.maximumOutstandingSegments else {
            throw HLSPlaylistError.tooManyOutstandingSegments
        }
        let entry = HLSPlaylistEntry(
            sequence: nextSequence,
            filename: "tubeist_\(sessionIdentifier)_\(nextSequence).ts",
            duration: duration,
            discontinuity: discontinuity,
            acknowledged: false
        )
        entries.append(entry)
        nextSequence += 1
        targetDuration = max(targetDuration, Int(ceil(duration)))
        return entry
    }

    mutating func acknowledge(sequence: Int) throws {
        guard let index = entries.firstIndex(where: { $0.sequence == sequence }) else {
            throw HLSPlaylistError.unknownSequence(sequence)
        }
        entries[index].acknowledged = true
        trimAcknowledgedPrefix()
    }

    func render() -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        for entry in entries {
            if entry.discontinuity {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            lines.append("#EXTINF:\(Self.formattedDuration(entry.duration)),")
            lines.append(entry.filename)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func makeSessionIdentifier(at date: Date = Date(), uuid: UUID = UUID()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let suffix = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        return "\(formatter.string(from: date))_\(suffix)"
    }

    private mutating func trimAcknowledgedPrefix() {
        let firstOutstanding = entries.firstIndex { !$0.acknowledged }
        let firstIndexToKeep: Int
        if let firstOutstanding {
            firstIndexToKeep = max(0, firstOutstanding - acknowledgedTailCount)
        } else {
            firstIndexToKeep = max(0, entries.count - acknowledgedTailCount)
        }
        if firstIndexToKeep > 0 {
            entries.removeFirst(firstIndexToKeep)
        }
    }

    private static func isSafeFilenameComponent(_ string: String) -> Bool {
        string.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) ||
                ($0 >= 0x41 && $0 <= 0x5a) ||
                ($0 >= 0x61 && $0 <= 0x7a) ||
                $0 == 0x2d || $0 == 0x5f
        }
    }

    private static func formattedDuration(_ duration: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), duration)
    }
}
