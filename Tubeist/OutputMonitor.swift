//
//  OutputMonitor.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-27.
//

import SwiftUI
@preconcurrency import AVFoundation

@MainActor
struct OutputMonitorView: UIViewControllerRepresentable {
    private static var frameNumber: UInt32 = 0
    public static var isBatterySavingOn: Bool = false
    public static private(set) var displayLayer: AVSampleBufferDisplayLayer?
    
    static func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let renderer = displayLayer?.sampleBufferRenderer else {
            LOG("Cannot enque sample buffer: renderer not yet available", level: .warning)
            return
        }
        frameNumber += 1
        frameNumber %= 600
        if isBatterySavingOn && frameNumber % 6 != 0 {
            return
        }
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sampleBuffer)
        }
        else if renderer.status == .failed {
            renderer.flush()
        }
    }

    static func createPreviewLayer() {
        if OutputMonitorView.displayLayer == nil {
            let displayLayer = AVSampleBufferDisplayLayer()
            displayLayer.preventsDisplaySleepDuringVideoPlayback = true
            OutputMonitorView.displayLayer = displayLayer
            LOG("Created output video display layer", level: .debug)
        }
    }

    static func deletePreviewLayer() {
        OutputMonitorView.displayLayer = nil
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

