//
//  HighlightRecorder.swift
//  Tubeist
//
//  Assembles short local clips around the moment a highlight is requested,
//  reusing the already-encoded fMP4 fragments the live recording writes to
//  disk (ContentPackager.swift). No re-encoding: clips round outward to the
//  nearest 2 s fragment boundary rather than being frame-exact.
//

import Foundation

enum HighlightError: LocalizedError, Equatable {
    case missingInitialization
    case folderUnavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingInitialization: "No footage has been encoded yet"
        case .folderUnavailable: "The highlights folder is unavailable"
        case .writeFailed(let message): "Could not save the highlight: \(message)"
        }
    }
}

/// Fired at each stage of a highlight save so the UI can acknowledge the
/// button press immediately, well before assembly (which waits on live
/// "after" fragments) actually finishes.
enum HighlightEvent: Sendable {
    case requested
    case saved(URL)
    case failed(HighlightError)
}

@PipelineActor
final class HighlightRecorder {
    static let shared = HighlightRecorder()

    /// Comfortably covers the requested ~10 s "before" window at 2 s/fragment
    /// (FRAGMENT_DURATION in Constants.swift), with a little headroom.
    private static let ringCapacity = 7
    private static let minimumAfterDuration: Double = 5

    private struct PendingHighlight {
        var before: [Fragment]
        var after: [Fragment] = []
        var afterDuration: Double = 0
    }

    private var initializationFragment: Fragment?
    private var ring: [Fragment] = []
    private var pending: [PendingHighlight] = []
    private let folder: URL?
    private let fileFactory: any RecordingFileCreating
    private var onEvent: (@Sendable (HighlightEvent) -> Void)?

    init(
        folder: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
        fileFactory: any RecordingFileCreating = SystemRecordingFileFactory()
    ) {
        self.folder = folder
        self.fileFactory = fileFactory
    }

    func setOnEvent(_ handler: @escaping @Sendable (HighlightEvent) -> Void) {
        onEvent = handler
    }

    /// Clears buffered fragments and abandons any highlight that never
    /// finished, ready for a new streaming session.
    func prepareForNewSession() {
        initializationFragment = nil
        ring.removeAll(keepingCapacity: true)
        pending.removeAll()
    }

    /// Feeds every fragment the live pipeline produces, in delivery order.
    func observe(_ fragment: Fragment) {
        guard fragment.type != .initialization else {
            initializationFragment = fragment
            return
        }
        for index in pending.indices {
            pending[index].after.append(fragment)
            pending[index].afterDuration += fragment.duration
        }
        ring.append(fragment)
        if ring.count > Self.ringCapacity { ring.removeFirst() }
        finishReadyHighlights()
    }

    /// Starts a new highlight capturing the currently buffered "before"
    /// fragments; it finishes once enough "after" fragments have arrived.
    /// Fires .requested immediately, well before the highlight is actually
    /// assembled, so the UI can acknowledge the press right away.
    func requestHighlight() {
        pending.append(PendingHighlight(before: ring))
        onEvent?(.requested)
        finishReadyHighlights()
    }

    /// Best-effort: assembles every highlight still waiting for its "after"
    /// window, using whatever arrived before the stream stopped producing
    /// fragments, rather than silently discarding a requested highlight.
    func flushPending() {
        let outstanding = pending
        pending.removeAll()
        for highlight in outstanding { assemble(highlight) }
    }

    private func finishReadyHighlights() {
        guard !pending.isEmpty else { return }
        var stillPending: [PendingHighlight] = []
        stillPending.reserveCapacity(pending.count)
        for highlight in pending {
            if highlight.afterDuration >= Self.minimumAfterDuration {
                assemble(highlight)
            } else {
                stillPending.append(highlight)
            }
        }
        pending = stillPending
    }

    private func assemble(_ highlight: PendingHighlight) {
        guard let initializationFragment else {
            complete(.failure(.missingInitialization))
            return
        }
        guard let folder else {
            complete(.failure(.folderUnavailable))
            return
        }
        var data = initializationFragment.segment
        for fragment in highlight.before { data.append(fragment.segment) }
        for fragment in highlight.after { data.append(fragment.segment) }
        let url = folder.appendingPathComponent("highlight_\(Self.timestamp()).mp4")
        do {
            let file = try fileFactory.createFile(at: url)
            try file.write(data)
            try file.synchronize()
            try file.close()
            complete(.success(url))
        } catch {
            complete(.failure(.writeFailed(error.localizedDescription)))
        }
    }

    private func complete(_ result: Result<URL, HighlightError>) {
        switch result {
        case .success(let url):
            LOG("Saved highlight to \(url.lastPathComponent)", level: .info)
            onEvent?(.saved(url))
        case .failure(let error):
            LOG("Could not save highlight: \(error.localizedDescription)", level: .error)
            onEvent?(.failed(error))
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
