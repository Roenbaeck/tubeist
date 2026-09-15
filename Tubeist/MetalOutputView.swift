import AVFoundation
import Metal
import UIKit

private struct PreviewRenderRequest: Sendable {
    let sample: SendableSampleBuffer
    let headroom: CGFloat
    let size: CGSize
}

/// The layer's layout and HDR configuration belong to UIKit. Drawable sizing,
/// acquisition and rendering belong to one worker; it never calls UIKit or
/// synchronously dispatches to the main thread.
private final class MetalPreviewSurface: @unchecked Sendable {
    private let layer: CAMetalLayer
    private let pipeline: MetalOutputPipeline
    private let availableFrames = DispatchSemaphore(value: 2)
    private let lock = NSLock()
    private var stopped = false
    private let onFailure: @Sendable (Error) -> Void

    init(layer: CAMetalLayer, pipeline: MetalOutputPipeline, onFailure: @escaping @Sendable (Error) -> Void) {
        self.layer = layer
        self.pipeline = pipeline
        self.onFailure = onFailure
    }

    func stop() { lock.withLock { stopped = true } }
    private var isStopped: Bool { lock.withLock { stopped } }

    func draw(_ request: PreviewRenderRequest) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !isStopped, let pixelBuffer = CMSampleBufferGetImageBuffer(request.sample.value),
              availableFrames.wait(timeout: .now()) == .success else { return }
        var submitted = false
        let started = ProcessInfo.processInfo.systemUptime
        var stage = "texture preparation"
        defer {
            if !submitted { availableFrames.signal() }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed > 1 {
                LOG(String(format: "Output preview render took %.2f seconds; last stage: %@ (background queue)", elapsed, stage), level: .warning)
            }
        }
        do {
            let frame = try pipeline.prepare(pixelBuffer)
            stage = "drawable acquisition"
            // Keep resizing on the same queue as nextDrawable. The UI only
            // publishes the desired size and never waits on a drawable lock.
            if layer.drawableSize != request.size { layer.drawableSize = request.size }
            guard !isStopped, let drawable = layer.nextDrawable(), !isStopped else { return }
            stage = "command submission"
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = drawable.texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            guard let command = pipeline.commandQueue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            let width = Double(drawable.texture.width), height = Double(drawable.texture.height)
            let sourceWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
            let sourceHeight = Double(CVPixelBufferGetHeight(pixelBuffer))
            let scale = min(width / sourceWidth, height / sourceHeight)
            encoder.setViewport(MTLViewport(
                originX: (width - sourceWidth * scale) / 2,
                originY: (height - sourceHeight * scale) / 2,
                width: sourceWidth * scale, height: sourceHeight * scale, znear: 0, zfar: 1
            ))
            pipeline.encode(frame, into: encoder, headroom: request.headroom)
            encoder.endEncoding()
            guard !isStopped else { return }
            command.present(drawable)
            let availableFrames = availableFrames
            command.addCompletedHandler { completed in
                // Prevent camera-pool reuse while the GPU reads the source.
                withExtendedLifetime(frame) {}
                availableFrames.signal()
                if completed.status == .error {
                    LOG("Metal preview failed: \(completed.error?.localizedDescription ?? "GPU error")", level: .error)
                }
            }
            command.commit()
            submitted = true
        } catch {
            guard !isStopped else { return }
            onFailure(error)
        }
    }
}

@MainActor
final class MetalOutputView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var surface: MetalPreviewSurface?
    private var worker: PreviewRenderWorker<PreviewRenderRequest>?
    private var lastLoggedHeadroom: CGFloat?
    var onFailure: ((Error) -> Void)?

    init(outputPipeline: MetalOutputPipeline) {
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        isAccessibilityElement = true
        accessibilityLabel = "Output video"
        accessibilityIdentifier = "metal-output-preview"
        let metalLayer = layer as! CAMetalLayer
        metalLayer.device = outputPipeline.device
        metalLayer.pixelFormat = MetalOutputPipeline.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        metalLayer.toneMapMode = .never
        if #available(iOS 26.0, *) {
            metalLayer.preferredDynamicRange = .high
            metalLayer.contentsHeadroom = MetalOutputPipeline.referenceHeadroom
        } else {
            metalLayer.wantsExtendedDynamicRangeContent = true
        }
        let surface = MetalPreviewSurface(layer: metalLayer, pipeline: outputPipeline) { [weak self] error in
            Task { @MainActor [weak self] in self?.onFailure?(error) }
        }
        self.surface = surface
        worker = PreviewRenderWorker { request in surface.draw(request) }
    }

    required init?(coder: NSCoder) { fatalError("Use init(outputPipeline:)") }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let screen = window.screen
        let headroom = screen.currentEDRHeadroom
        let size = CGSize(width: (bounds.width * screen.scale).rounded(),
                          height: (bounds.height * screen.scale).rounded())
        worker?.submit(PreviewRenderRequest(sample: SendableSampleBuffer(value: sampleBuffer),
                                            headroom: headroom, size: size))
        if lastLoggedHeadroom == nil || abs(headroom - lastLoggedHeadroom!) >= 0.25 {
            lastLoggedHeadroom = headroom
            LOG("Metal output preview: EDR headroom \(headroom), screen brightness \(screen.brightness)", level: .debug)
        }
    }

    func stop() {
        surface?.stop()
        worker?.stop()
        worker = nil
        surface = nil
        onFailure = nil
    }
}
