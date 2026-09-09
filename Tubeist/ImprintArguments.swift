import CoreVideo
import CoreGraphics

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

    // Cover complete 2x2 cells (also safe for 4:2:2 and 4:4:4). Coalesce after
    // alignment so the combined overlay is applied only once to each sample.
    static func regions(bounds: CGRect, boundingBoxes: [CGRect], coverage: Double) -> [CGRect] {
        guard !bounds.isEmpty else { return [] }
        if coverage > 0.75 || boundingBoxes.isEmpty { return [bounds] }
        var regions: [CGRect] = []
        for box in boundingBoxes {
            let clipped = box.intersection(bounds)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            let minX = floor(clipped.minX / 2) * 2
            let minY = floor(clipped.minY / 2) * 2
            var region = CGRect(
                x: minX, y: minY,
                width: ceil(clipped.maxX / 2) * 2 - minX,
                height: ceil(clipped.maxY / 2) * 2 - minY
            ).intersection(bounds)
            while let index = regions.firstIndex(where: { $0.intersects(region) }) {
                region = region.union(regions.remove(at: index))
            }
            regions.append(region)
        }
        return regions
    }
}
