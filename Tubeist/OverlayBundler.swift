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
    func roughBoundingBox(scaledWidth: Int) -> CGRect? {
        guard scaledWidth > 0, let cgImage = self.cgImage else { return nil }

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

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            guard pointer.baseAddress != nil else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                    let alpha = pointer.load(fromByteOffset: pixelIndex + bytesPerPixel - 1, as: UInt8.self)
                    if alpha > 0 {
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
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
            y: boxY,
//            y: originalHeight - boxY - boxHeight, // flip coordinate system
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

enum OverlayURLValidator {
    static func isAllowed(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            return false
        }
        return true
    }
}

struct OverlayRetryPolicy: Sendable {
    var initialDelay: TimeInterval = 2
    var maximumDelay: TimeInterval = 30
    var requestTimeout: TimeInterval = 15
}

@MainActor
final class Overlay: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let url: URL
    var sourceURL: URL { url }
    private let bundler: OverlayBundler
    private var webView: WKWebView?
    private var mimeType: String?
    private var overlayImage: UIImage?
    private var captureSchedule = OverlayCaptureSchedule()
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = 0
    private var didLogSnapshot = false
    private var forceSnapshot = false
    private let refreshRate: () -> OverlayRefreshRate
    private let retryPolicy: OverlayRetryPolicy
    private var retryDelay: TimeInterval
    private var retryTask: Task<Void, Never>?
    private var currentNavigation: WKNavigation?
    private var isPageReady = false
    private var scale: Double
    private var appliedScale: Double?
    
    init(url: URL, bundler: OverlayBundler, scale: Double = 1, retryPolicy: OverlayRetryPolicy = OverlayRetryPolicy(),
         refreshRate: @escaping () -> OverlayRefreshRate = { Settings.overlayRefreshRate }) {
        self.url = url
        self.bundler = bundler
        self.scale = OverlaySetting.normalizedScale(scale)
        self.retryPolicy = retryPolicy
        self.retryDelay = retryPolicy.initialDelay
        self.refreshRate = refreshRate
        super.init()
    }
    
    func prepareForRemoval() {
        retryTask?.cancel()
        retryTask = nil
        currentNavigation = nil
        isPageReady = false
        overlayImage = nil
        invalidateCapture()

        self.webView?.navigationDelegate = nil
        self.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "domChanged")
        self.webView?.pauseAllMediaPlayback(completionHandler: nil)
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
        prepareForRemoval()
        retryDelay = retryPolicy.initialDelay
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        // Register once per web view; adding it on every didFinish crashes
        // when an overlay reloads or recovers after a later failure.
        config.userContentController.add(self, name: "domChanged")
        installScaleScript(in: config.userContentController)
        
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

        self.webView = webView
        loadOverlay()
        return webView
    }

    func setScale(_ value: Double) {
        let value = OverlaySetting.normalizedScale(value)
        guard value != scale else { return }
        scale = value
        guard let webView else { return }
        installScaleScript(in: webView.configuration.userContentController)
        // A pending snapshot at the old scale must not replace the new one.
        // Reuse this web view so live page state and connections survive.
        invalidateCapture()
        applyScale(in: webView)
    }

    private func installScaleScript(in controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: Self.scaleScript(scale), injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient
        ))
    }

    private static func scaleScript(_ scale: Double) -> String {
        // Older WebKit can leave fonts unscaled by CSS zoom (bugs 272339 and
        // 272351). Transform the document there, with a larger layout canvas
        // to keep right/bottom anchors at the edge. iOS 27 handles text zoom
        // correctly and keeps automatic viewport fitting stable with CSS zoom.
        let needsTextZoomWorkaround: Bool
        if #available(iOS 27.0, *) {
            needsTextZoomWorkaround = false
        } else {
            needsTextZoomWorkaround = true
        }
        return """
        (() => {
            const root = document.documentElement;
            if (!root) return false;
            const properties = \(needsTextZoomWorkaround)
                ? ['transform', 'transform-origin', 'width', 'height'] : ['zoom'];
            const original = window.__tubeistOverlayScaleOriginal ??= {
                properties: Object.fromEntries(properties.map(name =>
                    [name, { value: root.style.getPropertyValue(name), priority: root.style.getPropertyPriority(name) }])),
                transform: getComputedStyle(root).transform,
                zoom: parseFloat(getComputedStyle(root).zoom) || 1
            };
            if (\(scale) === 1) {
                for (const [name, property] of Object.entries(original.properties)) {
                    if (property.value) root.style.setProperty(name, property.value, property.priority);
                    else root.style.removeProperty(name);
                }
            } else if (\(needsTextZoomWorkaround)) {
                const transform = original.transform === 'none' ? '' : original.transform;
                root.style.setProperty('transform', 'scale(\(scale)) ' + transform, 'important');
                root.style.setProperty('transform-origin', '0 0', 'important');
                root.style.setProperty('width', 'calc(100% / \(scale))', 'important');
                root.style.setProperty('height', 'calc(100vh / \(scale))', 'important');
            } else {
                root.style.setProperty('zoom', String(original.zoom * \(scale)), 'important');
            }
            // Older WebKit async bridges require a non-null result.
            return true;
        })();
        """
    }

    private func applyScale(in webView: WKWebView) {
        guard isPageReady else { return }
        let generation = captureGeneration
        let requestedScale = scale
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, self.isPageReady,
                  self.captureGeneration == generation, self.webView === webView else { return }
            do {
                let applied = try await webView.evaluateJavaScript(
                    Self.scaleScript(requestedScale), in: nil, contentWorld: .defaultClient
                )
                guard self.isPageReady, self.webView === webView,
                      self.captureGeneration == generation else { return }
                guard applied as? Bool == true else {
                    LOG("Could not apply overlay scale: page has no document root", level: .warning)
                    return
                }
                self.appliedScale = requestedScale
                self.captureWebViewImageOrSchedule()
            } catch {
                guard self.isPageReady, self.captureGeneration == generation else { return }
                LOG("Could not apply overlay scale: \(error)", level: .warning)
            }
        }
    }

    private func loadOverlay() {
        guard let webView else { return }
        // Always retry the saved URL, even if the first navigation never
        // committed. Bypass cached error responses when the server returns.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: retryPolicy.requestTimeout)
        currentNavigation = webView.load(request)
    }

    func reload() {
        guard let webView else { return }
        retryTask?.cancel()
        retryTask = nil
        retryDelay = retryPolicy.initialDelay
        invalidateCapture()
        isPageReady = false
        currentNavigation = nil
        webView.stopLoading()
        loadOverlay()
    }

    private func scheduleRetry(reason: String) {
        guard let webView, retryTask == nil else { return }
        isPageReady = false
        invalidateCapture()
        let delay = retryDelay
        retryDelay = min(retryPolicy.maximumDelay, retryDelay * 2)
        LOG("Overlay at \(url.host ?? "unknown host") could not load: \(reason). Retrying in \(delay)s", level: .warning)
        retryTask = Task { @MainActor [weak self, weak webView] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let webView, self.webView === webView else { return }
            self.retryTask = nil
            self.loadOverlay()
        }
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
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        retryTask?.cancel()
        retryTask = nil
        currentNavigation = navigation
        mimeType = nil
        isPageReady = false
        invalidateCapture()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let targetURL = navigationAction.request.url,
              OverlayURLValidator.isAllowed(targetURL.absoluteString) else {
            LOG("Blocked overlay navigation to an unsupported URL scheme", level: .warning)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard self.webView === webView else { return .cancel }
        if navigationResponse.isForMainFrame {
            if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
                // An error page is not an overlay. Leave the last good
                // snapshot in OUTPUT and keep trying the configured URL.
                scheduleRetry(reason: "HTTP \(response.statusCode)")
                return .cancel
            }
            mimeType = navigationResponse.response.mimeType
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(in: webView, navigation: navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(in: webView, navigation: navigation, error: error)
    }

    private func navigationFailed(in webView: WKWebView, navigation: WKNavigation?, error: Error) {
        guard self.webView === webView, currentNavigation === navigation else { return }
        let error = error as NSError
        // A replacement navigation or deliberate policy cancellation is not
        // a connectivity failure. HTTP errors schedule their own retry above.
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        scheduleRetry(reason: error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        scheduleRetry(reason: "Web content process terminated")
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView, currentNavigation === navigation else { return }
        retryTask?.cancel()
        retryTask = nil
        retryDelay = retryPolicy.initialDelay
        isPageReady = true
        captureSchedule.rate = refreshRate()
        didLogSnapshot = false
        LOG("Web view finished loading; maximum overlay refresh rate: \(captureSchedule.rate.rawValue)/s", level: .debug)
        applyScale(in: webView)
        
        guard let mimeType, mimeType.hasSuffix("html") else {
            LOG("Not detecting DOM changes for non-HTML content", level: .debug)
            return
        }
        
        webView.evaluateJavaScript(OverlayPageChanges.install) { result, error in
            if let error = error {
                LOG("Error injecting JavaScript: \(error)", level: .error)
            }
        }
    }
    
    private func invalidateCapture() {
        captureGeneration += 1
        appliedScale = nil
        captureSchedule.reset()
        forceSnapshot = false
        captureTask?.cancel()
        // Do not clear the task until its outstanding snapshot/composition
        // finishes: cancellation cannot cancel a WebKit snapshot callback.
    }

    func captureWebViewImageOrSchedule() {
        guard isPageReady else { return }
        forceSnapshot = true
        captureSchedule.request()
        startCaptureWorkerIfNeeded()
    }

    private func startCaptureWorkerIfNeeded() {
        guard isPageReady, appliedScale == scale, captureSchedule.isPending, captureTask == nil else { return }
        captureTask = Task { [weak self] in
            await self?.processCaptureRequests()
        }
    }

    private func processCaptureRequests() async {
        defer {
            captureTask = nil
            // A new navigation may finish while the previous snapshot is
            // returning. Its pending update belongs to a fresh worker.
            startCaptureWorkerIfNeeded()
        }
        while isPageReady, !Task.isCancelled {
            guard let delay = captureSchedule.delay(at: CACurrentMediaTime()) else { return }
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
            guard isPageReady, !Task.isCancelled else { return }
            guard captureSchedule.begin(at: CACurrentMediaTime()) else { continue }
            await captureWebViewImage()
            captureSchedule.complete()

            // High-rate modes also capture CSS/canvas animations, which do
            // not necessarily mutate the DOM. Static image URLs stay idle.
            if isPageReady, captureSchedule.rate != .once, mimeType?.hasSuffix("html") == true {
                captureSchedule.request()
            }
        }
    }

    private func captureWebViewImage() async {
        guard isPageReady, appliedScale == scale, let webView else { return }
        let generation = captureGeneration
        let forced = forceSnapshot
        forceSnapshot = false
        if captureSchedule.rate != .once, mimeType?.hasSuffix("html") == true {
            // A cheap page query avoids the much more expensive bitmap capture
            // when a text/CSS overlay is idle. Unknown/embedded media continues
            // refreshing so its animations are not silently frozen.
            let changed = try? await webView.evaluateJavaScript(OverlayPageChanges.consume) as? Bool
            guard isPageReady, self.webView === webView, generation == captureGeneration,
                  !Task.isCancelled else { return }
            if !forced, changed == false { return }
        }
        guard let width = await CaptureDirector.shared.getResolution()?.width else {
            LOG("Cannot get width from the camera input", level: .error)
            return
        }
        guard isPageReady, self.webView === webView, generation == captureGeneration,
              !Task.isCancelled else { return }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        let displayScale = max(1, webView.traitCollection.displayScale)
        config.snapshotWidth = NSNumber(value: Double(width) / Double(displayScale))
        do {
            let image = try await webView.takeSnapshot(configuration: config)
            guard isPageReady, self.webView === webView, generation == captureGeneration,
                  !Task.isCancelled else { return }
            overlayImage = image
            if !didLogSnapshot {
                didLogSnapshot = true
                let colorSpace = (image.cgImage?.colorSpace?.name as String?)?.replacingOccurrences(of: "kCGColorSpace", with: "")
                LOG("Captured overlay: \(image.cgImage?.width ?? 0)x\(image.cgImage?.height ?? 0) pixels, bitmap density \(image.scale)x, overlay scale \(Int((scale * 100).rounded()))%, color space: \(colorSpace ?? "unknown")", level: .debug)
            }
            // Backpressure includes composition and the GPU upload, not just
            // WebKit. At most one snapshot and one pending change per overlay.
            await bundler.combineOverlayImages()
        } catch {
            guard isPageReady, generation == captureGeneration, !Task.isCancelled else { return }
            forceSnapshot = true
            LOG("Error capturing snapshot: \(error)", level: .error)
        }
    }

}

actor OverlayBundleActor {
    private var url2overlay: [URL: Overlay] = [:]
    func addOverlay(url: URL, overlay: Overlay) {
        url2overlay[url] = overlay
    }
    func removeOverlay(url: URL, matching expected: Overlay? = nil) async {
        // Returning to the foreground can register a replacement before the
        // old view's asynchronous removal reaches this actor.
        if let expected, url2overlay[url] !== expected { return }
        guard let overlay = url2overlay.removeValue(forKey: url) else { return }
        await overlay.prepareForRemoval()
    }
    func getOverlays(in order: [URL]) -> [Overlay] {
        // Web views can register in any order. Only the saved layer order counts.
        order.compactMap { url2overlay[$0] }
    }
    func removeAllOverlays() async {
        let overlays = Array(url2overlay.values)
        await MainActor.run {
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

actor OverlayBundler {
    public static let shared = OverlayBundler()
    private let overlayBundle = OverlayBundleActor()
    private var isCombining = false
    private var needsCombination = false
    private var lastCombinationTime: TimeInterval?
    private var previousImages: [UIImage] = []
    private var cachedBounds: [ObjectIdentifier: (image: UIImage, box: CGRect?)] = [:]
    
    func addOverlay(url: URL, overlay: Overlay) async {
        await overlayBundle.addOverlay(url: url, overlay: overlay)
    }

    nonisolated func removeOverlay(url: URL, matching overlay: Overlay? = nil) {
        Task {
            await overlayBundle.removeOverlay(url: url, matching: overlay)
            await combineOverlayImages() // Update the combined image after removing
        }
    }
    
    nonisolated func removeAllOverlays() {
        Task {
            await overlayBundle.removeAllOverlays()
            await FrameGrabber.shared.setCombinedOverlay(nil)
        }
    }
    
    nonisolated func refreshCombinedImage() {
        Task {
            let overlays = await overlayBundle.getOverlays(in: savedOverlayOrder)
            for overlay in overlays {
                await overlay.captureWebViewImageOrSchedule()
            }
        }
    }

    func reloadOverlays(in order: [URL]) async {
        let overlays = await overlayBundle.getOverlays(in: order)
        for overlay in overlays {
            await overlay.reload()
        }
    }

    private nonisolated var savedOverlayOrder: [URL] {
        OverlaySettingsManager.loadOverlaysFromStorage().compactMap { URL(string: $0.url) }
    }

    func combineOverlayImages() async {
        needsCombination = true
        guard !isCombining else { return }
        isCombining = true
        if let lastCombinationTime {
            let delay = lastCombinationTime + Settings.overlayRefreshRate.interval - CACurrentMediaTime()
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        }
        // Changes during the wait are included in this composition. Several
        // overlays must not multiply the configured maximum GPU update rate.
        needsCombination = false
        lastCombinationTime = CACurrentMediaTime()
        await combineLatestOverlayImages()
        isCombining = false
        if needsCombination {
            // Let the requesting overlay capture its next frame even if other
            // overlays keep changing throughout every composition.
            Task { await combineOverlayImages() }
        }
    }

    private func combineLatestOverlayImages() async {
        if Settings.hideOverlays {
            previousImages = []
            await FrameGrabber.shared.setCombinedOverlay(nil)
            return
        }
        let order = savedOverlayOrder
        var images: [UIImage] = []
        for overlay in await overlayBundle.getOverlays(in: order) {
            if let image = await overlay.getOverlayImage() {
                images.append(image)
            }
        }
        // A Settings save may have changed the stack while snapshots were read.
        guard order == savedOverlayOrder else { return }
        if images.isEmpty {
            previousImages = []
            cachedBounds = [:]
            LOG("There are no images to combine", level: .debug)
            await FrameGrabber.shared.setCombinedOverlay(nil)
            return
        }
        guard images.count != previousImages.count || !zip(images, previousImages).allSatisfy({ $0 === $1 }) else { return }
        var currentBounds: [ObjectIdentifier: (image: UIImage, box: CGRect?)] = [:]
        for image in images {
            let id = ObjectIdentifier(image)
            currentBounds[id] = cachedBounds[id] ?? (
                image, image.roughBoundingBox(scaledWidth: BOUNDING_BOX_SEARCH_WIDTH)
            )
        }
        cachedBounds = currentBounds
        let boundingBoxes = images.compactMap { cachedBounds[ObjectIdentifier($0)]?.box }
        guard let flippedCIImage = OverlayImageComposer.compose(images)
        else {
            LOG("Images could not be combined", level: .error)
            return
        }
        // need to flip this to match Metal coordinate space
        let height = flippedCIImage.extent.height
        let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height))
        let ciImage = flippedCIImage.transformed(by: transform)
        
        var coverage: Double = 1.0
        if !boundingBoxes.isEmpty {
            coverage = boundingBoxes.map { $0.size.width * $0.size.height }.reduce(0, +) / (ciImage.extent.width * ciImage.extent.height)
        }
        let combinedOverlay = CombinedOverlay(image: ciImage, boundingBoxes: boundingBoxes, coverage: coverage)
        guard order == savedOverlayOrder, !Settings.hideOverlays else { return }
        await FrameGrabber.shared.setCombinedOverlay(combinedOverlay)
        previousImages = images
    }
}

struct OverlayView: UIViewRepresentable {
    var url: URL
    var scale: Double = 1

    func makeCoordinator() -> Overlay {
        let overlay = Overlay(url: url, bundler: OverlayBundler.shared, scale: scale)
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
        context.coordinator.setScale(scale)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Overlay) {
        coordinator.prepareForRemoval()
        OverlayBundler.shared.removeOverlay(url: coordinator.sourceURL, matching: coordinator)
    }
}
