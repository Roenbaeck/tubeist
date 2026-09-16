import Testing
import UIKit
import CoreImage
@testable import Tubeist

struct OverlayCompositionTests {
    @MainActor
    @Test(arguments: [1, 2, 3])
    func gpuCompositionMatchesUIKitColorsAndTransparency(layerCount: Int) throws {
        let colors = [
            UIColor(displayP3Red: 1, green: 0, blue: 0, alpha: 0.6),
            UIColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 0.4),
            UIColor(white: 0.9, alpha: 0.3),
        ]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .extended
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format)
        let layers = colors.prefix(layerCount).enumerated().map { index, color in
            renderer.image { context in
                color.setFill()
                context.fill(CGRect(x: index * 2, y: 0, width: 8 - index * 2, height: 8))
            }
        }
        // The previous implementation redrew every snapshot through UIKit.
        let reference = renderer.image { _ in
            for layer in layers { layer.draw(in: CGRect(x: 0, y: 0, width: 8, height: 8)) }
        }
        let gpu = try #require(OverlayImageComposer.compose(layers))
        let legacy = try #require(CIImage(image: reference))
        let context = CIContext(options: [.workingColorSpace: CG_COLOR_SPACE])
        func pixels(_ image: CIImage) -> [Float] {
            var pixels = [Float](repeating: 0, count: 8 * 8 * 4)
            pixels.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: 8 * 4 * 4,
                               bounds: image.extent, format: .RGBAf, colorSpace: CG_COLOR_SPACE)
            }
            return pixels
        }
        let differences = zip(pixels(gpu), pixels(legacy)).map { abs($0 - $1) }
        #expect(try #require(differences.max()) < 0.006)
        #expect(gpu.extent == CGRect(x: 0, y: 0, width: 8, height: 8))
    }
}
