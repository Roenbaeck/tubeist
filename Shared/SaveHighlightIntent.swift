//
//  SaveHighlightIntent.swift
//  Tubeist
//
//  Types shared by the app and the TubeistLiveActivity widget extension, so
//  the widget's SwiftUI can build a Button(intent:) with this concrete type.
//  SaveHighlightIntent conforms to LiveActivityIntent, which ActivityKit
//  documents as always running its perform() in the containing app's
//  process (launching it in the background if needed) rather than the
//  widget extension's process — required here, since the encoded-fragment
//  buffer only exists in the main app's memory. HighlightRequestBridge is
//  the indirection that lets this file compile in the extension target too,
//  without linking the capture pipeline into it: the app sets `handler`
//  once at launch, the extension never does, so a stray call there is inert.
//

import AppIntents
import Foundation

enum HighlightRequestBridge {
    nonisolated(unsafe) static var handler: (@Sendable () -> Void)?
}

struct SaveHighlightIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Save Highlight"
    static let description = IntentDescription("Saves the last few seconds as a local highlight clip.")

    func perform() async throws -> some IntentResult {
        HighlightRequestBridge.handler?()
        return .result()
    }
}
