//
//  OutputMonitor.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-27.
//

import SwiftUI
@preconcurrency import AVFoundation

final class OutputMonitor: Sendable {
    public static let shared = OutputMonitor()
    public let displayLayer: AVSampleBufferDisplayLayer
    
    init() {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
    }
    
    func configurePreviewLayer(on viewController: UIViewController) {
        Task { @MainActor in
            let height = viewController.view.bounds.height
            let width = height * (16.0/9.0)
            let x: CGFloat = 0
            let y: CGFloat = 0

            CATransaction.begin()
            CATransaction.setAnimationDuration(0)
            displayLayer.frame = CGRect(x: x, y: y, width: width, height: height)
            CATransaction.commit()
        }
    }
    
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sampleBuffer)
        }
    }
}

// SwiftUI wrapper
struct OutputMonitorView: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        // Ensure view is loaded before configurations
        viewController.loadViewIfNeeded()
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let outputMonitor = OutputMonitor.shared

        // Add the displayLayer to the view's layer if it's not already there
        if outputMonitor.displayLayer.superlayer != uiViewController.view.layer {
            uiViewController.view.layer.addSublayer(outputMonitor.displayLayer)
        }
        
        OutputMonitor.shared.configurePreviewLayer(on: uiViewController)
    }
}
