import Foundation

/// The content of an external status is opaque to both apps. These limits
/// bound transport and rendering work; they do not interpret its meaning.
enum ExternalStatusText {
    static let maximumBytes = 4_096
    static let maximumCharacters = 500
    static let maximumLines = 8
    static let freshnessInterval: TimeInterval = 30

    static func validate(_ data: Data) throws -> String {
        guard data.count <= maximumBytes else { throw ExternalStatusError.tooLarge }
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw ExternalStatusError.invalidText
        }
        let text = decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExternalStatusError.emptyText }
        guard text.count <= maximumCharacters,
              text.split(separator: "\n", omittingEmptySubsequences: false).count <= maximumLines else {
            throw ExternalStatusError.tooLarge
        }
        // Preserve ordinary Unicode, including RTL languages and emoji, but
        // reject invisible control characters and explicit bidi overrides.
        guard !text.unicodeScalars.contains(where: {
            ($0.value != 10 && $0.properties.generalCategory == .control)
                || (0x202A...0x202E).contains($0.value)
                || (0x2066...0x2069).contains($0.value)
        }) else { throw ExternalStatusError.invalidText }
        return text
    }
}

enum ExternalStatusError: Error, LocalizedError, Equatable {
    case invalidURL, invalidResponse, invalidText, emptyText, tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a complete HTTP or HTTPS URL for external status."
        case .invalidResponse: "The external status endpoint must return UTF-8 plain text."
        case .invalidText: "The external status contains unsupported text."
        case .emptyText: "The external status is empty."
        case .tooLarge: "The external status is too long."
        }
    }
}

struct ExternalStatusSnapshot: Codable, Sendable, Equatable {
    let text: String
    let receivedAt: Date

    init(text: String, receivedAt: Date) throws {
        self.text = try ExternalStatusText.validate(Data(text.utf8))
        self.receivedAt = receivedAt
    }

    private enum CodingKeys: String, CodingKey { case text, receivedAt }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(text: values.decode(String.self, forKey: .text),
                      receivedAt: values.decode(Date.self, forKey: .receivedAt))
    }

    func isFresh(at now: Date) -> Bool {
        receivedAt <= now.addingTimeInterval(5)
            && now.timeIntervalSince(receivedAt) < ExternalStatusText.freshnessInterval
    }
}
