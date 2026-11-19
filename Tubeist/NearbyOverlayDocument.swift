import Foundation

final class NearbyOverlayDocument: Sendable {
    static let sourceURL = URL(string: "tubeist-nearby://overlay")!

    let id = UUID()
    let name: String
    let directory: URL
    let entryURL: URL

    init(package: NearbyOverlayWire.Package) throws {
        let trimmedName = package.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.utf8.count <= 100,
              (1...64).contains(package.files.count),
              package.files[package.entry] != nil,
              ["html", "htm"].contains((package.entry as NSString).pathExtension.lowercased()),
              package.files.keys.allSatisfy(Self.isSafePath) else {
            throw NearbyOverlayWire.FormatError.invalidChunk
        }
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("NearbyOverlay-\(id.uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
            for (path, data) in package.files {
                let destination = directory.appendingPathComponent(path)
                try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination)
            }
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
        self.name = trimmedName
        self.directory = directory
        self.entryURL = directory.appendingPathComponent(package.entry)
    }

    private static func isSafePath(_ path: String) -> Bool {
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        guard !path.isEmpty, path.utf8.count <= 160 else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." && component.allSatisfy(allowed.contains)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
