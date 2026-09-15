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
    private static var previewGeneration = UUID()
    private static var previewEnabled = true
    var isPreviewEnabled = true

    static func setPreviewEnabled(_ enabled: Bool) {
        previewEnabled = enabled
        previewLayer?.connection?.isEnabled = enabled
        previewLayer?.isHidden = !enabled
    }

    static func createPreviewLayer(
        sessionProvider: @MainActor () async -> AVCaptureSession = { await CaptureDirector.shared.getSession() }
    ) async {
        let generation = previewGeneration
        let session = await sessionProvider()
        // Recheck after suspension: another caller may have created the layer,
        // or backgrounding may have invalidated this request in the meantime.
        guard !Task.isCancelled, generation == previewGeneration, previewLayer == nil else { return }
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        setPreviewEnabled(previewEnabled)
        LOG("Created camera video preview layer", level: .debug)
    }

    static func deletePreviewLayer() {
        previewGeneration = UUID()
        CameraMonitorView.previewLayer?.removeFromSuperlayer()
        CameraMonitorView.previewLayer = nil
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        viewController.loadViewIfNeeded()
        Self.setPreviewEnabled(isPreviewEnabled)

        guard let previewLayer = CameraMonitorView.previewLayer else {
            LOG("Waiting for preview layer to become available", level: .debug) // This normally happens once
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
        Self.setPreviewEnabled(isPreviewEnabled)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        let height = uiViewController.view.bounds.height
        let width = height * (16.0/9.0)
        CameraMonitorView.previewLayer?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        CATransaction.commit()
    }
}
