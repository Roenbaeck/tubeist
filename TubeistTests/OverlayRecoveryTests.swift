import Network
import Testing
import UIKit
import WebKit
@testable import Tubeist

@MainActor
@Suite(.serialized)
struct OverlayRecoveryTests {
    private let retryPolicy = OverlayRetryPolicy(initialDelay: 0.05, maximumDelay: 0.1, requestTimeout: 10)

    @Test func coveredOverlayKeepsCapturingPageUpdatesWithoutReloading() async throws {
        let server = try OverlayHTTPTestServer(replies: [.html("Score")])
        try await server.start()
        defer { server.stop() }
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: retryPolicy)
        let webView = overlay.createWebView(width: 320, height: 180)
        let window = display(webView)
        defer { window.isHidden = true }
        defer { overlay.prepareForRemoval() }
        try await waitUntil { overlay.getOverlayImage() != nil }
        let initialImage = try #require(overlay.getOverlayImage())
        let initialPixels = try #require(initialImage.pngData())

        // Battery Saving Mode covers the live web view with an opaque sibling.
        let cover = UIView(frame: webView.frame)
        cover.backgroundColor = .black
        webView.superview?.addSubview(cover)
        _ = try await webView.evaluateJavaScript("document.body.innerHTML = '<div style=\"position:fixed;inset:0;background:red\"></div>'")
        try await waitUntil {
            guard let image = overlay.getOverlayImage(), image !== initialImage else { return false }
            return image.pngData() != initialPixels
        }
        let updatedImage = try #require(overlay.getOverlayImage()?.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(updatedImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        // The snapshot must contain the updated page, not the black cover or
        // an empty image produced because the web view is no longer visible.
        #expect(pixel[0] > 200 && pixel[1] < 50 && pixel[2] < 50 && pixel[3] > 200)
        #expect(overlay.getWebView() === webView)
        #expect(server.requests.count == 1)
    }

    @Test func failedStartupRecoversThroughNetworkAndServerErrors() async throws {
        let server = try OverlayHTTPTestServer(replies: [.disconnect, .status(503), .html("Recovered")])
        try await server.start()
        defer { server.stop() }
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: retryPolicy)
        let webView = overlay.createWebView(width: 320, height: 180)
        let window = display(webView)
        defer { window.isHidden = true }
        defer { overlay.prepareForRemoval() }

        try await waitUntil { try await webView.evaluateJavaScript("document.title") as? String == "Recovered" }
        try await waitUntil { overlay.getOverlayImage() != nil }
        #expect(overlay.getWebView() === webView)
        #expect(server.requests.count == 3)
        #expect(server.requests.allSatisfy { $0.hasPrefix("GET /overlay?source=fixture HTTP/") })
        // Successful recovery stops retries rather than refreshing a live page.
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.count == 3)
    }

    @Test func unresponsiveRequestTimesOutAndRetries() async throws {
        let server = try OverlayHTTPTestServer(replies: [.stall, .html("After timeout")])
        try await server.start()
        defer { server.stop() }
        // Only this fixture uses a short request timeout. Other tests allow
        // normal WebKit process startup without incidental network timeouts.
        let policy = OverlayRetryPolicy(initialDelay: 0.05, maximumDelay: 0.1, requestTimeout: 2)
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: policy)
        let webView = overlay.createWebView(width: 320, height: 180)
        defer { overlay.prepareForRemoval() }

        try await waitUntil { try await webView.evaluateJavaScript("document.title") as? String == "After timeout" }
        #expect(server.requests.count == 2)
    }

    @Test func staticImageRecoversAfterServerFailure() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let png = try #require(renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
        let server = try OverlayHTTPTestServer(replies: [.status(502), .png(png)])
        try await server.start()
        defer { server.stop() }
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: retryPolicy)
        let webView = overlay.createWebView(width: 320, height: 180)
        let window = display(webView)
        defer { window.isHidden = true }
        defer { overlay.prepareForRemoval() }

        try await waitUntil {
            try await webView.evaluateJavaScript("document.images.length === 1 && document.images[0].naturalWidth > 0") as? Bool == true
        }
        try await waitUntil { overlay.getOverlayImage() != nil }
        #expect(server.requests.count == 2)
    }

    @Test func reloadsAndProcessRecoveryKeepDOMHandlerUsable() async throws {
        let server = try OverlayHTTPTestServer(replies: [.html("First"), .html("Second"), .html("Third")])
        try await server.start()
        defer { server.stop() }
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: retryPolicy)
        let webView = overlay.createWebView(width: 320, height: 180)
        defer { overlay.prepareForRemoval() }

        try await waitUntil { try await webView.evaluateJavaScript("document.title") as? String == "First" }
        overlay.webViewWebContentProcessDidTerminate(webView)
        try await waitUntil { try await webView.evaluateJavaScript("document.title") as? String == "Second" }
        webView.reload()
        try await waitUntil { try await webView.evaluateJavaScript("document.title") as? String == "Third" }
        // Exercise the script bridge after three successful navigations. The
        // old registration in didFinish would throw on the second HTML load.
        let handlerType = try await webView.evaluateJavaScript("typeof window.webkit.messageHandlers.domChanged.postMessage")
        #expect(handlerType as? String == "function")
        _ = try await webView.evaluateJavaScript("document.body.textContent = 'Updated'; window.webkit.messageHandlers.domChanged.postMessage('DOM changed'); true")
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.count == 3)
    }

    @Test func replacingAnUnfinishedNavigationDoesNotCauseExtraRetries() async throws {
        let server = try OverlayHTTPTestServer(replies: [.stall, .html("Replacement")])
        try await server.start()
        defer { server.stop() }
        let policy = OverlayRetryPolicy(initialDelay: 0.05, maximumDelay: 0.1, requestTimeout: 10)
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: policy)
        let webView = overlay.createWebView(width: 320, height: 180)
        defer { overlay.prepareForRemoval() }

        try await waitUntil { server.requests.count == 1 }
        overlay.reload()
        try await waitUntil { try await webView.evaluateJavaScript("document.title") as? String == "Replacement" }
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.count == 2)
    }

    @Test func removalCancelsPendingRetry() async throws {
        let server = try OverlayHTTPTestServer(replies: [.status(503)])
        try await server.start()
        defer { server.stop() }
        let policy = OverlayRetryPolicy(initialDelay: 0.5, maximumDelay: 0.5, requestTimeout: 10)
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: policy)
        let webView = overlay.createWebView(width: 320, height: 180)
        defer { overlay.prepareForRemoval() }

        try await waitUntil { server.requests.count == 1 && !webView.isLoading }
        overlay.prepareForRemoval()
        try await Task.sleep(for: .milliseconds(800))
        #expect(server.requests.count == 1)
        #expect(overlay.getWebView() == nil)
        #expect(overlay.getOverlayImage() == nil)
    }

    @Test func laterServerErrorPreservesLastSuccessfulSnapshot() async throws {
        let server = try OverlayHTTPTestServer(replies: [.html("Good overlay"), .status(503)])
        try await server.start()
        defer { server.stop() }
        let policy = OverlayRetryPolicy(initialDelay: 0.5, maximumDelay: 0.5, requestTimeout: 10)
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: policy)
        let webView = overlay.createWebView(width: 320, height: 180)
        let window = display(webView)
        defer { window.isHidden = true }
        defer { overlay.prepareForRemoval() }

        try await waitUntil { overlay.getOverlayImage() != nil }
        let goodSnapshot = try #require(overlay.getOverlayImage())
        webView.reload()
        try await waitUntil { server.requests.count >= 2 && !webView.isLoading }
        #expect(overlay.getOverlayImage() === goodSnapshot)
        #expect(try await webView.evaluateJavaScript("document.title") as? String == "Good overlay")
    }

    @Test func explicitRefreshReloadsAllAppliedOverlaysIncludingHealthyPages() async throws {
        let firstServer = try OverlayHTTPTestServer(replies: [.html("First before"), .html("First after")])
        let secondServer = try OverlayHTTPTestServer(replies: [.html("Second before"), .html("Second after")])
        let removedServer = try OverlayHTTPTestServer(replies: [.html("Removed")])
        try await firstServer.start()
        defer { firstServer.stop() }
        try await secondServer.start()
        defer { secondServer.stop() }
        try await removedServer.start()
        defer { removedServer.stop() }
        let bundler = OverlayBundler()
        let first = Overlay(url: firstServer.url, bundler: bundler, retryPolicy: retryPolicy)
        let second = Overlay(url: secondServer.url, bundler: bundler, retryPolicy: retryPolicy)
        let removed = Overlay(url: removedServer.url, bundler: bundler, retryPolicy: retryPolicy)
        let firstView = first.createWebView(width: 320, height: 180)
        let secondView = second.createWebView(width: 320, height: 180)
        let removedView = removed.createWebView(width: 320, height: 180)
        defer { first.prepareForRemoval(); second.prepareForRemoval(); removed.prepareForRemoval() }
        await bundler.addOverlay(url: firstServer.url, overlay: first)
        await bundler.addOverlay(url: secondServer.url, overlay: second)
        await bundler.addOverlay(url: removedServer.url, overlay: removed)
        try await waitUntil { try await firstView.evaluateJavaScript("document.title") as? String == "First before" }
        try await waitUntil { try await secondView.evaluateJavaScript("document.title") as? String == "Second before" }
        try await waitUntil { try await removedView.evaluateJavaScript("document.title") as? String == "Removed" }

        // The applied settings determine which pages reload, even if a removed
        // view is still registered while SwiftUI finishes updating the stack.
        await bundler.reloadOverlays(in: [secondServer.url, firstServer.url])
        try await waitUntil { try await firstView.evaluateJavaScript("document.title") as? String == "First after" }
        try await waitUntil { try await secondView.evaluateJavaScript("document.title") as? String == "Second after" }
        #expect(first.getWebView() === firstView)
        #expect(second.getWebView() === secondView)
        #expect(firstServer.requests.count == 2)
        #expect(secondServer.requests.count == 2)
        #expect(removedServer.requests.count == 1)
    }

    @Test func explicitRefreshBypassesPendingRetryDelay() async throws {
        let server = try OverlayHTTPTestServer(replies: [.status(503), .html("Refreshed")])
        try await server.start()
        defer { server.stop() }
        let bundler = OverlayBundler()
        let policy = OverlayRetryPolicy(initialDelay: 30, maximumDelay: 30, requestTimeout: 10)
        let overlay = Overlay(url: server.url, bundler: bundler, retryPolicy: policy)
        let webView = overlay.createWebView(width: 320, height: 180)
        defer { overlay.prepareForRemoval() }
        await bundler.addOverlay(url: server.url, overlay: overlay)
        try await waitUntil { server.requests.count == 1 && !webView.isLoading }

        await bundler.reloadOverlays(in: [server.url])
        // The 15s test deadline is shorter than the scheduled 30s retry.
        try await waitUntil { try await webView.evaluateJavaScript("document.title") as? String == "Refreshed" }
        #expect(server.requests.count == 2)
    }

    private func display(_ webView: WKWebView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.windowLevel = .normal + 1
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(webView)
        window.isHidden = false
        return window
    }

    private func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(15))
        while ContinuousClock().now < deadline {
            // Evaluating JS while the initial document is unavailable may fail.
            if (try? await condition()) == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw OverlayFixtureError.timedOut
    }
}

