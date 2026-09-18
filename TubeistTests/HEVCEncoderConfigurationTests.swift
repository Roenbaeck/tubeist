import Testing
import VideoToolbox
@testable import Tubeist

struct HEVCEncoderConfigurationTests {
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
