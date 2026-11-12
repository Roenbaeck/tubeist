//
//  FrameGrabber.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2024-12-05.
//

import AVFoundation
import CoreImage
import Metal

// this is not 1-1 with the Metal struct, since textures are set differently
struct KernelArguments {
    var strength: Float = 0
    var frame: UInt32 = 0
    var threadgroupWidth: UInt32 = 0
    var threadgroupHeight: UInt32 = 0
    var widthRatio: UInt32 = 1
    var heightRatio: UInt32 = 1
}

struct KernelSettings {
    var pipeline: MTLComputePipelineState
    var threads: MTLSize
    var args: MTLBuffer // of type KernelArguments
}

/// A rendered overlay texture crossing actors. Metal textures are thread-safe
/// to hand over; only one owner reads or writes a texture at a time.
private struct OverlayTexture: @unchecked Sendable {
    let texture: MTLTexture
    let seconds: TimeInterval
}

/// Renders overlay snapshots away from the camera frame path. Core Image's
/// bitmap upload and the GPU render used to block FrameTinkerer, and with it
/// every camera frame, for the whole update. Frames now keep imprinting the
/// previous texture until the new one has completed.
private actor OverlayTextureUploader {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    // Textures no frame can still be waiting to read; see recycle().
    private var free: [MTLTexture] = []

    init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
        context = CIContext(
            mtlDevice: device,
            options: [
                .useSoftwareRenderer: false,
                .workingColorSpace: CG_COLOR_SPACE,
                .cacheIntermediates: true,
                .memoryTarget: 512
            ])
    }

    func upload(_ image: CIImage) async -> OverlayTexture? {
        let started = ProcessInfo.processInfo.systemUptime
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        guard width > 0, height > 0 else { return nil }
        let texture: MTLTexture
        if let index = free.firstIndex(where: { $0.width == width && $0.height == height }) {
            texture = free.remove(at: index)
        } else {
            let descriptor = MTLTextureDescriptor()
            descriptor.pixelFormat = .rgba16Unorm
            descriptor.width = width
            descriptor.height = height
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            guard let created = device.makeTexture(descriptor: descriptor) else {
                LOG("Could not create Metal texture from the combined overlay", level: .error)
                return nil
            }
            texture = created
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            LOG("Could not create command buffer to render the combined overlay", level: .error)
            free.append(texture)
            return nil
        }
        // The imprint kernel expects HLG/BT.2020 RGB, regardless of the overlay's source color space.
        context.render(image, to: texture, commandBuffer: commandBuffer, bounds: image.extent, colorSpace: CG_COLOR_SPACE)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }
        return OverlayTexture(texture: texture, seconds: ProcessInfo.processInfo.systemUptime - started)
    }

    /// Accepts a texture that frames have stopped selecting. Frames that did
    /// select it were committed earlier to this same command queue, which runs
    /// command buffers in commit order, so a later render cannot overtake them.
    func recycle(_ recycled: OverlayTexture) {
        // One spare is enough for alternating updates; a 4K texture is 66 MB.
        free = [recycled.texture]
    }
}

/// Counts frames the capture system discarded before delivering them.
private final class CaptureDropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    func increment() -> Int { lock.withLock { total += 1; return total } }
    func reset() { lock.withLock { total = 0 } }
    func count() -> Int { lock.withLock { total } }
}

