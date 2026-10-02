import AppIntents
import Foundation

/// LiveActivityIntent executes in the containing app. The session parameter
/// prevents a button on an old activity from capturing a newer stream.
@MainActor
enum HighlightRequestBridge {
    static var handler: (@MainActor @Sendable (UUID) async throws -> Void)?

    static func request(sessionID: UUID) async throws {
        guard let handler else { throw HighlightIntentError.unavailable }
        try await handler(sessionID)
    }
}

enum HighlightIntentError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Highlights are only available during an active Tubeist session." }
}

struct SaveHighlightIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Save Highlight"
    static let description = IntentDescription("Saves about 10 seconds before and 5 seconds after this moment as a local clip.")

    @Parameter(title: "Session") var sessionID: String

    init() {}
    init(sessionID: UUID) { self.sessionID = sessionID.uuidString }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: sessionID) else { throw HighlightIntentError.unavailable }
        try await HighlightRequestBridge.request(sessionID: id)
        return .result()
    }
}
