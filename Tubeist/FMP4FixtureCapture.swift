//
//  FMP4FixtureCapture.swift
//  Tubeist
//

#if DEBUG
import Foundation

actor FMP4FixtureCapture {
    static let shared = FMP4FixtureCapture()

    private struct ManifestEntry: Codable {
        let sequence: Int
        let filename: String
        let duration: Double
        let type: String
        let byteCount: Int
    }

    private let maximumMediaFragments = 6
    private var folder: URL?
    private var entries: [ManifestEntry] = []
    private var mediaFragmentCount = 0

    func capture(_ fragment: Fragment) {
        guard Settings.captureRemuxFixtures else { return }
        if fragment.type == .initialization {
            beginSession()
        }
        guard let folder else { return }
        if fragment.type != .initialization,
           mediaFragmentCount >= maximumMediaFragments {
            return
        }

        let filename: String
        switch fragment.type {
        case .initialization:
            filename = "initialization.mp4"
        case .separable:
            filename = String(format: "fragment_%04d.m4s", fragment.sequence)
            mediaFragmentCount += 1
        case .finalization:
            filename = String(format: "fragment_%04d_final.m4s", fragment.sequence)
            mediaFragmentCount += 1
        }

        do {
            try fragment.segment.write(to: folder.appendingPathComponent(filename), options: .atomic)
            entries.append(ManifestEntry(
                sequence: fragment.sequence,
                filename: filename,
                duration: fragment.duration,
                type: fragment.segmentType(),
                byteCount: fragment.segment.count
            ))
            try writeManifest(in: folder)
            if mediaFragmentCount == maximumMediaFragments {
                Settings.captureRemuxFixtures = false
                LOG("Captured direct-HLS fMP4 fixture set in the app Documents folder", level: .info)
            }
        } catch {
            LOG("Could not capture fMP4 fixture: \(error.localizedDescription)", level: .warning)
        }
    }

    private func beginSession() {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            LOG("Could not access Documents for fMP4 fixture capture", level: .warning)
            return
        }
        let identifier = HLSMediaPlaylist.makeSessionIdentifier()
        let folder = documents
            .appendingPathComponent("TubeistRemuxFixtures", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.folder = folder
            entries.removeAll(keepingCapacity: true)
            mediaFragmentCount = 0
        } catch {
            self.folder = nil
            LOG("Could not create fMP4 fixture folder: \(error.localizedDescription)", level: .warning)
        }
    }

    private func writeManifest(in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(
            to: folder.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }
}
#endif