private actor FrameTinkerer {
    // GPU work and hardware encoding overlap, sharing the same bounded
    // arrival-age budget as the capture queue. No pixel copies or retiming.
    private let encodingMailbox = BoundedAsyncMailbox<SendableSampleBuffer>(
        policy: CaptureBuffering.videoPolicy, timing: { $0.mailboxTiming },
        onDrop: { submission in
            guard submission.shouldReport(every: 120) else { return }
            LOG("Dropped video exceeding the pre-encoding buffer budget", level: .warning)
            Task { await Streamer.shared.setStreamHealth(.degraded) }
        }
    ) { sample in
        do {
            try await ContentPackager.shared.appendVideoSampleBuffer(sample.value)
        } catch {
            Task { await Streamer.shared.handleRuntimeFailure(error) }
        }
    }

    nonisolated func resetEncodingDropCount() { encodingMailbox.resetDropCount() }
    nonisolated func encodingDropCount() -> Int { encodingMailbox.snapshot().totalDropped }
    nonisolated func drainEncoding() async { await encodingMailbox.waitUntilIdle() }
    nonisolated func drainEncoding(deadline: ContinuousClock.Instant) async -> Bool {
        await encodingMailbox.waitUntilIdle(deadline: deadline)
    }

    // frame grabbing settings
    private var grabbingFrames: Bool = false
    private var style: String?
    private var styleStrength: Float = 1.0
    private var effect: String?
    private var effectStrength: Float = 1.0

    // metal stuff
    private var metalDevice: MTLDevice?
    private var library: MTLLibrary?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var kernels: [String: KernelSettings] = [:]
    private var lumaTexture: CVMetalTexture?
    private var chromaTexture: CVMetalTexture?
    private var vhsSourceY: MTLTexture?
    private var vhsSourceCbCr: MTLTexture?
    private var loggedDiagnostics: Set<String> = []

    // overlay imprinting
    private var overlayTexture: MTLTexture?
    private var overlayUploader: OverlayTextureUploader?
    private var overlayGeneration: UInt64 = 0
    private var lastSlowOverlayReport = -TimeInterval.infinity
    private var imprintPipeline: MTLComputePipelineState?
    private var boundingBoxData: [(MTLBuffer, MTLSize, MTLSize)] = []
    private var overlayRegions: [CGRect] = []
    private var imprintArguments = ImprintArguments()
    private var pixelFormat: OSType?
    
    // resettable
    private var measureTextures: Bool = true
    private var lumaWidth: Int = DEFAULT_CAPTURE_WIDTH
    private var lumaHeight: Int = DEFAULT_CAPTURE_HEIGHT
    private var chromaWidth: Int = DEFAULT_CAPTURE_WIDTH
    private var chromaHeight: Int = DEFAULT_CAPTURE_HEIGHT
    private var lumaChromaWidthRatio: UInt32 = 1
    private var lumaChromaHeightRatio: UInt32 = 1
    private var currentPresentationTimestamp: CMTime?
    private var frameNumber: UInt32 = 0
    private var threadsPerGrid: MTLSize = MTLSize(
        width: DEFAULT_CAPTURE_WIDTH,
        height: DEFAULT_CAPTURE_HEIGHT,
        depth: 1
    )

    func start() {
        grabbingFrames = true
    }
    func stop() {
        grabbingFrames = false
    }
    func isActive() -> Bool {
        grabbingFrames
    }
    func refreshStyle() {
        let selectedStyle = Settings.style
        guard let selectedStyle, selectedStyle != NO_STYLE else {
            style = nil
            vhsSourceY = nil
            vhsSourceCbCr = nil
            return
        }
        guard kernels[selectedStyle] != nil else {
            style = nil
            logOnce(
                key: "style-\(selectedStyle)",
                message: "Style '\(selectedStyle)' is unavailable because its Metal kernel was not loaded"
            )
            return
        }
        style = selectedStyle
        if selectedStyle != "VHS" {
            vhsSourceY = nil
            vhsSourceCbCr = nil
        }
    }
    func getStyle() -> String? {
        style
    }
    func setStyleStrength(_ strength: Float) {
        self.styleStrength = strength
    }
    func getStyleStrength() -> Float {
        styleStrength
    }
    func refreshEffect() {
        let selectedEffect = Settings.effect
        guard let selectedEffect, selectedEffect != NO_EFFECT else {
            effect = nil
            return
        }
        guard kernels[selectedEffect] != nil else {
            effect = nil
            logOnce(
                key: "effect-\(selectedEffect)",
                message: "Effect '\(selectedEffect)' is unavailable because its Metal kernel was not loaded"
            )
            return
        }
        effect = selectedEffect
    }
    func getEffect() -> String? {
        effect
    }
    func setEffectStrength(_ strength: Float) {
        self.effectStrength = strength
    }
    func getEffectStrength() -> Float {
        effectStrength
    }
    
    init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice(),
              let commandQueue = metalDevice.makeCommandQueue() else {
            LOG("Metal is unavailable; styles, effects and overlays cannot be rendered", level: .warning)
            return
        }
        LOG("Created rendering context with Metal support", level: .debug)
        commandQueue.label = "FrameTinkerer"
        self.metalDevice = metalDevice
        self.commandQueue = commandQueue
        // Shares the frame command queue: its ordering is what makes it safe
        // to render into a texture earlier frames have finished selecting.
        overlayUploader = OverlayTextureUploader(device: metalDevice, commandQueue: commandQueue)
        var textureCache: CVMetalTextureCache?
        let textureCacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            metalDevice,
            nil,
            &textureCache
        )
        guard textureCacheStatus == kCVReturnSuccess, let textureCache else {
            LOG("Could not create the Metal texture cache (Core Video \(textureCacheStatus))", level: .error)
            return
        }
        self.textureCache = textureCache

        guard let library = metalDevice.makeDefaultLibrary() else {
            LOG("Could not load Tubeist's default Metal shader library", level: .error)
            return
        }
        self.library = library

        var kernelNames = AVAILABLE_STYLES.filter( { $0 != NO_STYLE } )
        kernelNames.append(contentsOf: AVAILABLE_EFFECTS.filter( { $0 != NO_EFFECT } ))
                                                   
        for kernel in kernelNames {
            guard let function = library.makeFunction(name: kernel.lowercased()) else {
                LOG("Could not make function out of kernel code '\(kernel)'", level: .error)
                continue
            }
            do {
                let pipeline = try metalDevice.makeComputePipelineState(function: function)
                // calculating optimum threadgroup and grid sizes
                let w = pipeline.threadExecutionWidth
                let h = pipeline.maxTotalThreadsPerThreadgroup / w
                let threads = MTLSize(width: w, height: h, depth: 1)
                
                var kernelArguments = KernelArguments()
                kernelArguments.threadgroupWidth = UInt32(w)
                kernelArguments.threadgroupHeight = UInt32(h)
                kernelArguments.widthRatio = lumaChromaWidthRatio
                kernelArguments.heightRatio = lumaChromaHeightRatio
                
                guard let kernelArgumentBuffer = metalDevice.makeBuffer(
                    bytes: &kernelArguments,
                    length: MemoryLayout<KernelArguments>.size,
                    options: [.cpuCacheModeWriteCombined]
                )
                else {
                    LOG("Could not create kernel argument buffer", level: .error)
                    continue
                }

                kernels[kernel] = KernelSettings(
                    pipeline: pipeline,
                    threads: threads,
                    args: kernelArgumentBuffer
                )
            }
            catch {
                LOG("Failed to create pipeline state for kernel '\(kernel)': \(error)", level: .error)
            }
        }

        if let imprintFunction = library.makeFunction(name: "imprint") {
            do {
                imprintPipeline = try metalDevice.makeComputePipelineState(function: imprintFunction)
            } catch {
                LOG("Failed to create the imprint pipeline state: \(error)", level: .error)
            }
        } else {
            LOG("Could not make function out of imprint kernel", level: .error)
        }

        LOG("Loaded \(kernels.count) Metal style/effect pipelines", level: .debug)
    }

    private func logOnce(key: String, message: String, level: LogLevel = .error) {
        guard loggedDiagnostics.insert(key).inserted else { return }
        LOG(message, level: level)
    }
    
    func reset() {
        measureTextures = true
        currentPresentationTimestamp = nil
        frameNumber = 0
        threadsPerGrid = MTLSize(
            width: DEFAULT_CAPTURE_WIDTH,
            height: DEFAULT_CAPTURE_HEIGHT,
            depth: 1
        )
    }
    
    func getCurrentPresentationTimestamp() -> CMTime? {
        currentPresentationTimestamp
    }
    
    func setCombinedOverlay(_ combinedOverlay: CombinedOverlay?) async {
        // This actor is re-entered while an upload is awaited. The newest
        // request wins; an older upload that finishes later is discarded.
        overlayGeneration &+= 1
        let generation = overlayGeneration
        guard let combinedOverlay else {
            // Clear before suspending: a newer request may run meanwhile.
            boundingBoxData = []
            overlayRegions = []
            await replaceOverlayTexture(with: nil)
            return
        }
        guard let metalDevice, let overlayUploader else {
            logOnce(
                key: "overlay-metal-device",
                message: "Overlay rendering is unavailable because Metal could not be initialized"
            )
            return
        }
        guard let imprintPipeline else {
            logOnce(
                key: "overlay-imprint-pipeline",
                message: "Overlay rendering is unavailable because the imprint kernel was not loaded"
            )
            return
        }

        // Camera frames continue with the previous overlay during this await.
        guard let uploaded = await overlayUploader.upload(combinedOverlay.image) else { return }
        guard generation == overlayGeneration else {
            // No frame ever selected this texture, so it is free immediately.
            await overlayUploader.recycle(uploaded)
            return
        }
        reportSlowOverlayUpload(uploaded.seconds)

        let w = imprintPipeline.threadExecutionWidth
        let h = imprintPipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerThreadgroup = MTLSizeMake(w, h, 1)

        let regions = ImprintArguments.regions(
            bounds: combinedOverlay.image.extent,
            boundingBoxes: combinedOverlay.boundingBoxes,
            coverage: combinedOverlay.coverage
        )
        if regions != overlayRegions {
            var regionData: [(MTLBuffer, MTLSize, MTLSize)] = []
            for box in regions {
                var imprintArguments = self.imprintArguments
                imprintArguments.offsetX = UInt32(box.origin.x)
                imprintArguments.offsetY = UInt32(box.origin.y)
                let imprintArgumentBuffer = metalDevice.makeBuffer(
                    bytes: &imprintArguments,
                    length: MemoryLayout<ImprintArguments>.size,
                    options: [.cpuCacheModeWriteCombined]
                )
                let threadsPerGrid = MTLSize(
                    width: Int(box.size.width), height: Int(box.size.height), depth: 1
                )
                if let imprintArgumentBuffer {
                    regionData.append((imprintArgumentBuffer, threadsPerGrid, threadsPerThreadgroup))
                }
            }
            boundingBoxData = regionData
            overlayRegions = regionData.count == regions.count ? regions : []
        }
        // The texture and its regions change together, between two frames:
        // nothing suspends from here to the end of this function's swap.
        let previous = overlayTexture
        overlayTexture = uploaded.texture
        if let previous {
            await overlayUploader.recycle(OverlayTexture(texture: previous, seconds: 0))
        }
    }

    private func replaceOverlayTexture(with texture: MTLTexture?) async {
        let previous = overlayTexture
        overlayTexture = texture
        if let previous {
            await overlayUploader?.recycle(OverlayTexture(texture: previous, seconds: 0))
        }
    }

    /// An upload no longer delays camera frames, but a slow one still limits
    /// how fresh the overlay can be and competes for the GPU.
    private func reportSlowOverlayUpload(_ seconds: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        guard seconds >= 0.05, now - lastSlowOverlayReport >= 30 else { return }
        lastSlowOverlayReport = now
        LOG(String(format: "Overlay texture upload took %.0f ms", seconds * 1000), level: .debug)
    }
    
    func createTextures(from sampleBuffer: CMSampleBuffer) -> Bool {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logTextureFailure("Cannot get a pixel buffer from the video sample")
            return false
        }
        guard let textureCache else {
            logTextureFailure("Cannot create video textures because the Metal texture cache is unavailable")
            return false
        }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else {
            logTextureFailure("Cannot create video textures from a non-planar pixel buffer")
            return false
        }

        let currentPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if measureTextures || pixelFormat != currentPixelFormat {
            let measuredLumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let measuredLumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let measuredChromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let measuredChromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            guard measuredLumaWidth > 0,
                  measuredLumaHeight > 0,
                  measuredChromaWidth > 0,
                  measuredChromaHeight > 0 else {
                logTextureFailure("Cannot create video textures with empty pixel-buffer planes")
                return false
            }
            lumaWidth = measuredLumaWidth
            lumaHeight = measuredLumaHeight
            chromaWidth = measuredChromaWidth
            chromaHeight = measuredChromaHeight
            lumaChromaWidthRatio = UInt32(lumaWidth / chromaWidth)
            lumaChromaHeightRatio = UInt32(lumaHeight / chromaHeight)
            pixelFormat = currentPixelFormat
            imprintArguments.widthRatio = lumaChromaWidthRatio
            imprintArguments.heightRatio = lumaChromaHeightRatio
            imprintArguments.setPixelFormat(currentPixelFormat)
            
            for kernel in kernels.keys {
                let args = kernels[kernel]!.args
                let argsPointer = args.contents().bindMemory(to: KernelArguments.self, capacity: 1)
                argsPointer.pointee.widthRatio = lumaChromaWidthRatio
                argsPointer.pointee.heightRatio = lumaChromaHeightRatio
            }
            for (args, _, _) in boundingBoxData {
                let argsPointer = args.contents().bindMemory(to: ImprintArguments.self, capacity: 1)
                argsPointer.pointee.widthRatio = lumaChromaWidthRatio
                argsPointer.pointee.heightRatio = lumaChromaHeightRatio
                argsPointer.pointee.videoRange = imprintArguments.videoRange
            }

            threadsPerGrid = MTLSize(
                width: lumaWidth,
                height: lumaHeight,
                depth: 1
            )
            
            measureTextures = false
        }
        // The matrix is a frame attachment, independent of the pixel format.
        let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        var matrixArguments = imprintArguments
        matrixArguments.setYCbCrMatrix(matrix)
        if (matrixArguments.matrixKr, matrixArguments.matrixKb) != (imprintArguments.matrixKr, imprintArguments.matrixKb) {
            imprintArguments = matrixArguments
            for (args, _, _) in boundingBoxData {
                let argsPointer = args.contents().bindMemory(to: ImprintArguments.self, capacity: 1)
                argsPointer.pointee.matrixKr = imprintArguments.matrixKr
                argsPointer.pointee.matrixKb = imprintArguments.matrixKb
            }
        }
        var newLumaTexture: CVMetalTexture?
        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r16Unorm,
            lumaWidth,
            lumaHeight,
            0,
            &newLumaTexture
        )
        var newChromaTexture: CVMetalTexture?
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg16Unorm,
            chromaWidth,
            chromaHeight,
            1,
            &newChromaTexture
        )
        guard lumaStatus == kCVReturnSuccess,
              chromaStatus == kCVReturnSuccess,
              let newLumaTexture,
              let newChromaTexture,
              CVMetalTextureGetTexture(newLumaTexture) != nil,
              CVMetalTextureGetTexture(newChromaTexture) != nil else {
            lumaTexture = nil
            chromaTexture = nil
            CVMetalTextureCacheFlush(textureCache, 0)
            logTextureFailure(
                "Could not create Metal textures from the pixel buffer planes " +
                "(luma \(lumaStatus), chroma \(chromaStatus), format \(CVPixelBufferGetPixelFormatType(pixelBuffer)))"
            )
            return false
        }
        lumaTexture = newLumaTexture
        chromaTexture = newChromaTexture
        return true
    }

    private func logTextureFailure(_ message: String) {
        logOnce(key: "texture-failure", message: message)
    }

    private func prepareVHS(commandBuffer: MTLCommandBuffer) -> Bool {
        guard let metalDevice, let lumaTexture, let chromaTexture,
              let y = CVMetalTextureGetTexture(lumaTexture),
              let cbcr = CVMetalTextureGetTexture(chromaTexture) else { return false }
        func snapshotTexture(for source: MTLTexture, height: Int, cached: MTLTexture?) -> MTLTexture? {
            if let cached, cached.width == source.width, cached.height == height,
               cached.pixelFormat == source.pixelFormat { return cached }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat,
                width: source.width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = .shaderRead
            return metalDevice.makeTexture(descriptor: descriptor)
        }
        vhsSourceY = snapshotTexture(for: y, height: Int(ceil(Float(y.height) * 0.05)), cached: vhsSourceY)
        vhsSourceCbCr = snapshotTexture(for: cbcr, height: cbcr.height, cached: vhsSourceCbCr)
        guard let vhsSourceY, let vhsSourceCbCr, let blit = commandBuffer.makeBlitCommandEncoder() else {
            logOnce(key: "vhs-snapshot", message: "Could not prepare VHS source textures")
            return false
        }
        // VHS reads displaced neighbours. Read an immutable copy so GPU scheduling
        // cannot make it sample pixels that another thread has already modified.
        // This is a byte copy of the original Y/CbCr planes, with no color conversion.
        blit.copy(from: y, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: y.width, height: vhsSourceY.height, depth: 1),
            to: vhsSourceY, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.copy(from: cbcr, to: vhsSourceCbCr)
        blit.endEncoding()
        return true
    }
    
    func apply(kernel: String, strength: Float, encoder: MTLComputeCommandEncoder) {
        guard let kernelSettings = kernels[kernel] else {
            logOnce(
                key: "runtime-kernel-\(kernel)",
                message: "Cannot apply '\(kernel)' because its Metal pipeline is unavailable"
            )
            return
        }
        guard let lumaTexture,
              let chromaTexture,
              let metalLumaTexture = CVMetalTextureGetTexture(lumaTexture),
              let metalChromaTexture = CVMetalTextureGetTexture(chromaTexture) else {
            logTextureFailure("Cannot apply '\(kernel)' because the video textures are unavailable")
            return
        }
        
        let argsPointer = kernelSettings.args.contents().bindMemory(to: KernelArguments.self, capacity: 1)
        argsPointer.pointee.strength = strength
        argsPointer.pointee.frame = frameNumber

        if kernel == "VHS" {
            guard let vhsSourceY, let vhsSourceCbCr else { return }
            encoder.setTexture(vhsSourceY, index: 2)
            encoder.setTexture(vhsSourceCbCr, index: 3)
        }
        encoder.setComputePipelineState(kernelSettings.pipeline)
        encoder.setTexture(metalLumaTexture, index: 0)
        encoder.setTexture(metalChromaTexture, index: 1)
        encoder.setBuffer(kernelSettings.args, offset: 0, index: 0)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: kernelSettings.threads)
        encoder.memoryBarrier(scope: .textures)
    }

    func imprintOverlay(encoder: MTLComputeCommandEncoder) {
        guard let imprintPipeline else {
            logOnce(
                key: "runtime-imprint-pipeline",
                message: "Cannot imprint the overlay because its Metal pipeline is unavailable"
            )
            return
        }
        guard let lumaTexture,
              let chromaTexture,
              let metalLumaTexture = CVMetalTextureGetTexture(lumaTexture),
              let metalChromaTexture = CVMetalTextureGetTexture(chromaTexture) else {
            logTextureFailure("Cannot imprint the overlay because the video textures are unavailable")
            return
        }
        
        encoder.setComputePipelineState(imprintPipeline)
        encoder.setTexture(metalLumaTexture, index: 0)
        encoder.setTexture(metalChromaTexture, index: 1)
        encoder.setTexture(overlayTexture, index: 2)

        for (imprintArgumentBuffer, threadsPerGrid, threadsPerThreadgroup) in boundingBoxData {
            encoder.setBuffer(imprintArgumentBuffer, offset: 0, index: 0)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        }
    }
    
    func processFrame(_ wrappedSampleBuffer: SendableSampleBuffer) async {
        let sampleBuffer = wrappedSampleBuffer.value
        currentPresentationTimestamp = sampleBuffer.presentationTimeStamp
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer // removes the need for @preconcurrency
        if grabbingFrames {
            if style != nil || effect != nil || overlayTexture != nil {
                frameNumber += 1
                frameNumber %= 600 // restart counter every 600 frames
                if createTextures(from: sendableSampleBuffer) {
                    if let commandBuffer = commandQueue?.makeCommandBuffer() {
                        var styleReady = true
                        if style == "VHS" { styleReady = prepareVHS(commandBuffer: commandBuffer) }
                        if let encoder = commandBuffer.makeComputeCommandEncoder() {
                            if let style, styleReady {
                                apply(kernel: style, strength: styleStrength, encoder: encoder)
                            }
                            if let effect {
                                apply(kernel: effect, strength: effectStrength, encoder: encoder)
                            }
                            if overlayTexture != nil {
                                imprintOverlay(encoder: encoder)
                            }
                            encoder.endEncoding()
                            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                                commandBuffer.addCompletedHandler { _ in continuation.resume() }
                                commandBuffer.commit()
                            }
                        } else {
                            logOnce(key: "command-objects", message: "Could not create Metal command objects")
                        }
                    } else {
                        logOnce(key: "command-objects", message: "Could not create Metal command objects")
                    }
                }
            }
            if await Streamer.shared.isStreaming() {
                encodingMailbox.submit(wrappedSampleBuffer)
            }
            if OutputMonitorView.frameGate.isEnabled() {
                OutputMonitorView.enqueue(SendableSampleBuffer(value: sendableSampleBuffer))
            }
        }
    }

}

