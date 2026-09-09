import CoreVideo

// Keep the field order in sync with ImprintArguments in Kernels.metal.
struct ImprintArguments {
    var offsetX: UInt32 = 0
    var offsetY: UInt32 = 0
    var widthRatio: UInt32 = 1
    var heightRatio: UInt32 = 1
    var videoRange: UInt32 = 0

    mutating func setPixelFormat(_ pixelFormat: OSType) {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
            videoRange = 1
        default:
            videoRange = 0
        }
    }
}
