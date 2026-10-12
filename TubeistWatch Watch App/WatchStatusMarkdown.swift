import Foundation

/// Presentation only: the status remains an opaque string throughout the phone
/// relay. Call with text validated by ExternalStatusSnapshot.
enum WatchStatusMarkdown {
    static func render(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .throwError
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }

        // Markdown entities can introduce characters that were absent from the
        // validated source (for example, an encoded bidi override or newline).
        let visibleText = String(parsed.characters)
        // Older watchOS parsers use an object-replacement character for an
        // image without alt text. Fall back rather than display a blank object.
        guard !visibleText.contains("\u{fffc}"),
              let checked = try? ExternalStatusText.validate(Data(visibleText.utf8)),
              checked == visibleText else {
            return AttributedString(source)
        }

        let allowed: InlinePresentationIntent = [.stronglyEmphasized, .emphasized, .code]
        var result = AttributedString()
        for run in parsed.runs {
            // Rebuild each run from characters, copying only approved styles.
            // Links and images become their labels, with no URL or action;
            // HTML remains text. No remote attributes reach SwiftUI directly.
            var text = AttributedString(String(parsed[run.range].characters))
            let styles = (run.inlinePresentationIntent ?? []).intersection(allowed)
            if !styles.isEmpty { text.inlinePresentationIntent = styles }
            result.append(text)
        }
        return result
    }
}
