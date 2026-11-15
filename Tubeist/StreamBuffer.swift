import Foundation

/// Frozen when a stream starts. The value limits waiting media, not a fixed
/// delay: healthy uploads always begin immediately.
enum StreamBuffering: Int, CaseIterable, Sendable {
    case stayLive = 0
    case preserve15 = 15
    case preserve30 = 30
    case preserve60 = 60

    var preservesFootage: Bool { self != .stayLive }
    var duration: TimeInterval { preservesFootage ? Double(rawValue) : 10 }
    var label: String { preservesFootage ? "Preserve up to \(rawValue) seconds" : "Stay live (default)" }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.integer(forKey: "StreamBuffering")) ?? .stayLive
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "StreamBuffering")
    }
}

enum StreamBufferError: LocalizedError, CustomStringConvertible {
    case storageUnavailable
    case unreadable
    case oversized

    var description: String {
        switch self {
        case .storageUnavailable: "Could not save the upload buffer. Check the iPhone's free storage."
        case .unreadable: "Could not read the saved upload buffer."
        case .oversized: "The upload buffer exceeded its storage limit."
        }
    }
    var errorDescription: String? { description }
}

/// Disk entries retain only metadata in RAM. Read one body for the active
/// transaction; the uploader then owns its immutable bytes through all retries.
struct BufferedStreamFragment {
    private let metadata: Fragment
    let fileURL: URL?
    let byteCount: Int
    var sequence: Int { metadata.sequence }
    var duration: Double { metadata.duration }
    var type: Fragment.SegmentType { metadata.type }

    init(_ fragment: Fragment, fileURL: URL? = nil) {
        self.fileURL = fileURL
        byteCount = fragment.segment.count
        metadata = Fragment(sequence: fragment.sequence, segment: fileURL == nil ? fragment.segment : Data(),
                            duration: fragment.duration, discontinuity: fragment.discontinuity,
                            type: fragment.type, container: fragment.container)
    }

    func read() throws -> Fragment {
        guard let fileURL else { return metadata }
        guard let data = try? Data(contentsOf: fileURL), data.count == byteCount else {
            throw StreamBufferError.unreadable
        }
        return Fragment(sequence: sequence, segment: data, duration: duration,
                        discontinuity: metadata.discontinuity, type: type, container: metadata.container)
    }

    func removeFile() throws {
        if let fileURL {
            do { try FileManager.default.removeItem(at: fileURL) }
            catch { throw StreamBufferError.storageUnavailable }
        }
    }
}

/// Owned serially by one upload sink. Files are temporary, never a recording
/// or a cross-launch stream resume mechanism. Each session has its own directory.
final class StreamDiskBuffer {
    static let maximumBytes = 512 * 1024 * 1024
    static let maximumFragments = 600
    let directory: URL

    // Once per process, remove abandoned files from a crash/force-quit. Later
    // sessions must not remove directories belonging to another active sink.
    private static let root: URL = {
        let root = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("TubeistUploadBuffers", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    init(parentDirectory: URL? = nil) throws {
        do {
            let parent = parentDirectory ?? Self.root
            directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { throw StreamBufferError.storageUnavailable }
    }

    func store(_ fragment: Fragment) throws -> BufferedStreamFragment {
        guard fragment.segment.count <= Self.maximumBytes else { throw StreamBufferError.oversized }
        let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("segment")
        do { try fragment.segment.write(to: file, options: .atomic) }
        catch { throw StreamBufferError.storageUnavailable }
        return BufferedStreamFragment(fragment, fileURL: file)
    }

    // Normal reads/discards remove each file. Also clean up on failure,
    // cancellation, replacement, or teardown; next launch retries any leftovers.
    deinit { try? FileManager.default.removeItem(at: directory) }
}
