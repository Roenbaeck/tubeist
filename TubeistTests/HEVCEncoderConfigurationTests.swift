import Testing
import VideoToolbox
@testable import Tubeist

struct HEVCEncoderConfigurationTests {
    @Test func camera420NeverAttempts422() throws {
        for pixelFormat in [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                            kCVPixelFormatType_32BGRA] {
            var selection = HEVCEncoderSelection()
            var attempts: [HEVCChromaSampling] = []
            let result = try selection.makeEncoder(sourcePixelFormat: pixelFormat) { chroma in
                attempts.append(chroma)
                return chroma
            }
            #expect(result == .yuv420)
            #expect(attempts == [.yuv420])
        }
    }

    @Test func camera422Uses422WhenHardwareAcceptsIt() throws {
        for pixelFormat in [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                            kCVPixelFormatType_422YpCbCr10BiPlanarFullRange] {
            var selection = HEVCEncoderSelection()
            let chosen = try selection.makeEncoder(sourcePixelFormat: pixelFormat) { chroma in
                var profile: String?
                try HEVCEncoderConfiguration.apply(frameRate: 60, bitrate: 20_000_000,
                    keyframeInterval: 2, chroma: chroma) { key, value in
                    if key == kVTCompressionPropertyKey_ProfileLevel { profile = value as? String }
                    return noErr
                }
                return profile
            }
            #expect(chosen == kVTProfileLevel_HEVC_Main42210_AutoLevel as String)
            #expect(selection.chroma == .yuv422)
            #expect(selection.fallbackReason == nil)
        }
    }

    @Test func disabling422SkipsTheAttemptEvenForA422Camera() throws {
        for pixelFormat in [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                            kCVPixelFormatType_422YpCbCr10BiPlanarFullRange] {
            var selection = HEVCEncoderSelection(allows422: false)
            var attempts: [HEVCChromaSampling] = []
            let chosen = try selection.makeEncoder(sourcePixelFormat: pixelFormat) { chroma in
                attempts.append(chroma)
                return chroma
            }
            #expect(chosen == .yuv420)
            // No hardware session may be created for a profile the user declined.
            #expect(attempts == [.yuv420])
            #expect(selection.chroma == .yuv420)
            #expect(selection.fallbackReason == "turned off in Settings")
        }
    }

    @Test func disabling422LeavesA420CameraUnremarked() throws {
        var selection = HEVCEncoderSelection(allows422: false)
        let chosen = try selection.makeEncoder(sourcePixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) { $0 }
        #expect(chosen == .yuv420)
        #expect(selection.fallbackReason == nil)
    }

    @Test func unsupported422FallsBackAndRecoveryKeeps420() throws {
        var selection = HEVCEncoderSelection()
        var attempts: [HEVCChromaSampling] = []
        let chosen = try selection.makeEncoder(sourcePixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange) { chroma in
            attempts.append(chroma)
            if chroma == .yuv422 { throw MediaEncodingError.operation("Preparing encoder", kVTPropertyNotSupportedErr) }
            return chroma
        }
        #expect(chosen == .yuv420)
        #expect(attempts == [.yuv422, .yuv420])
        #expect(selection.fallbackReason != nil)
        attempts.removeAll()
        // Even if resources/capabilities change, a recording cannot change profile.
        _ = try selection.makeEncoder(sourcePixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange) { chroma in
            attempts.append(chroma)
        }
        #expect(attempts == [.yuv420])
    }

    @Test func failedFallbackDoesNotCommitSelectionOrHideFailure() {
        var selection = HEVCEncoderSelection()
        var attempts: [HEVCChromaSampling] = []
        do {
            _ = try selection.makeEncoder(sourcePixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange) { chroma in
                attempts.append(chroma)
                throw MediaEncodingError.invalid(chroma.rawValue)
            }
            Issue.record("Accepted an encoder when both profiles failed")
        } catch MediaEncodingError.invalid(let message) {
            #expect(message == "4:2:0")
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(attempts == [.yuv422, .yuv420])
        #expect(selection.chroma == nil)
    }

    @Test func recoveryFailureDoesNotChangeAnEstablished422Profile() throws {
        var selection = HEVCEncoderSelection()
        _ = try selection.makeEncoder(sourcePixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange) { $0 }
        var attempts: [HEVCChromaSampling] = []
        #expect(throws: MediaEncodingError.self) {
            try selection.makeEncoder(sourcePixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange) { chroma in
                attempts.append(chroma)
                throw MediaEncodingError.operation("Recovering encoder", kVTVideoEncoderNotAvailableNowErr)
            }
        }
        #expect(attempts == [.yuv422])
        #expect(selection.chroma == .yuv422)
    }

    @Test func newSessionReevaluatesTheCameraFormat() throws {
        var selection = HEVCEncoderSelection()
        _ = try selection.makeEncoder(sourcePixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange) { $0 }
        selection = HEVCEncoderSelection()
        let chosen = try selection.makeEncoder(sourcePixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) { $0 }
        #expect(chosen == .yuv420)
    }

    @Test func unsupportedDelayLimitStillAppliesHDRAndClosedGOPSettings() throws {
        var applied: [String: AnyObject] = [:]
        try HEVCEncoderConfiguration.apply(frameRate: 60, bitrate: 20_000_000, keyframeInterval: 2) { key, value in
            applied[key as String] = value
            return key == kVTCompressionPropertyKey_MaxFrameDelayCount ? kVTPropertyNotSupportedErr : noErr
        }
        #expect(applied[kVTCompressionPropertyKey_AllowOpenGOP as String] as? Bool == false)
        #expect(applied[kVTCompressionPropertyKey_ProfileLevel as String] as? String == kVTProfileLevel_HEVC_Main10_AutoLevel as String)
        #expect(applied[kVTCompressionPropertyKey_TransferFunction as String] as? String == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        #expect(applied[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] as? String == kVTHDRMetadataInsertionMode_Auto as String)
    }

    @Test(arguments: ["ProfileLevel", "RealTime", "AverageBitRate", "ExpectedFrameRate",
                     "MaxKeyFrameInterval", "MaxKeyFrameIntervalDuration", "AllowFrameReordering", "AllowOpenGOP",
                     "ColorPrimaries", "TransferFunction", "YCbCrMatrix", "HDRMetadataInsertionMode"])
    func unsupportedRequiredSettingStillFailsAndNamesTheProperty(property: String) {
        do {
            try HEVCEncoderConfiguration.apply(frameRate: 30, bitrate: 8_000_000, keyframeInterval: 2) { key, _ in
                key as String == property ? kVTPropertyNotSupportedErr : noErr
            }
            Issue.record("Unsupported required setting was accepted: \(property)")
        } catch MediaEncodingError.operation(let operation, let status) {
            #expect(operation.contains(property))
            #expect(status == kVTPropertyNotSupportedErr)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func unrelatedDelaySettingErrorsStillFail() {
        do {
            try HEVCEncoderConfiguration.apply(frameRate: 30, bitrate: 8_000_000, keyframeInterval: 2) { key, _ in
                key == kVTCompressionPropertyKey_MaxFrameDelayCount ? kVTParameterErr : noErr
            }
            Issue.record("Unexpected delay setting error was ignored")
        } catch MediaEncodingError.operation(let operation, let status) {
            #expect(operation.contains("MaxFrameDelayCount"))
            #expect(status == kVTParameterErr)
        } catch { Issue.record("Unexpected error: \(error)") }
    }
}
