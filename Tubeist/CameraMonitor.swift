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
    @State private var previewLayerAdded: Bool = false
    
    static func createPreviewLayer() async -> AVCaptureVideoPreviewLayer? {
        await AVCaptureVideoPreviewLayer(session: CaptureDirector.shared.getSession())
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        viewController.loadViewIfNeeded()
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        Task { @MainActor in
            if CameraMonitorView.previewLayer == nil {
                CameraMonitorView.previewLayer = await CameraMonitorView.createPreviewLayer()
                LOG("Created preview layer", level: .debug)
            }
            
            guard let previewLayer = CameraMonitorView.previewLayer else { return }
            
            previewLayer.videoGravity = .resizeAspect
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }

            let height = uiViewController.view.bounds.height
            let width = height * (16.0/9.0)
            let x: CGFloat = 0
            let y: CGFloat = 0
            
            CATransaction.begin()
            CATransaction.setAnimationDuration(0)
            previewLayer.frame = CGRect(x: x, y: y, width: width, height: height)
            CATransaction.commit()
            
            if !previewLayerAdded {
                uiViewController.view.layer.addSublayer(previewLayer)
            }
        }
    }
}