final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    @PipelineActor public static let shared = FrameGrabber()
    private let frameTinkerer: FrameTinkerer
    private let frameMailbox: BoundedAsyncMailbox<SendableSampleBuffer>
    private let captureDrops = CaptureDropCounter()

    override init() {
        let frameTinkerer = FrameTinkerer()
        self.frameTinkerer = frameTinkerer
        self.frameMailbox = BoundedAsyncMailbox(
            policy: CaptureBuffering.videoPolicy, timing: { $0.mailboxTiming },
            onDrop: { submission in
                guard submission.shouldReport(every: 120) else { return }
                LOG("Dropped video exceeding the capture buffer budget", level: .warning)
                Task { await Streamer.shared.setStreamHealth(.degraded) }
            }
        ) { sampleBuffer in
            await frameTinkerer.processFrame(sampleBuffer)
        }
        super.init()
    }

    func resetTinkerer() async {
        await frameTinkerer.reset()
    }
    
    func commenceGrabbing() async {
        if await !frameTinkerer.isActive() {
            await frameTinkerer.reset()
            await frameTinkerer.refreshStyle()
            await frameTinkerer.refreshEffect()
            await frameTinkerer.start()
            frameMailbox.resetDropCount()
            frameTinkerer.resetEncodingDropCount()
            LOG("Started grabbing frames", level: .debug)
        }
        else {
            LOG("Frame grabbing already started", level: .debug)
        }
    }
    func terminateGrabbing() async {
        if await frameTinkerer.isActive() {
            await frameTinkerer.stop()
            LOG("Stopped grabbing frames", level: .debug)
        }
        else {
            LOG("Frame grabbing already stopped", level: .debug)
        }
    }
    func refreshStyle() async {
        await frameTinkerer.refreshStyle()
    }
    func setStyleStrength(to strength: Float) async {
        await frameTinkerer.setStyleStrength(strength)
    }
    func refreshEffect() async {
        await frameTinkerer.refreshEffect()
    }
    func setEffectStrength(to strength: Float) async {
        await frameTinkerer.setEffectStrength(strength)
    }
    func setCombinedOverlay(_ combinedOverlay: CombinedOverlay?) async {
        await frameTinkerer.setCombinedOverlay(combinedOverlay)
    }
    func getCurrentPresentationTimestamp() async -> CMTime? {
        await frameTinkerer.getCurrentPresentationTimestamp()
    }
    func resetDroppedFrameCount() {
        // Output preview may already be running. Reset only diagnostics,
        // leaving its queued and in-flight frames untouched.
        frameMailbox.resetDropCount()
        frameTinkerer.resetEncodingDropCount()
        captureDrops.reset()
    }
    func logDroppedFrameCount() {
        let processingDrops = frameMailbox.snapshot().totalDropped
        let encodingDrops = frameTinkerer.encodingDropCount()
        let cameraDrops = captureDrops.count()
        LOG("Stream frame processing: \(cameraDrops + processingDrops + encodingDrops) video frames dropped before encoding (camera: \(cameraDrops), processing queue: \(processingDrops), encoder queue: \(encodingDrops))", level: .info)
    }
    func drainSubmittedFrames() async {
        await frameMailbox.waitUntilIdle()
        await frameTinkerer.drainEncoding()
    }

    func drainSubmittedFrames(deadline: ContinuousClock.Instant) async -> Bool {
        guard await frameMailbox.waitUntilIdle(deadline: deadline) else { return false }
        return await frameTinkerer.drainEncoding(deadline: deadline)
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        nonisolated(unsafe) let sendableSampleBuffer = sampleBuffer
        frameMailbox.submit(SendableSampleBuffer(value: sendableSampleBuffer))
    }

    /// The capture system discarded a frame before delivering it, e.g. because
    /// its buffer pool was exhausted or an earlier callback was still running.
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let total = captureDrops.increment()
        guard total == 1 || total.isMultiple(of: 120) else { return }
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: nil) as? String ?? "unknown reason"
        LOG("The camera has discarded \(total) frame\(total == 1 ? "" : "s") before delivery (\(reason))", level: .warning)
    }
}
