import Network
import Testing
import UIKit
import WebKit
@testable import Tubeist

@MainActor
@Suite(.serialized)
struct OverlayRecoveryTests {
    private let retryPolicy = OverlayRetryPolicy(initialDelay: 0.05, maximumDelay: 0.1, requestTimeout: 10)

    @Test func unmountingStopsHighRateCaptureAndReleasesThePage() async throws {
        let server = try OverlayHTTPTestServer(replies: [.html("Background cleanup")])
        try await server.start()
        defer { server.stop() }
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: retryPolicy,
                              refreshRate: { .thirty })
        let webView = overlay.createWebView(width: 320, height: 180)
        let window = display(webView)
        defer { window.isHidden = true; overlay.prepareForRemoval() }
        try await waitUntil { overlay.getOverlayImage() != nil }
        _ = try await webView.evaluateJavaScript("document.querySelector('div').animate([{opacity: 0.2}, {opacity: 1}], {duration: 200, iterations: Infinity}); true")
        OverlayView.dismantleUIView(webView, coordinator: overlay)
        #expect(overlay.getWebView() == nil)
        #expect(webView.navigationDelegate == nil)
        // A pending WebKit callback cannot restart the worker or restore its
        // image after SwiftUI unmounts the view on backgrounding.
        overlay.captureWebViewImageOrSchedule()
        try await Task.sleep(for: .milliseconds(300))
        #expect(overlay.getOverlayImage() == nil)
        #expect(server.requests.count == 1)
    }

    @Test(arguments: ["width=device-width,initial-scale=1", "width=640,initial-scale=1", ""])
    func scaleChangesLiveContentAndSnapshotWithoutReloadingAndSurvivesReload(viewport: String) async throws {
        let fixture = Self.scaleFixture.replacingOccurrences(of: "width=device-width,initial-scale=1", with: viewport)
        let server = try OverlayHTTPTestServer(replies: [.page(fixture)])
        try await server.start()
        defer { server.stop() }
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: retryPolicy)
        let webView = overlay.createWebView(width: 320, height: 180)
        let window = display(webView)
        defer { window.isHidden = true; overlay.prepareForRemoval() }
        try await waitUntil { overlay.getOverlayImage() != nil }
        _ = try await webView.evaluateJavaScript("document.body.style.margin='0'; document.querySelector('div').textContent=''; true")
        overlay.captureWebViewImageOrSchedule()
        try await waitUntil {
            guard let box = overlay.getOverlayImage()?.roughBoundingBox(scaledWidth: 320), let image = overlay.getOverlayImage() else { return false }
            return box.width / (image.size.width * image.scale) < 0.8
        }
        let fullSize = try #require(overlay.getOverlayImage())
        let fullBounds = try #require(fullSize.roughBoundingBox(scaledWidth: 320))
        overlay.setScale(0.6)
        #expect(webView.pageZoom == 1)
        try await waitUntil {
            guard let image = overlay.getOverlayImage(), image !== fullSize,
                  let box = image.roughBoundingBox(scaledWidth: 320) else { return false }
            return box.width < fullBounds.width * 0.75
        }
        let scaledImage = try #require(overlay.getOverlayImage())
        let scaledBounds = try #require(scaledImage.roughBoundingBox(scaledWidth: 320))
        #expect(abs(scaledBounds.width / fullBounds.width - 0.6) < 0.08)
        #expect(abs(scaledBounds.height / fullBounds.height - 0.6) < 0.08)
        #expect(scaledImage.size == fullSize.size) // Output canvas stays the same size.
        #expect(server.requests.count == 1)
        overlay.setScale(1)
        try await waitUntil {
            guard let image = overlay.getOverlayImage(), image !== scaledImage,
                  let box = image.roughBoundingBox(scaledWidth: 320) else { return false }
            return abs(box.width - fullBounds.width) < 10
        }
        overlay.setScale(0.6)
        overlay.reload()
        try await waitUntil {
            guard server.requests.count == 2, !webView.isLoading,
                  let image = overlay.getOverlayImage(), image !== scaledImage,
                  let box = image.roughBoundingBox(scaledWidth: 320) else { return false }
            return abs(box.width / fullBounds.width - 0.6) < 0.08
        }
        #expect(webView.pageZoom == 1)
    }

    @Test(arguments: ["width=device-width,initial-scale=1", "width=640,initial-scale=1", ""])
    func initialOverlayScaleIsAppliedBeforeItsFirstSnapshot(viewport: String) async throws {
        let fixture = Self.scaleFixture.replacingOccurrences(of: "width=device-width,initial-scale=1", with: viewport)
        let server = try OverlayHTTPTestServer(replies: [.page(fixture)])
        try await server.start()
        defer { server.stop() }
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), scale: 0.6, retryPolicy: retryPolicy)
        let webView = overlay.createWebView(width: 320, height: 180)
        let window = display(webView)
        defer { window.isHidden = true; overlay.prepareForRemoval() }
        try await waitUntil { overlay.getOverlayImage() != nil }
        #expect(webView.pageZoom == 1)
        let image = try #require(overlay.getOverlayImage())
        let bounds = try #require(image.roughBoundingBox(scaledWidth: 320))
        #expect(bounds.width / (image.size.width * image.scale) < 0.23)
        overlay.setScale(1)
        try await waitUntil {
            guard let fullImage = overlay.getOverlayImage(), fullImage !== image,
                  let fullBounds = fullImage.roughBoundingBox(scaledWidth: 320) else { return false }
            return abs(bounds.width / fullBounds.width - 0.6) < 0.08
        }
    }

    private static let scaleFixture = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="margin:0"><div style="background:red;width:100px;height:100px"></div></body></html>
        """

    @Test(arguments: ["auto", "none", "100%"])
    func scoreboardTextAndGraphicsScaleTogether(textSizeAdjustment: String) async throws {
        // Wide scoreboard, fixed row heights and explicitly sized bold text:
        // older WebKit can scale the boxes while leaving these fonts full size.
        let fixture = """
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
            html { -webkit-text-size-adjust: \(textSizeAdjustment); }
            body { margin:0; background:transparent; }
            .board { position:absolute; left:10px; top:10px; width:630px; }
            .logo { float:left; width:90px; height:90px; background:lime; }
            .teams { float:left; margin-left:20px; font: bold 28px/1.3 Arial; }
            .row { width:320px; height:36px; margin-bottom:4px; background:blue; color:red; }
            .row span { font-size:28px; font-weight:bold; }
            </style></head><body><div class="board"><div class="logo"></div>
            <div class="teams"><div class="row"><span>Reunion 20 25</span></div>
            <div class="row"><span>Sollentuna 25 17</span></div></div></div></body></html>
            """
        let server = try OverlayHTTPTestServer(replies: [.page(fixture)])
        try await server.start()
        defer { server.stop() }
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: retryPolicy)
        let webView = overlay.createWebView(width: 640, height: 360)
        let window = display(webView)
        defer { window.isHidden = true; overlay.prepareForRemoval() }
        try await waitUntil { overlay.getOverlayImage() != nil }
        let original = try #require(overlay.getOverlayImage())
        let originalBoxes = try #require(colorBounds(original, channel: 2))
        let originalText = try #require(colorBounds(original, channel: 0))
        let originalLogo = try #require(colorBounds(original, channel: 1))
        overlay.setScale(0.5)
        try await waitUntil {
            guard let image = overlay.getOverlayImage(), image !== original,
                  let boxes = colorBounds(image, channel: 2) else { return false }
            return abs(boxes.width / originalBoxes.width - 0.5) < 0.05
        }
        let reduced = try #require(overlay.getOverlayImage())
        let text = try #require(colorBounds(reduced, channel: 0))
        let logo = try #require(colorBounds(reduced, channel: 1))
        #expect(abs(text.width / originalText.width - 0.5) < 0.06)
        #expect(abs(text.height / originalText.height - 0.5) < 0.06)
        #expect(abs(logo.width / originalLogo.width - 0.5) < 0.03)
        #expect(reduced.size == original.size)
        overlay.reload()
        try await waitUntil { server.requests.count == 2 && overlay.getOverlayImage() !== reduced }
        let reloaded = try #require(overlay.getOverlayImage())
        let reloadedText = try #require(colorBounds(reloaded, channel: 0))
        #expect(abs(reloadedText.width / originalText.width - 0.5) < 0.06)
        #expect(abs(reloadedText.height / originalText.height - 0.5) < 0.06)
        overlay.setScale(1)
        try await waitUntil {
            guard let image = overlay.getOverlayImage(), image !== reloaded,
                  let boxes = colorBounds(image, channel: 2) else { return false }
            return abs(boxes.width - originalBoxes.width) < 2
        }
        let restored = try #require(overlay.getOverlayImage())
        let restoredText = try #require(colorBounds(restored, channel: 0))
        #expect(abs(restoredText.width - originalText.width) < 2)
        #expect(abs(restoredText.height - originalText.height) < 2)
    }

    @Test func scalingKeepsFixedOverlaysAnchoredToTheBottomRight() async throws {
        let fixture = """
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
            <body style="margin:0"><div style="position:fixed;bottom:10px;right:10px;
            width:80px;height:40px;background:blue"></div></body></html>
            """
        let server = try OverlayHTTPTestServer(replies: [.page(fixture)])
        try await server.start()
        defer { server.stop() }
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: retryPolicy)
        let window = display(overlay.createWebView(width: 320, height: 180))
        defer { window.isHidden = true; overlay.prepareForRemoval() }
        try await waitUntil { overlay.getOverlayImage() != nil }
        let original = try #require(overlay.getOverlayImage())
        let originalBounds = try #require(colorBounds(original, channel: 2))
        overlay.setScale(0.5)
        try await waitUntil { overlay.getOverlayImage() !== original }
        let reduced = try #require(overlay.getOverlayImage())
        let bounds = try #require(colorBounds(reduced, channel: 2))
        let cgImage = try #require(reduced.cgImage)
        let width = CGFloat(min(640, cgImage.width))
        let height = width * CGFloat(cgImage.height) / CGFloat(cgImage.width)
        #expect(abs(bounds.width / originalBounds.width - 0.5) < 0.03)
        #expect(abs(bounds.height / originalBounds.height - 0.5) < 0.03)
        #expect(abs((width - bounds.maxX) - (width - originalBounds.maxX) * 0.5) < 2)
        #expect(abs((height - bounds.maxY) - (height - originalBounds.maxY) * 0.5) < 2)
    }

    private func colorBounds(_ image: UIImage, channel: Int) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        let width = min(640, cgImage.width)
        let height = cgImage.height * width / cgImage.width
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    if bytes[offset + channel] > 128,
                       bytes[offset + (channel + 1) % 3] < 80,
                       bytes[offset + (channel + 2) % 3] < 80 {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= minX else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

    @Test func rapidScaleChangesUseTheLatestValueAndResetRestoresPageZoom() async throws {
        let fixture = Self.scaleFixture.replacingOccurrences(of: "<html>", with: "<html style='zoom:1.25'>")
        let server = try OverlayHTTPTestServer(replies: [.page(fixture)])
        try await server.start()
        defer { server.stop() }
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: retryPolicy)
        let webView = overlay.createWebView(width: 320, height: 180)
        let window = display(webView)
        defer { window.isHidden = true; overlay.prepareForRemoval() }
        try await waitUntil { overlay.getOverlayImage() != nil }
        let original = try #require(overlay.getOverlayImage())
        let originalBounds = try #require(original.roughBoundingBox(scaledWidth: 320))
        overlay.setScale(0.6)
        overlay.setScale(2)
        overlay.setScale(0.25)
        try await waitUntil {
            guard let image = overlay.getOverlayImage(), image !== original,
                  let box = image.roughBoundingBox(scaledWidth: 320) else { return false }
            return abs(box.width / originalBounds.width - 0.25) < 0.05
        }
        let reduced = try #require(overlay.getOverlayImage())
        overlay.setScale(2)
        try await waitUntil {
            guard let image = overlay.getOverlayImage(), image !== reduced,
                  let box = image.roughBoundingBox(scaledWidth: 320) else { return false }
            return abs(box.width / originalBounds.width - 2) < 0.08
        }
        overlay.setScale(1)
        try await waitUntil {
            guard let image = overlay.getOverlayImage(),
                  let box = image.roughBoundingBox(scaledWidth: 320) else { return false }
            return abs(box.width - originalBounds.width) < 10
        }
        #expect(try await webView.evaluateJavaScript("document.documentElement.style.zoom") as? String == "1.25")
        #expect(server.requests.count == 1)
    }

    @Test func highRateRefreshesWithoutDOMChangesAndReloadAppliesNewRate() async throws {
        let server = try OverlayHTTPTestServer(replies: [.html("Animated"), .html("Reloaded")])
        try await server.start()
        defer { server.stop() }
        var rate = OverlayRefreshRate.thirty
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: retryPolicy,
                              refreshRate: { rate })
        let webView = overlay.createWebView(width: 320, height: 180)
        let window = display(webView)
        defer { window.isHidden = true }
        defer { overlay.prepareForRemoval() }
        try await waitUntil { overlay.getOverlayImage() != nil }
        let initialImage = try #require(overlay.getOverlayImage())
        // CSS animation changes pixels without mutating the DOM each frame.
        _ = try await webView.evaluateJavaScript("document.querySelector('div').animate([{opacity: 0.2}, {opacity: 1}], {duration: 200, iterations: Infinity}); true")
        try await waitUntil { overlay.getOverlayImage() !== initialImage }
        let animatedImage = try #require(overlay.getOverlayImage())
        try await waitUntil { overlay.getOverlayImage() !== animatedImage }
        #expect(server.requests.count == 1) // Snapshots never reload the URL.

        rate = .once
        overlay.reload()
        try await waitUntil { try await webView.evaluateJavaScript("document.title") as? String == "Reloaded" }
        // Allow a trailing change from the transparent-background injection.
        try await Task.sleep(for: .seconds(2))
        let reloadedImage = try #require(overlay.getOverlayImage())
        try await Task.sleep(for: .milliseconds(300))
        #expect(overlay.getOverlayImage() === reloadedImage)
        overlay.prepareForRemoval()
        try await Task.sleep(for: .milliseconds(100))
        #expect(overlay.getOverlayImage() == nil)
        #expect(server.requests.count == 2)
    }

    @Test func highRateIdlePageSkipsSnapshotsButAttributeChangesStillAppear() async throws {
        let server = try OverlayHTTPTestServer(replies: [.html("Idle")])
        try await server.start()
        defer { server.stop() }
        let overlay = Overlay(url: server.url, bundler: OverlayBundler(), retryPolicy: retryPolicy,
                              refreshRate: { .thirty })
        let webView = overlay.createWebView(width: 320, height: 180)
        let window = display(webView)
        defer { window.isHidden = true }
        defer { overlay.prepareForRemoval() }
        try await waitUntil { overlay.getOverlayImage() != nil }
        // Drain the initial page capture and the observer's initial dirty bit.
        try await Task.sleep(for: .seconds(1))
        let idle = try #require(overlay.getOverlayImage())
        try await Task.sleep(for: .milliseconds(400))
        #expect(overlay.getOverlayImage() === idle)
        _ = try await webView.evaluateJavaScript("document.querySelector('div').style.background = 'blue'")
        try await waitUntil { overlay.getOverlayImage() !== idle }

        // CSS rule edits bypass MutationObserver, but must still be captured.
        _ = try await webView.evaluateJavaScript("document.querySelector('div').removeAttribute('style'); const style = document.createElement('style'); style.textContent = 'div { width: 100px; height: 100px; background: red; }'; document.head.appendChild(style); true")
        try await Task.sleep(for: .milliseconds(500))
        let beforeRuleChange = try #require(overlay.getOverlayImage())
        _ = try await webView.evaluateJavaScript("document.styleSheets[0].cssRules[0].style.backgroundColor = 'green'")
        try await waitUntil { overlay.getOverlayImage() !== beforeRuleChange }

        let beforeAnimation = try #require(overlay.getOverlayImage())
        _ = try await webView.evaluateJavaScript("window.testAnimation = document.querySelector('div').animate([{opacity: 0.2}, {opacity: 1}], {duration: 60000, fill: 'forwards'}); true")
        try await waitUntil { overlay.getOverlayImage() !== beforeAnimation }
        try await waitUntil { try await webView.evaluateJavaScript("window.__tubeistOverlayChanges.wasAnimating") as? Bool == true }
        let beforeFinish = try #require(overlay.getOverlayImage())
        _ = try await webView.evaluateJavaScript("window.testAnimation.finish(); true")
        try await waitUntil { overlay.getOverlayImage() !== beforeFinish }
        try await Task.sleep(for: .milliseconds(500))
        let finished = try #require(overlay.getOverlayImage())
        try await Task.sleep(for: .milliseconds(300))
        #expect(overlay.getOverlayImage() === finished)
    }

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
    enum Reply { case disconnect, stall, status(Int), html(String), page(String), png(Data) }
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
        case .page(let html):
            status = 200
            contentType = "text/html"
            body = Data(html.utf8)
        }
        let headers = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Unavailable")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: max-age=3600\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
