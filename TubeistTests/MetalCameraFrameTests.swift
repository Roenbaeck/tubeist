//
//  MetalCameraFrameTests.swift
//  TubeistTests
//

import AVFoundation
import CoreVideo
import Metal
import Testing
@testable import Tubeist

#if !targetEnvironment(simulator)
private enum MetalCameraFrameTestError: Error, CustomStringConvertible {
    case cameraPermission(AVAuthorizationStatus)
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case noCaptureFormat
    case timedOut
    case missingImageBuffer
    case unexpectedPixelFormat(OSType)
    case invalidPlaneCount(Int)
    case textureCache(OSStatus)
    case lumaTexture(OSStatus)
    case chromaTexture(OSStatus)
    case missingMetalTexture
    case missingFilmFunction
    case commandObjects
    case commandFailed(String)

    var description: String {
        switch self {
        case .cameraPermission(let status):
            "Camera authorization is \(status.rawValue), not authorized"
        case .noCamera:
            "No back camera is available"
        case .cannotAddInput:
            "The camera input could not be added"
        case .cannotAddOutput:
            "The video output could not be added"
        case .noCaptureFormat:
            "Tubeist could not select its configured 10-bit capture format"
        case .timedOut:
            "Timed out waiting for a camera frame"
        case .missingImageBuffer:
            "The camera sample has no image buffer"
        case .unexpectedPixelFormat(let format):
            "The camera produced unexpected pixel format \(format)"
        case .invalidPlaneCount(let count):
            "The camera pixel buffer has \(count) planes instead of at least two"
        case .textureCache(let status):
            "CVMetalTextureCacheCreate failed with \(status)"
        case .lumaTexture(let status):
            "The camera luma plane could not become a Metal texture: \(status)"
        case .chromaTexture(let status):
            "The camera chroma plane could not become a Metal texture: \(status)"
        case .missingMetalTexture:
            "Core Video did not vend both underlying Metal textures"
        case .missingFilmFunction:
            "The Film function is missing from the app Metal library"
        case .commandObjects:
            "Metal command objects could not be created"
        case .commandFailed(let message):
            "The Film command failed: \(message)"
        }
    }
}

private final class MetalCameraFrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let metalDevice: MTLDevice
    private let library: MTLLibrary
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    init(metalDevice: MTLDevice, library: MTLLibrary) {
        self.metalDevice = metalDevice
        self.library = library
    }

    func waitForResult(timeout: TimeInterval) throws {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw MetalCameraFrameTestError.timedOut
        }
        try lock.withLock {
            try #require(result).get()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        let alreadyFinished = result != nil
        lock.unlock()
        guard !alreadyFinished else { return }

        let inspectedResult = Result { try inspect(sampleBuffer) }
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = inspectedResult
        lock.unlock()
        semaphore.signal()
    }

    private func inspect(_ sampleBuffer: CMSampleBuffer) throws {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw MetalCameraFrameTestError.missingImageBuffer
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let expectedFormats: Set<OSType> = [
            kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ]
        guard expectedFormats.contains(pixelFormat) else {
            throw MetalCameraFrameTestError.unexpectedPixelFormat(pixelFormat)
        }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard planeCount >= 2 else {
            throw MetalCameraFrameTestError.invalidPlaneCount(planeCount)
        }

        var textureCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            metalDevice,
            nil,
            &textureCache
        )
        guard cacheStatus == kCVReturnSuccess, let textureCache else {
            throw MetalCameraFrameTestError.textureCache(cacheStatus)
        }

        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        var lumaReference: CVMetalTexture?
        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r16Unorm,
            lumaWidth,
            lumaHeight,
            0,
            &lumaReference
        )
        guard lumaStatus == kCVReturnSuccess, let lumaReference else {
            throw MetalCameraFrameTestError.lumaTexture(lumaStatus)
        }

        var chromaReference: CVMetalTexture?
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg16Unorm,
            chromaWidth,
            chromaHeight,
            1,
            &chromaReference
        )
        guard chromaStatus == kCVReturnSuccess, let chromaReference else {
            throw MetalCameraFrameTestError.chromaTexture(chromaStatus)
        }

        guard let lumaTexture = CVMetalTextureGetTexture(lumaReference),
              let chromaTexture = CVMetalTextureGetTexture(chromaReference) else {
            throw MetalCameraFrameTestError.missingMetalTexture
        }
        guard let filmFunction = library.makeFunction(name: "film") else {
            throw MetalCameraFrameTestError.missingFilmFunction
        }

        let pipeline = try metalDevice.makeComputePipelineState(function: filmFunction)
        guard let commandQueue = metalDevice.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalCameraFrameTestError.commandObjects
        }

        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        var arguments = KernelArguments(
            strength: 1,
            frame: 1,
            threadgroupWidth: UInt32(threadWidth),
            threadgroupHeight: UInt32(threadHeight),
            widthRatio: UInt32(lumaWidth / chromaWidth),
            heightRatio: UInt32(lumaHeight / chromaHeight)
        )
        guard let argumentBuffer = metalDevice.makeBuffer(
            bytes: &arguments,
            length: MemoryLayout<KernelArguments>.size,
            options: [.cpuCacheModeWriteCombined]
        ) else {
            throw MetalCameraFrameTestError.commandObjects
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(lumaTexture, index: 0)
        encoder.setTexture(chromaTexture, index: 1)
        encoder.setBuffer(argumentBuffer, offset: 0, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: lumaWidth, height: lumaHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            throw MetalCameraFrameTestError.commandFailed(
                commandBuffer.error?.localizedDescription ?? "status \(commandBuffer.status.rawValue)"
            )
        }
    }
}

struct MetalCameraFrameTests {
    @Test(.timeLimit(.minutes(1)))
    func actualCameraFrameCreatesMetalTexturesAndRunsFilm() throws {
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        guard authorization == .authorized else {
            throw MetalCameraFrameTestError.cameraPermission(authorization)
        }

        let metalDevice = try #require(MTLCreateSystemDefaultDevice())
        let library = try #require(metalDevice.makeDefaultLibrary())
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw MetalCameraFrameTestError.noCamera
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        let receiver = MetalCameraFrameReceiver(metalDevice: metalDevice, library: library)

        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MetalCameraFrameTestError.cannotAddInput
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MetalCameraFrameTestError.cannotAddOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        guard let format = camera.findFormat() else {
            throw MetalCameraFrameTestError.noCaptureFormat
        }
        try camera.lockForConfiguration()
        camera.activeFormat = format
        camera.activeColorSpace = AV_COLOR_SPACE
        camera.unlockForConfiguration()

        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(
            receiver,
            queue: DispatchQueue(label: "MetalCameraFrameTests.capture")
        )

        session.startRunning()
        defer {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
        }
        try receiver.waitForResult(timeout: 15)
    }
}
#endif
