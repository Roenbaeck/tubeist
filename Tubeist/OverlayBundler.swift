//
//  OverlayBundler.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-04.
//

import SwiftUI
import WebKit

final class WebOverlayViewController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    public static let shared = WebOverlayViewController()
    private var webView: WKWebView?
    private let urlString: String
    private var overlayImage: CIImage?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name
            == "domChanged" {
            // print("Capturing web view due to DOM change")
            self.captureWebViewImage()
        }
    }
    
    func getOverlayImage() -> CIImage? {
        self.overlayImage
    }
    
    override init() {
        self.urlString = UserDefaults.standard.string(forKey: "OverlayURL") ?? ""
        super.init()
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

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        
        self.webView = webView
        return webView
    }
    
    func getWebView() -> WKWebView {
        return webView!
    }
    
    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("Web view finished loading")
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
                print("Error injecting JavaScript: \(error)")
            }
        }

        webView.configuration.userContentController.add(self, name: "domChanged")

        STREAMING_QUEUE.asyncAfter(deadline: .now() + 2) {
            Task {
                await self.captureWebViewImage()
            }
        }
    }

    func captureWebViewImage() {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: CAPTURE_WIDTH / Int(UIScreen.main.scale))

        webView?.takeSnapshot(with: config) { [weak self] (image, error) in
            guard let uiImage = image else {
                print("Error capturing snapshot: \(String(describing: error))")
                return
            }

            self?.overlayImage = CIImage(image: uiImage)
            print("Captured overlay with dimensions \(uiImage.size)")
        }
    }
}

struct WebOverlayView: UIViewRepresentable {
    
    func makeCoordinator() -> WebOverlayViewController {
        WebOverlayViewController()
    }
    
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.createWebView()
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Handle updates if needed
    }
}
