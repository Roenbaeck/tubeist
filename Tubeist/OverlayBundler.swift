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

extension UIImage {
    func roughBoundingBox(scaledWidth: Int) -> CGRect? {
        guard let cgImage = self.cgImage else { return nil }

        // Calculate scaling factor
        let originalWidth = cgImage.width
        let originalHeight = cgImage.height
        let scaleFactor = Double(scaledWidth) / Double(originalWidth)
        let scaledHeight = Int(Double(originalHeight) * scaleFactor)

        // Resize the image
        let scaledImage = self.scaled(to: CGSize(width: scaledWidth, height: scaledHeight))
        guard let scaledCGImage = scaledImage.cgImage else { return nil }
        guard let data = scaledCGImage.dataProvider?.data as Data? else { return nil }

        let width = Int(scaledCGImage.width)
        let height = Int(scaledCGImage.height)
        let bytesPerRow = Int(scaledCGImage.bytesPerRow)
        let bytesPerPixel = Int(scaledCGImage.bitsPerPixel / 8)

        var minX = 0
        var minY = 0
        var maxX = width - 1
        var maxY = height - 1

        data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            guard let _ = pointer.baseAddress else { return }

            // Similar logic as original for finding bounding box on scaled image
            for y in 0..<height {
                var found = false
                for x in minX...maxX {
                    let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                    let alpha = pointer.load(fromByteOffset: pixelIndex + bytesPerPixel - 1, as: UInt8.self)
                    if alpha > 0 {
                        minY = y
                        found = true
                        break
                    }
                }
                if found { break }
            }

            if minY < height {
                for y in (minY...maxY).reversed() {
                    var found = false
                    for x in minX...maxX {
                        let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                        let alpha = pointer.load(fromByteOffset: pixelIndex + bytesPerPixel - 1, as: UInt8.self)
                        if alpha > 0 {
                            maxY = y
                            found = true
                            break
                        }
                    }
                    if found { break }
                }
            }

            if minY <= maxY {
                for x in 0..<width {
                    var found = false
                    for y in minY...maxY {
                        let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                        let alpha = pointer.load(fromByteOffset: pixelIndex + bytesPerPixel - 1, as: UInt8.self)
                        if alpha > 0 {
                            minX = x
                            found = true
                            break
                        }
                    }
                    if found { break }
                }
            }

            if minY <= maxY {
                for x in (minX...maxX).reversed() {
                    var found = false
                    for y in minY...maxY {
                        let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                        let alpha = pointer.load(fromByteOffset: pixelIndex + bytesPerPixel - 1, as: UInt8.self)
                        if alpha > 0 {
                            maxX = x
                            found = true
                            break
                        }
                    }
                    if found { break }
                }
            }
        }

        if minY > maxY || minX > maxX { return nil }

        // Scale back to original dimensions
        let scale = 1.0 / scaleFactor
        
        let boxX: Int = max(0, Int(Double(minX) * scale - scale))
        let boxY: Int = max(0, Int(Double(minY) * scale - scale))
        let boxWidth: Int = min(originalWidth, Int(Double(maxX - minX + 1) * scale + 2 * scale))
        let boxHeight: Int = min(originalHeight, Int(Double(maxY - minY + 1) * scale + 2 * scale))
        
        return CGRect(
            x: boxX,
            y: originalHeight - boxY - boxHeight, // flip coordinate system
            width: boxWidth,
            height: boxHeight
        )
    }

    // Helper function to scale an image
    func scaled(to size: CGSize) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        self.draw(in: CGRect(origin: .zero, size: size))
        let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return scaledImage ?? self
    }
}

