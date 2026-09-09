import AVFoundation
import MetalKit

@MainActor
final class MetalOutputView: MTKView, MTKViewDelegate {
    private let outputPipeline: MetalOutputPipeline
    private let availableFrames = DispatchSemaphore(value: 2)
    private var pendingBuffer: CVPixelBuffer?
    private var lastLoggedHeadroom: CGFloat?
    var onFailure: ((Error) -> Void)?

    init(previewDevice device: MTLDevice) throws {
        outputPipeline = try MetalOutputPipeline(device: device)
        super.init(frame: .zero, device: device)
        colorPixelFormat = MetalOutputPipeline.pixelFormat
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        backgroundColor = .black
        isAccessibilityElement = true
        accessibilityLabel = "Output video"
        accessibilityIdentifier = "metal-output-preview"
        delegate = self
        let metalLayer = layer as! CAMetalLayer
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        metalLayer.toneMapMode = .never
        if #available(iOS 26.0, *) {
            metalLayer.preferredDynamicRange = .high
            metalLayer.contentsHeadroom = MetalOutputPipeline.referenceHeadroom
        } else {
            metalLayer.wantsExtendedDynamicRangeContent = true
        }
    }

    required init(coder: NSCoder) { fatalError("Use init(previewDevice:)") }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard window != nil else { return }
        pendingBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        draw()
        pendingBuffer = nil
    }

    func stop() {
        pendingBuffer = nil
        delegate = nil
        onFailure = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pixelBuffer = pendingBuffer else { return }
        pendingBuffer = nil
        // Keep at most two preview submissions in flight; drop a frame if busy.
        guard availableFrames.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { availableFrames.signal() } }
        do {
            let frame = try outputPipeline.prepare(pixelBuffer)
            guard let descriptor = currentRenderPassDescriptor,
                  let drawable = currentDrawable,
                  let command = outputPipeline.commandQueue.makeCommandBuffer(),
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
            let headroom = window?.screen.currentEDRHeadroom ?? 1
            outputPipeline.encode(frame, into: encoder, headroom: headroom)
            encoder.endEncoding()
            command.present(drawable)
            let availableFrames = availableFrames
            command.addCompletedHandler { completed in
                // Holding the CVPixelBuffer prevents camera-pool reuse during
                // this read. The preview never writes either source plane.
                withExtendedLifetime(frame) {}
                availableFrames.signal()
                if completed.status == .error {
                    LOG("Metal preview failed: \(completed.error?.localizedDescription ?? "GPU error")", level: .error)
                }
            }
            command.commit()
            submitted = true
            if lastLoggedHeadroom == nil || abs(headroom - lastLoggedHeadroom!) >= 0.25 {
                lastLoggedHeadroom = headroom
                LOG("Metal output preview: EDR headroom \(headroom), screen brightness \(window?.screen.brightness ?? 0)", level: .debug)
            }
        } catch {
            onFailure?(error)
        }
    }
}
