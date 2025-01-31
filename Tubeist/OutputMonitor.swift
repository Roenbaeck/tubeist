//
//  OutputMonitor.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-27.
//

import SwiftUI
@preconcurrency import AVFoundation

struct OutputMonitorView: UIViewControllerRepresentable {
    @MainActor public static private(set) var displayLayer: AVSampleBufferDisplayLayer?
    
    static func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let renderer = displayLayer?.sampleBufferRenderer else {
            LOG("Cannot enque sample buffer: renderer not yet available", level: .warning)
            return
        }
        if renderer.status == .failed {
            renderer.flush()
        }
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sampleBuffer)
        }
    }

    static func createPreviewLayer() async {
        if OutputMonitorView.displayLayer == nil {
            OutputMonitorView.displayLayer = AVSampleBufferDisplayLayer()
            LOG("Created output video display layer", level: .debug)
        }
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        viewController.loadViewIfNeeded()
        
        guard let displayLayer = OutputMonitorView.displayLayer else {
            LOG("Waiting for display layer to become available", level: .warning)
            return viewController
        }
        
        displayLayer.removeFromSuperlayer()
        displayLayer.videoGravity = .resizeAspect
        viewController.view.layer.addSublayer(displayLayer)
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        let height = uiViewController.view.bounds.height
        let width = height * (16.0/9.0)
        OutputMonitorView.displayLayer?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        CATransaction.commit()
    }
}

