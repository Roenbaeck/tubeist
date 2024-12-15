//
//  OverlayBundler.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-04.
//

// @preconcurrency need to avoid non-sendable CIImage when calling overlay.getOverlayImage()
@preconcurrency import SwiftUI
import WebKit
// import Observation

final class Overlay: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let url: URL
    private let bundler: OverlayBundler
    private var webView: WKWebView?
    private var overlayImage: CIImage?
    private var lastCaptureTime: Date = Date.distantPast
    private var captureTimer: Timer?
    private let minimumCaptureInterval: TimeInterval = 1.0 // at least 1 second between snapshots
    
    init(url: URL, bundler: OverlayBundler) {
        self.url = url
        self.bundler = bundler
        super.init()
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "domChanged" {
            self.captureWebViewImageOrSchedule()
        }
    }

    func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: CAPTURE_WIDTH, height: CAPTURE_HEIGHT), configuration: config)
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.zoomScale = 1.0
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.contentScaleFactor = 1.0
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.contentInset = UIEdgeInsets.zero
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        webView.load(URLRequest(url: url))
        
        self.webView = webView
        return webView
    }

    func getOverlayImage() -> CIImage? {
        guard let overlayImage = self.overlayImage else {
            LOG("No overlay image captured yet")
            return nil
        }
        return overlayImage
    }
    
    func getWebView() -> WKWebView? { // Make this optional
        return webView
    }
    
    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        LOG("Web view finished loading")
        let script = """
            (function() {
                // Create a MutationObserver to watch for DOM changes
                const observer = new MutationObserver(mutationsList => {
                    // Trigger a Swift callback when a change is detected
                    window.webkit.messageHandlers.domChanged.postMessage('DOM changed');
                });

                // Start observing the entire document
                observer.observe(document, { subtree: true, childList: true, characterData: true });
            })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                LOG("Error injecting JavaScript: \(error)")
            }
        }

        webView.configuration.userContentController.add(self, name: "domChanged")
    }
    
    // Both throttling and debouncing the capture so we ensure that at least the minimum capture interval passes
    // between snapshots, and that the last call is always executed even in a situation where several are coming
    // in quick succession
    private func captureWebViewImageOrSchedule() {
        let currentTime = Date()
        if currentTime.timeIntervalSince(lastCaptureTime) >= minimumCaptureInterval {
            captureWebViewImage()
        } else {
            captureTimer?.invalidate()
            captureTimer = Timer.scheduledTimer(withTimeInterval: minimumCaptureInterval, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.captureWebViewImage()
                }
            }
        }
    }
    
    func captureWebViewImage() {
        lastCaptureTime = Date()
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: CAPTURE_WIDTH / Int(UIScreen.main.scale))

        webView?.takeSnapshot(with: config) { (image, error) in
            guard let uiImage = image else {
                LOG("Error capturing snapshot: \(String(describing: error))")
                return
            }
            guard let ciImage = CIImage(image: uiImage) else {
                LOG("Failed to convert UIImage to CIImage")
                return
            }
            self.overlayImage = ciImage
            LOG("Captured overlay with dimensions \(ciImage.extent.size)")
            Task {
                // Combine all images every time any image is changed
                await self.bundler.combineOverlayImages()
            }
        }
    }
}

actor OverlayBundleActor {
    private var overlays: [URL: Overlay] = [:]
    func addOverlay(url: URL, overlay: Overlay) async {
        overlays[url] = overlay
    }
    func removeOverlay(url: URL) {
        overlays.removeValue(forKey: url)
    }
    func getOverlays() -> [Overlay] {
        Array(overlays.values)
    }
}

actor CombinedImageActor {
    private var combinedOverlayImage: CIImage? = nil
    func setImage(_ image: CIImage) {
        combinedOverlayImage = image
    }
    func getImage() -> CIImage? {
        combinedOverlayImage
    }
}

final class OverlayBundler: Sendable {
    public static let shared = OverlayBundler()
    private let overlayBundle = OverlayBundleActor()
    private let combinedImage = CombinedImageActor()

    func addOverlay(url: URL, overlay: Overlay) async {
        await overlayBundle.addOverlay(url: url, overlay: overlay)
    }

    func removeOverlay(url: URL) async {
        await overlayBundle.removeOverlay(url: url)
        await combineOverlayImages() // Update the combined image after removing
    }

    func combineOverlayImages() async {
        var images: [CIImage] = []
        for overlay in await overlayBundle.getOverlays() {
            if let image = await overlay.getOverlayImage() {
                images.append(image)
            }
        }
        LOG("Combining \(images.count) images")

        guard !images.isEmpty, let firstImage = images.first else {
            LOG("No images to combine")
            return
        }

        let imageComposition = images.dropFirst().reduce(firstImage) { result, image in
            result.composited(over: image)
        }

        await combinedImage.setImage(imageComposition)
    }
    
    func getCombinedImage() async -> CIImage? {
        await combinedImage.getImage()
    }
}

struct OverlayBundlerView: UIViewRepresentable {
    var url: URL

    func makeCoordinator() -> Overlay {
        let overlay = Overlay(url: url, bundler: OverlayBundler.shared)
        Task {
            await OverlayBundler.shared.addOverlay(url: url, overlay: overlay)
        }
        return overlay
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.createWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Handle updates if needed
    }
}
