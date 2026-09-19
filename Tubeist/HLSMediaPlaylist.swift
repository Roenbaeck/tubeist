//
//  HLSMediaPlaylist.swift
//  Tubeist
//

import Foundation
import CryptoKit

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
    static let retainedSegmentCount = 15

    let sessionIdentifier: String
    let playlistFilename: String
    private let filenamePrefix: String
    // HLS requires this value to remain constant for the entire playlist.
    // Five seconds also covers a delayed keyframe without changing the header.
    let targetDuration: Int = 5
    private(set) var discontinuitySequence = 0
    private(set) var entries: [HLSPlaylistEntry] = []
    private(set) var nextSequence: Int = 0

    // Keep a rolling history of acknowledged uploads, separate from the five
    // outstanding uploads allowed by YouTube. No media bytes are retained here.
    init(sessionIdentifier: String) throws {
        guard Self.isSafeFilenameComponent(sessionIdentifier),
              !sessionIdentifier.isEmpty else {
            throw HLSPlaylistError.invalidSessionIdentifier
        }
        self.sessionIdentifier = sessionIdentifier
        // Hash once per session, retaining 128 bits of identity in 22 URL-safe
        // characters. This preserves stable retry names without repeating the
        // human-readable timestamp and app name in every playlist entry.
        let token = Data(SHA256.hash(data: Data(sessionIdentifier.utf8)).prefix(16))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        self.filenamePrefix = "t\(token)"
        self.playlistFilename = "\(filenamePrefix).m3u8"
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
            filename: mediaFilename(sequence: nextSequence),
            duration: duration,
            discontinuity: discontinuity,
            acknowledged: false
        )
        entries.append(entry)
        nextSequence += 1
        trimAcknowledgedHistory()
        return entry
    }

    mutating func acknowledge(sequence: Int) throws {
        guard let index = entries.firstIndex(where: { $0.sequence == sequence }) else {
            throw HLSPlaylistError.unknownSequence(sequence)
        }
        entries[index].acknowledged = true
        trimAcknowledgedHistory()
    }

    func mediaFilename(sequence: Int) -> String {
        "\(filenamePrefix)_\(String(sequence, radix: 36)).ts"
    }

    private mutating func trimAcknowledgedHistory() {
        guard entries.count > Self.retainedSegmentCount else { return }
        var duration = entries.reduce(0) { $0 + $1.duration }
        var removed = 0
        // HLS forbids shortening a live playlist below three target durations.
        // Unusually short segments may therefore temporarily need >15 entries.
        for entry in entries.prefix(entries.count - Self.retainedSegmentCount) {
            guard entry.acknowledged,
                  duration - entry.duration >= Double(3 * targetDuration) else { break }
            duration -= entry.duration
            if entry.discontinuity { discontinuitySequence += 1 }
            removed += 1
        }
        entries.removeFirst(removed)
    }

    func render(endList: Bool = false) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)",
            "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        for entry in entries {
            if entry.discontinuity {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            lines.append("#EXTINF:\(Self.formattedDuration(entry.duration)),")
            lines.append(entry.filename)
        }
        if endList {
            lines.append("#EXT-X-ENDLIST")
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
