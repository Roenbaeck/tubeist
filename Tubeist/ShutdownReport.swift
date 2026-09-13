//
//  ShutdownReport.swift
//  Tubeist
//

import Foundation

enum ShutdownComponentStatus: Sendable, Equatable {
    case notRequested
    case completed
    case failed(String)

    var failedMessage: String? {
        if case .failed(let message) = self { message } else { nil }
    }
}

struct ContentPackagingShutdownReport: Sendable, Equatable {
    let assetWriter: ShutdownComponentStatus
    let fragmentDispatch: ShutdownComponentStatus
    let recording: ShutdownComponentStatus

    static let notRequested = ContentPackagingShutdownReport(
        assetWriter: .notRequested,
        fragmentDispatch: .notRequested,
        recording: .notRequested
    )

    var succeeded: Bool {
        assetWriter.failedMessage == nil &&
        fragmentDispatch.failedMessage == nil &&
        recording.failedMessage == nil
    }
}

struct ContentPackagingShutdownError: LocalizedError, Sendable, Equatable {
    let report: ContentPackagingShutdownReport

    var errorDescription: String? {
        report.failureDescriptions.joined(separator: "; ")
    }
}

enum StreamStopOutcome: Sendable, Equatable {
    case alreadyIdle
    case stopped
}

struct StreamStopResult: Sendable, Equatable {
    let outcome: StreamStopOutcome
    let captureIntake: ShutdownComponentStatus
    let packaging: ContentPackagingShutdownReport
    let youTubeUpload: ShutdownComponentStatus

    static let alreadyIdle = StreamStopResult(
        outcome: .alreadyIdle,
        captureIntake: .notRequested,
        packaging: .notRequested,
        youTubeUpload: .notRequested
    )

    var succeeded: Bool {
        captureIntake.failedMessage == nil &&
        packaging.succeeded &&
        youTubeUpload.failedMessage == nil
    }
}

struct StreamShutdownError: LocalizedError, Sendable, Equatable {
    let report: StreamStopResult

    var errorDescription: String? {
        let descriptions = [
            report.captureIntake.failedMessage.map { "Capture intake: \($0)" }
        ].compactMap { $0 } + report.packaging.failureDescriptions + [
            report.youTubeUpload.failedMessage.map { "YouTube upload: \($0)" }
        ].compactMap { $0 }
        return descriptions.isEmpty
            ? "Stream shutdown did not complete"
            : descriptions.joined(separator: "; ")
    }
}

private extension ContentPackagingShutdownReport {
    var failureDescriptions: [String] {
        [
            assetWriter.failedMessage.map { "Media writer: \($0)" },
            fragmentDispatch.failedMessage.map { "Fragment ordering: \($0)" },
            recording.failedMessage.map { "Local recording: \($0)" },
        ].compactMap { $0 }
    }
}
