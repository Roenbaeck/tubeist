//
//  CameraMonitor.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-01-03.
//
import SwiftUI
@preconcurrency import AVFoundation

struct CameraMonitorView: UIViewControllerRepresentable {
    @MainActor public static private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    init() {
        Task { @MainActor in
            if CameraMonitorView.previewLayer == nil {
                CameraMonitorView.previewLayer = await CameraMonitorView.createPreviewLayer()
                LOG("Created preview layer", level: .debug)
            }
        }
    }
    
    static func createPreviewLayer() async -> AVCaptureVideoPreviewLayer? {
        await AVCaptureVideoPreviewLayer(session: CaptureDirector.shared.getSession())
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

