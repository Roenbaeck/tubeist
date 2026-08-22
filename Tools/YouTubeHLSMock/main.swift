//
// Development-only socket integration runner for YouTubeHLSUploader.
//

import Foundation

private enum SocketValidationError: Error, CustomStringConvertible {
    case invalidArguments
    case unexpectedReceipt(YouTubeHLSUploadReceipt)
    case uploadUnexpectedlySucceeded(String)
    case unexpectedError(String)

    var description: String {
        switch self {
        case .invalidArguments:
            "Usage: uploader-socket-test <endpoint> <contract|reconnect|timeout|stop|cancel>"
        case .unexpectedReceipt(let receipt):
            "Unexpected upload receipt: \(receipt)"
        case .uploadUnexpectedlySucceeded(let scenario):
            "The \(scenario) upload unexpectedly succeeded"
        case .unexpectedError(let description):
            "Unexpected uploader error: \(description)"
        }
    }
}

private final class LocalhostTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@main
private struct YouTubeHLSUploaderSocketTest {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let endpointURL = URL(string: CommandLine.arguments[1]) else {
            throw SocketValidationError.invalidArguments
        }
        let scenario = CommandLine.arguments[2]
        let timeout: TimeInterval = scenario == "timeout" ? 0.15 : 2
        let transport = URLSessionYouTubeHLSHTTPTransport(
            requestTimeout: timeout,
            resourceTimeout: max(timeout * 4, 2),
            delegate: LocalhostTrustDelegate()
        )
        let uploader = try YouTubeHLSUploader(
            endpoint: YouTubeHLSEndpoint(developmentURL: endpointURL),
            sessionIdentifier: "socket_session",
            userAgent: "Apple / SocketTest / Tubeist-1",
            transport: transport,
            retryPolicy: YouTubeHLSRetryPolicy(
                maximumAttempts: 4,
                initialDelay: 0,
                maximumDelay: 0,
                jitterFraction: 0
            ),
            sleeper: { _ in }
        )

        switch scenario {
        case "contract":
            let first = try await uploader.upload(
                segment: Data([0x01, 0x02, 0x03]),
                duration: 2
            )
            let second = try await uploader.upload(
                segment: Data([0x04, 0x05]),
                duration: 2.5
            )
            guard first.sequence == 0, second.sequence == 1 else {
                throw SocketValidationError.unexpectedReceipt(second)
            }
            try await uploader.finish()

        case "reconnect", "timeout":
            let receipt = try await uploader.upload(
                segment: Data([0x01, 0x02, 0x03]),
                duration: 2
            )
            guard receipt.sequence == 0 else {
                throw SocketValidationError.unexpectedReceipt(receipt)
            }

        case "stop":
            let upload = Task {
                try await uploader.upload(
                    segment: Data([0x01, 0x02, 0x03]),
                    duration: 2
                )
            }
            try await Task.sleep(for: .milliseconds(100))
            await uploader.stop()
            try await requireStopped(upload, scenario: scenario)

        case "cancel":
            let upload = Task {
                try await uploader.upload(
                    segment: Data([0x01, 0x02, 0x03]),
                    duration: 2
                )
            }
            try await Task.sleep(for: .milliseconds(100))
            upload.cancel()
            try await requireStopped(upload, scenario: scenario)

        default:
            throw SocketValidationError.invalidArguments
        }

        await uploader.stop()
        print("Socket scenario passed: \(scenario)")
    }

    private static func requireStopped(
        _ upload: Task<YouTubeHLSUploadReceipt, Error>,
        scenario: String
    ) async throws {
        do {
            _ = try await upload.value
            throw SocketValidationError.uploadUnexpectedlySucceeded(scenario)
        } catch let error as YouTubeHLSUploadError {
            guard error == .stopped else {
                throw SocketValidationError.unexpectedError(error.description)
            }
        }
    }
}