final class Overlay: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let url: URL
    private let bundler: OverlayBundler
    private var webView: WKWebView?
    private var mimeType: String?
    private var overlayImage: UIImage?
    private var lastCaptureTime: Date = Date.distantPast
    private var captureTimer: Timer?
    private let minimumCaptureInterval: TimeInterval = 1.0 // at least 1 second between snapshots
    
    init(url: URL, bundler: OverlayBundler) {
        self.url = url
        self.bundler = bundler
        super.init()
    }
    
    func prepareForRemoval() {
        self.captureTimer?.invalidate()
        self.captureTimer = nil

        self.webView?.navigationDelegate = nil
        self.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "domChanged")
        self.webView?.stopLoading()
        self.webView = nil
    }
        
    deinit {
        LOG("Deinitializing Overlay for \(self.url)")
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
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let mimeType = navigationResponse.response.mimeType {
            self.mimeType = mimeType
        }
        return .allow
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        LOG("Web view finished loading", level: .info)
        captureWebViewImageOrSchedule()
        
        guard let mimeType, mimeType.hasSuffix("html") else {
            LOG("Not detecting DOM changes for non-HTML content")
            return
        }
        
        let script = """
            (function() {
                // Ensure transparent background even if set to a specific color
                document.body.style.backgroundColor = 'transparent';
        
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
                Task { @MainActor in
                    self?.captureWebViewImage()
                }
            }
        }
    }
    
    private func captureWebViewImage() {
        lastCaptureTime = Date()
        Task {
            guard let width = await CaptureDirector.shared.getResolution()?.width else {
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
                let colorSpace = (uiImage.cgImage?.colorSpace?.name as String?)?.replacingOccurrences(of: "kCGColorSpace", with: "")
                LOG("Captured overlay \(uiImage.size), scale \(uiImage.scale), and color space: \(colorSpace ?? "unknown")", level: .debug)
                Task {
                    // Combine all images every time any image is changed
                    await self.bundler.combineOverlayImages()
                }
            }
        }
    }
}

actor OverlayBundleActor {
    private var url2overlay: [URL: Overlay] = [:]
    func addOverlay(url: URL, overlay: Overlay) async {
        url2overlay[url] = overlay
    }
    func removeOverlay(url: URL) {
        guard let overlay = url2overlay.removeValue(forKey: url) else { return }
        Task { @MainActor in
            overlay.prepareForRemoval()
        }
    }
    func getOverlays() -> [Overlay] {
        Array(url2overlay.values)
    }
    func removeAllOverlays() {
        let overlays = getOverlays()
        Task { @MainActor in
            overlays.forEach { $0.prepareForRemoval() }
        }
        url2overlay.removeAll()
    }
}

struct CombinedOverlay {
    let image: CIImage
    let boundingBoxes: [CGRect]
    let coverage: Double
}

actor CombinedOverlayActor {
    private var combinedOverlay: CombinedOverlay?
    func setOverlay(_ image: CIImage, _ boundingBoxes: [CGRect] = []) {
        var coverage: Double = 1.0
        if !boundingBoxes.isEmpty {
            coverage = boundingBoxes.map { $0.size.width * $0.size.height }.reduce(0, +) / (image.extent.width * image.extent.height)
        }
        combinedOverlay = CombinedOverlay(image: image, boundingBoxes: boundingBoxes, coverage: coverage)
    }
    func getOverlay() -> CombinedOverlay? {
        combinedOverlay
    }
    func deleteOverlay() {
        combinedOverlay = nil
    }
}

final class OverlayBundler: Sendable {
    public static let shared = OverlayBundler()
    private let overlayBundle = OverlayBundleActor()
    private let combinedOverlay = CombinedOverlayActor()

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
            await combinedOverlay.deleteOverlay()
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
            await combinedOverlay.deleteOverlay()
        }
        else {
            var images: [UIImage] = []
            for overlay in await overlayBundle.getOverlays() {
                if let image = await overlay.getOverlayImage() {
                    images.append(image)
                }
            }
            if images.isEmpty {
                LOG("There are no images to combine", level: .debug)
                return
            }
            var boundingBoxes: [CGRect] = []
            for uiImage in images {
                if let boundingBox = uiImage.roughBoundingBox(scaledWidth: BOUNDING_BOX_SEARCH_WIDTH) {
                    boundingBoxes.append(boundingBox)
                }
            }
            guard let imageComposition = UIImage.composite(images: images),
                  let ciImage = CIImage(image: imageComposition, options: [.expandToHDR: true, .colorSpace: CG_COLOR_SPACE])
            else {
                LOG("Images could not be combined", level: .error)
                return
            }
            let colorSpace = (ciImage.colorSpace?.name as String?)?.replacingOccurrences(of: "kCGColorSpace", with: "")
            await combinedOverlay.setOverlay(ciImage, boundingBoxes)
            let combinedOverlay = await combinedOverlay.getOverlay()
            LOG("Combined \(images.count) images to single overlay with color space: \(colorSpace ?? "unknown")", level: .debug)
            let coveragePercentage = Int(100 * (combinedOverlay?.coverage ?? -1))
            LOG("Bounding boxes: \(String(describing: combinedOverlay?.boundingBoxes)) covering \(coveragePercentage)%")
            
        }
    }
    
    func getOverlay() async -> CombinedOverlay? {
        await combinedOverlay.getOverlay()
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
        if Settings.isInputSyncedWithOutput {
            let preset = Settings.selectedPreset
            return context.coordinator.createWebView(width: preset.width, height: preset.height)
        }
        return context.coordinator.createWebView(width: DEFAULT_CAPTURE_WIDTH, height: DEFAULT_CAPTURE_HEIGHT)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Handle updates if needed
    }
}