private enum OverlayFixtureError: Error { case timedOut }

/// A real loopback HTTP server exercises WebKit's navigation callbacks, cache
/// policy, and request timeout. No external overlay or physical phone is used.
@MainActor
private final class OverlayHTTPTestServer {
    enum Reply { case disconnect, stall, status(Int), html(String), png(Data) }
    private let listener: NWListener
    private let replies: [Reply]
    private var connections: [NWConnection] = []
    private var isReady = false
    private var isStopped = false
    private var failure: NWError?
    private(set) var requests: [String] = []

    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/overlay?source=fixture")! }

    init(replies: [Reply]) throws {
        self.replies = replies
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.isReady = true }
                if case .failed(let error) = state { self?.failure = error }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .main)
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !isReady {
            if let failure { throw failure }
            guard ContinuousClock().now < deadline else { throw OverlayFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stop() {
        isStopped = true
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard !isStopped else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue: .main)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.isStopped else { connection.cancel(); return }
                let received = accumulated + (data ?? Data())
                if let header = String(data: received, encoding: .utf8), header.contains("\r\n\r\n") {
                    self.respond(on: connection, header: header)
                } else if error == nil, !complete, received.count < 65_536 {
                    self.receiveRequest(on: connection, accumulated: received)
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private func respond(on connection: NWConnection, header: String) {
        let reply = replies[min(requests.count, replies.count - 1)]
        requests.append(header)
        let status: Int
        let contentType: String
        let body: Data
        switch reply {
        case .disconnect: connection.cancel(); return
        case .stall: return
        case .status(let code):
            status = code
            contentType = "text/html"
            body = Data("<title>Unavailable</title>Server unavailable".utf8)
        case .html(let title):
            status = 200
            contentType = "text/html"
            body = Data("<html><head><title>\(title)</title></head><body><div style='background:red;width:100px;height:100px'>Overlay</div></body></html>".utf8)
        case .png(let data):
            status = 200
            contentType = "image/png"
            body = data
        }
        let headers = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Unavailable")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: max-age=3600\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
