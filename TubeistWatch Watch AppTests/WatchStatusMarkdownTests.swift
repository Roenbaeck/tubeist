import Foundation
import Testing
@testable import TubeistWatch_Watch_App

struct WatchStatusMarkdownTests {
    @Test func preservesLinesUnicodeAndSupportedEmphasis() throws {
        let text = WatchStatusMarkdown.render("**Stage 👩‍💻**\n*Next speaker*\n\n`12:30` — العربية")
        #expect(String(text.characters) == "Stage 👩‍💻\nNext speaker\n\n12:30 — العربية")
        let title = try #require(text.range(of: "Stage 👩‍💻"))
        let subtitle = try #require(text.range(of: "Next speaker"))
        let time = try #require(text.range(of: "12:30"))
        #expect(text[title].inlinePresentationIntent == .stronglyEmphasized)
        #expect(text[subtitle].inlinePresentationIntent == .emphasized)
        #expect(text[time].inlinePresentationIntent == .code)
        let nested = WatchStatusMarkdown.render("***Both***")
        #expect(nested.inlinePresentationIntent == [.stronglyEmphasized, .emphasized])
    }

    @Test func discardsAllRemoteAttributesExceptApprovedTextStyles() {
        let source = "[Open](tubeist://start) ![Photo](https://example.com/photo.png)\n"
            + "<https://example.com> <b>HTML</b>\n~~Strike~~ ^[Color](color: 'red')"
        let text = WatchStatusMarkdown.render(source)
        #expect(String(text.characters) == "Open Photo\nhttps://example.com <b>HTML</b>\nStrike Color")
        #expect(text.runs.allSatisfy { $0.attributes == AttributeContainer() })

        var emphasizedLink = WatchStatusMarkdown.render("[**Title**](file:///private/example)")
        // Foundation versions differ on emphasis inside link labels. Any
        // attributes other than the approved text styles must still be absent.
        emphasizedLink.inlinePresentationIntent = nil
        #expect(emphasizedLink == AttributedString("Title"))
    }

    @Test func encodedControlsAndExtraLinesFallBackToLiteralSource() throws {
        for source in ["&#x202e;Hidden", "&#x2066;Hidden", "a&#1;b", "a&#9;b",
                       "Line" + String(repeating: "&#10;Line", count: 8), "![](https://example.com)"] {
            // All pass the transport checks; decoding must not bypass them.
            #expect(try ExternalStatusText.validate(Data(source.utf8)) == source)
            #expect(WatchStatusMarkdown.render(source) == AttributedString(source))
        }
    }

    @Test func escapedTeamNamesAndHTMLStayLiteral() {
        // Same escaping used by Scoreboard for user-provided team names.
        let source = #"\<b\>\*Team\*\</b\> \[A\]\(B\) \&copy\; \_C\_ \`D\` \\E"#
        let expected = "<b>*Team*</b> [A](B) &copy; _C_ `D` \\E"
        #expect(WatchStatusMarkdown.render(source) == AttributedString(expected))
    }

    @Test func plainTextAndUnfinishedMarkdownRemainReadable() {
        for source in ["Lund – Hylte\nSets: 1–2\nPoints: 23–21", "**Unfinished", "# Heading\n- Item"] {
            #expect(WatchStatusMarkdown.render(source) == AttributedString(source))
        }
    }
}
