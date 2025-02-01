//
//  CameraMonitor.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-01-03.
//
import SwiftUI
@preconcurrency import AVFoundation

@MainActor 
struct CameraMonitorView: UIViewControllerRepresentable {
    public static private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    static func createPreviewLayer() async {
        if CameraMonitorView.previewLayer == nil {
            CameraMonitorView.previewLayer = await AVCaptureVideoPreviewLayer(session: CaptureDirector.shared.getSession())
            LOG("Created camera video preview layer", level: .debug)
        }
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        viewController.loadViewIfNeeded()

        guard let previewLayer = CameraMonitorView.previewLayer else {
            LOG("Waiting for preivew layer to become available", level: .warning)
            return viewController
        }
        
        previewLayer.removeFromSuperlayer()
        
        previewLayer.videoGravity = .resizeAspect
        if let connection = previewLayer.connection {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        }

        viewController.view.layer.addSublayer(previewLayer)
        return viewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        let height = uiViewController.view.bounds.height
        let width = height * (16.0/9.0)
        CameraMonitorView.previewLayer?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        CATransaction.commit()
    }
}

