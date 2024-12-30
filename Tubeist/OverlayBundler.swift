//
//  OverlayBundler.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-04.
//

// @preconcurrency need to avoid non-sendable CIImage when calling overlay.getOverlayImage()
@preconcurrency import SwiftUI
import WebKit

extension UIImage {
    static func composite(images: [UIImage]) -> UIImage? {
        guard let firstImage = images.first else { return nil }
        let size = firstImage.size
        
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false // Preserve transparency if needed
        format.preferredRange = .extended // Wide color range
        
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let composedImage = renderer.image { context in
            for image in images.reversed() { // Draw from back to front
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        return composedImage
    }
}

final class Overlay: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let url: URL
    private let bundler: OverlayBundler
    private var webView: WKWebView?
    private var overlayImage: UIImage?
    private var lastCaptureTime: Date = Date.distantPast
    private var captureTimer: Timer?
    private let minimumCaptureInterval: TimeInterval = 1.0 // at least 1 second between snapshots
    
    init(url: URL, bundler: OverlayBundler) {
        self.url = url
        self.bundler = bundler
        super.init()
    }
    
    deinit {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            LOG("Deinitializing Overlay for \(self.url)")

            self.captureTimer?.invalidate()
            self.captureTimer = nil

            self.webView?.navigationDelegate = nil
            self.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "domChanged")
            self.webView?.stopLoading()
            self.webView = nil
        }
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "domChanged" {
            self.captureWebViewImageOrSchedule()
        }
    }

    func createWebView(width: Int, height: Int) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = WK_PROCESS_POOL
        config.suppressesIncrementalRendering = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: config)
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

    func getOverlayImage() -> UIImage? {
        guard let overlayImage = self.overlayImage else {
            return nil
        }
        return overlayImage
    }
    
    func getWebView() -> WKWebView? { // Make this optional
        return webView
    }
    
    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        LOG("Web view finished loading", level: .info)
        captureWebViewImageOrSchedule()

        let script = """
            (function() {
                // Create a MutationObserver to watch for DOM changes
                const observer = new MutationObserver(mutationsList => {
                    // Trigger a Swift callback when a change is detected
                    window.webkit.messageHandlers.domChanged.postMessage('DOM changed');
                });

                // Start observing the entire document
                observer.observe(document, { subtree: true, childList: true, characterData: true });
                // When this is supported, we should be able to mix audio from several WKWebViews
                // navigator.audioSession.type = 'ambient';
            })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                LOG("Error injecting JavaScript: \(error)", level: .error)
            }
        }

        webView.configuration.userContentController.add(self, name: "domChanged")
    }
    
    // Both throttling and debouncing the capture so we ensure that at least the minimum capture interval passes
    // between snapshots, and that the last call is always executed even in a situation where several are coming
    // in quick succession
    func captureWebViewImageOrSchedule() {
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
    
    private func captureWebViewImage() {
        lastCaptureTime = Date()
        Task {
            guard let width = await CameraMonitor.shared.getResolution()?.width else {
                LOG("Cannot get width from the camera input", level: .error)
                return
            }
            
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = NSNumber(value: width / Int(UIScreen.main.scale))
            
            webView?.takeSnapshot(with: config) { (image, error) in
                guard let uiImage = image else {
                    LOG("Error capturing snapshot: \(String(describing: error))", level: .error)
                    return
                }
                self.overlayImage = uiImage
                let colorSpace = uiImage.cgImage?.colorSpace?.name as String?
                LOG("Captured overlay with size \(uiImage.size), scale \(uiImage.scale), and color space: \(colorSpace ?? "unknown")", level: .debug)
                Task {
                    // Combine all images every time any image is changed
                    await self.bundler.combineOverlayImages()
                }
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
    func removeAllOverlays() {
        overlays.removeAll()
    }
}

actor CombinedImageActor {
    private var combinedOverlayImage: CIImage? = nil
    func setImage(_ image: CIImage?) {
        combinedOverlayImage = image
    }
    func getImage() -> CIImage? {
        combinedOverlayImage
    }
    func deleteImage() {
        combinedOverlayImage = nil
    }
}

final class OverlayBundler: Sendable {
    public static let shared = OverlayBundler()
    private let overlayBundle = OverlayBundleActor()
    private let combinedImage = CombinedImageActor()

    func addOverlay(url: URL, overlay: Overlay) async {
        await overlayBundle.addOverlay(url: url, overlay: overlay)
    }

    func removeOverlay(url: URL) {
        Task {
            await overlayBundle.removeOverlay(url: url)
            await combineOverlayImages() // Update the combined image after removing
        }
    }
    
    func removeAllOverlays() {
        Task {
            await overlayBundle.removeAllOverlays()
            await combinedImage.deleteImage()
        }
    }
    
    func refreshCombinedImage() {
        Task {
            let overlays = await overlayBundle.getOverlays()
            for overlay in overlays {
                await overlay.captureWebViewImageOrSchedule()
            }
        }
    }
    
    func combineOverlayImages() async {
        if Settings.hideOverlays {
            LOG("Overlays are hidden so no images will be combined", level: .debug)
            await combinedImage.setImage(nil)
        }
        else {
            var images: [UIImage] = []
            for overlay in await overlayBundle.getOverlays() {
                if let image = await overlay.getOverlayImage() {
                    images.append(image)
                }
            }
            LOG("Combining \(images.count) images", level: .debug)
            
            guard let imageComposition = UIImage.composite(images: images),
                  let ciImage = CIImage(image: imageComposition, options: [.expandToHDR: true, .colorSpace: CG_COLOR_SPACE])
            else {
                LOG("Images could not be combined", level: .error)
                return
            }
            let colorSpace = ciImage.colorSpace?.name as String?
            LOG("Combined overlay has color space: \(colorSpace ?? "unknown")", level: .debug)
            await combinedImage.setImage(ciImage)
        }
    }
    
    func getCombinedImage() async -> CIImage? {
        await combinedImage.getImage()
    }
}

struct OverlayView: UIViewRepresentable {
    var url: URL

    func makeCoordinator() -> Overlay {
        let overlay = Overlay(url: url, bundler: OverlayBundler.shared)
        Task {
            await OverlayBundler.shared.addOverlay(url: url, overlay: overlay)
        }
        return overlay
    }

    func makeUIView(context: Context) -> WKWebView {
        if Settings.isInputSyncedWithOutput, let preset = Settings.selectedPreset {
            return context.coordinator.createWebView(width: preset.width, height: preset.height)
        }
        return context.coordinator.createWebView(width: DEFAULT_CAPTURE_WIDTH, height: DEFAULT_CAPTURE_HEIGHT)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Handle updates if needed
    }
}
