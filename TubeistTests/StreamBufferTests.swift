import Foundation
import Testing
@testable import Tubeist

struct StreamBufferTests {
    @Test func existingOrInvalidPreferencesStayLiveAndEveryOptionRoundTrips() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(StreamBuffering.load(from: defaults) == .stayLive)
        defaults.set(999, forKey: "StreamBuffering")
        #expect(StreamBuffering.load(from: defaults) == .stayLive)
        for mode in StreamBuffering.allCases {
            mode.save(to: defaults)
            #expect(StreamBuffering.load(from: defaults) == mode)
        }
    }

    @Test func diskRoundTripPreservesBytesAndMetadataAndCleansUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var buffer: StreamDiskBuffer? = try StreamDiskBuffer(parentDirectory: root)
        let folder = try #require(buffer?.directory)
        let original = Fragment(sequence: 42, segment: Data((0...255).map(UInt8.init)), duration: 1.7,
                                discontinuity: true, type: .finalization, container: .mpegTransportStream)
        let stored = try #require(buffer).store(original)
        let file = try #require(stored.fileURL)
        #expect(try Data(contentsOf: file) == original.segment)
        let loaded = try stored.read()
        #expect(loaded.segment == original.segment)
        #expect(loaded.sequence == 42 && loaded.duration == 1.7 && loaded.discontinuity)
        #expect(loaded.type == .finalization && loaded.container == .mpegTransportStream)
        try stored.removeFile()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        _ = try #require(buffer).store(original)
        buffer = nil
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func sessionsHaveSeparateDirectoriesAndMissingDataFailsVisibly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var first: StreamDiskBuffer? = try StreamDiskBuffer(parentDirectory: root)
        let second = try StreamDiskBuffer(parentDirectory: root)
        let fragment = Fragment(sequence: 0, segment: Data([1, 2, 3]), duration: 2)
        let old = try #require(first).store(fragment)
        let current = try second.store(fragment)
        first = nil
        #expect(throws: StreamBufferError.self) { try old.read() }
        #expect(try current.read().segment == fragment.segment)
        try Data([1]).write(to: #require(current.fileURL))
        #expect(throws: StreamBufferError.self) { try current.read() }
        try FileManager.default.removeItem(at: second.directory)
        #expect(throws: StreamBufferError.self) { try second.store(fragment) }
    }
}
