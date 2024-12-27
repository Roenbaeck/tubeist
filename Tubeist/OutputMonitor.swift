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
    private let displayLayer: AVSampleBufferDisplayLayer
    
    init() {
        displayLayer = AVSampleBufferDisplayLayer()
    }
    
    func configurePreviewLayer(on viewController: UIViewController) {
        displayLayer.videoGravity = .resizeAspect
        
        DispatchQueue.main.async {
            // Remove existing preview layers
            viewController.view.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            
            // Add preview layer
            viewController.view.layer.addSublayer(self.displayLayer)
            
            // Calculate the frame based on 16:9 ratio
            let height = viewController.view.bounds.height
            let width = height * (16.0/9.0)
            let x: CGFloat = 0
            let y: CGFloat = 0
            
            CATransaction.begin()
            CATransaction.setAnimationDuration(0)
            self.displayLayer.frame = CGRect(x: x, y: y, width: width, height: height)
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
        OutputMonitor.shared.configurePreviewLayer(on: uiViewController)
    }
}
