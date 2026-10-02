// Save Highlight, contributed by Jan Lindhardsen. Clips reuse compressed
// fMP4 samples; selection rounds outward to segment boundaries.
import Foundation

enum HighlightError: LocalizedError, Equatable {
    case missingInitialization, folderUnavailable, unavailable, busy
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingInitialization: "No footage has been encoded yet"
        case .folderUnavailable: "The highlights folder is unavailable"
        case .unavailable: "Highlight buffering is unavailable for this session"
        case .busy: "A highlight is already being saved"
        case .writeFailed(let message): "Could not save the highlight: \(message)"
        }
    }
}

enum HighlightEvent: Sendable {
    case ready, unavailable, requested, saved(URL), failed(HighlightError)
}

@PipelineActor
final class HighlightRecorder {
    static let shared = HighlightRecorder()
    private static let beforeDuration: Double = 10
    private static let afterDuration: Double = 5
    // A time budget plus a byte budget keeps high-bitrate captures bounded.
    private static let byteBudget = 64 * 1_024 * 1_024

    private struct PendingHighlight {
        var fragments: [Fragment]
        var afterDuration: Double = 0
    }
    private var initialization: Fragment?
    private var ring: [Fragment] = []
    private var pending: PendingHighlight?
    private var sessionID = UUID()
    private var generation = UUID()
    private var active = false
    private var saving = false
    private var saves: [UUID: Task<Void, Never>] = [:]
    private var onEvent: (@Sendable (UUID, HighlightEvent) -> Void)?
    private let writer: HighlightFileWriter

    init(folder: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
         fileFactory: any RecordingFileCreating = SystemRecordingFileFactory(),
         normalize: Bool = true) {
        writer = HighlightFileWriter(folder: folder, fileFactory: fileFactory, normalize: normalize)
    }

    func setOnEvent(_ handler: @escaping @Sendable (UUID, HighlightEvent) -> Void) { onEvent = handler }

    func prepareForNewSession(sessionID: UUID = UUID(), enabled: Bool = true) {
        self.sessionID = sessionID
        generation = UUID()
        initialization = nil
        ring.removeAll(keepingCapacity: true)
        pending = nil
        active = enabled
        saving = false
    }

    func observe(_ fragment: Fragment) {
        guard active, fragment.container == .fragmentedMP4 else { return }
        if fragment.type == .initialization {
            initialization = fragment
            return
        }
        guard fragment.duration.isFinite, fragment.duration > 0 else { return }
        guard fragment.segment.count <= Self.byteBudget else {
            stopAfterFailure()
            return
        }
        if pending != nil {
            pending?.fragments.append(fragment)
            pending?.afterDuration += fragment.duration
            if pending!.fragments.reduce(0, { $0 + $1.segment.count }) > Self.byteBudget {
                pending = nil
                saving = false
                onEvent?(sessionID, .failed(.writeFailed("The highlight exceeded its memory budget")))
            } else if pending!.afterDuration >= Self.afterDuration {
                finishPending()
            }
        }
        let wasEmpty = ring.isEmpty
        ring.append(fragment)
        while ring.count > 1,
              ring.dropFirst().reduce(0, { $0 + $1.duration }) >= Self.beforeDuration ||
              ring.reduce(0, { $0 + $1.segment.count }) > Self.byteBudget {
            ring.removeFirst()
        }
        if wasEmpty, initialization != nil { onEvent?(sessionID, .ready) }
    }

    func requestHighlight(sessionID requestedSession: UUID? = nil) throws {
        guard requestedSession == nil || requestedSession == sessionID, active else { throw HighlightError.unavailable }
        guard initialization != nil, !ring.isEmpty else { throw HighlightError.missingInitialization }
        // A previous session may still be writing its final requested clip.
        // Keep at most one save in flight across rapid Stop/Start cycles too.
        guard !saving, saves.isEmpty else { throw HighlightError.busy }
        saving = true
        pending = PendingHighlight(fragments: ring)
        onEvent?(sessionID, .requested)
    }

    /// Final callbacks are drained before this call; a Stop saves a shorter
    /// post-roll instead of discarding the requested moment.
    func flushPending(waitForWrites: Bool = true) async {
        active = false
        finishPending()
        ring.removeAll()
        initialization = nil
        if waitForWrites {
            let outstanding = Array(saves.values)
            for task in outstanding { await task.value }
        }
    }

    func stopAfterFailure() {
        active = false
        ring.removeAll()
        initialization = nil
        if pending != nil {
            pending = nil
            saving = false
            onEvent?(sessionID, .failed(.unavailable))
        }
        onEvent?(sessionID, .unavailable)
    }

    private func finishPending() {
        guard let pending, let initialization else { return }
        self.pending = nil
        let generation = self.generation
        let sessionID = self.sessionID
        let saveID = UUID()
        let task = Task { [self, writer] in
            let result = await writer.save(initialization: initialization.segment, fragments: pending.fragments)
            saves[saveID] = nil
            switch result {
            case .success(let url): LOG("Saved highlight to \(url.lastPathComponent)", level: .info)
            case .failure(let error): LOG(error.localizedDescription, level: .warning)
            }
            guard generation == self.generation else { return }
            saving = false
            switch result {
            case .success(let url): onEvent?(sessionID, .saved(url))
            case .failure(let error): onEvent?(sessionID, .failed(error))
            }
        }
        saves[saveID] = task
    }
}

/// File work and MP4 timestamp rebasing run off both the capture actor and UI.
private actor HighlightFileWriter {
    let folder: URL?
    let fileFactory: any RecordingFileCreating
    let normalize: Bool
    init(folder: URL?, fileFactory: any RecordingFileCreating, normalize: Bool) {
        self.folder = folder
        self.fileFactory = fileFactory
        self.normalize = normalize
    }

    func save(initialization: Data, fragments: [Fragment]) -> Result<URL, HighlightError> {
        guard let folder else { return .failure(.folderUnavailable) }
        let url = folder.appendingPathComponent("highlight_\(HLSMediaPlaylist.makeSessionIdentifier()).mp4")
        var file: (any RecordingFileWriting)?
        do {
            let clip = normalize ? try HighlightClipAssembler(initialization: initialization, first: fragments.first?.segment) : nil
            file = try fileFactory.createFile(at: url)
            try file?.write(initialization)
            var offset = initialization.count
            for fragment in fragments {
                let data = try clip?.normalize(fragment.segment, fileOffset: offset) ?? fragment.segment
                try file?.write(data)
                offset += data.count
            }
            try file?.synchronize()
            try file?.close()
            return .success(url)
        } catch {
            try? file?.close()
            try? FileManager.default.removeItem(at: url)
            return .failure(.writeFailed(error.localizedDescription))
        }
    }
}
