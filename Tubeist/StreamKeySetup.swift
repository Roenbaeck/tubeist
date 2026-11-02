import Foundation
import Observation

/// Owns the whole key-confirmation wait so progress and Start guards share
/// one lifetime. A cancelled/older operation can never start a stream later.
@Observable @MainActor
final class StreamKeySetup {
    private(set) var title: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    var isActive: Bool { title != nil }

    @discardableResult
    func begin(
        title: String,
        operation: @escaping @MainActor () async throws -> Void,
        start: @escaping @MainActor () -> Void,
        failure: @escaping @MainActor (Error) -> Void
    ) -> Task<Void, Never>? {
        guard !isActive else { return nil }
        let generation = UUID()
        self.generation = generation
        self.title = title
        let task = Task { @MainActor in
            do {
                try await operation()
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                self.finish()
                start()
            } catch {
                guard self.generation == generation else { return }
                self.finish()
                if !YouTubeDiagnostics.isCancellation(error) { failure(error) }
            }
        }
        self.task = task
        return task
    }

    func cancel() {
        task?.cancel()
        generation = UUID()
        finish()
    }

    private func finish() {
        task = nil
        title = nil
    }
}
