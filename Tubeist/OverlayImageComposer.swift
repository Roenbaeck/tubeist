@preconcurrency import UIKit
import CoreImage

enum OverlayImageComposer {
    // Match UIKit/WebKit source-over blending in nonlinear, extended sRGB.
    // Let Core Image convert the final result to HLG during the GPU upload.
    private static let blendColorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    static func compose(_ images: [UIImage]) -> CIImage? {
        guard let first = images.first, var result = CIImage(image: first) else { return nil }
        let bounds = result.extent
        guard !bounds.isEmpty else { return nil }
        for image in images.dropFirst() {
            guard var layer = CIImage(image: image), !layer.extent.isEmpty else { return nil }
            layer = layer.transformed(by: CGAffineTransform(
                scaleX: bounds.width / layer.extent.width,
                y: bounds.height / layer.extent.height
            ))
            guard let blended = CIBlendKernel.sourceOver.apply(
                foreground: layer, background: result, colorSpace: blendColorSpace
            ) else { return nil }
            result = blended
        }
        // This is a lazy GPU recipe, with no full-size intermediate UIImage.
        // For one overlay it simply references the existing WebKit snapshot.
        return result.cropped(to: bounds)
    }
}
