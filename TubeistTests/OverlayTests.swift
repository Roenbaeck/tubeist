//
//  OverlayTests.swift
//  TubeistTests
//

import Testing
import UIKit
import CoreImage
@testable import Tubeist

struct OverlayTests {
    @Test(arguments: [
        "https://example.com/overlay",
        "http://127.0.0.1:8080/status",
    ])
    func acceptsWebOverlayURLs(_ value: String) {
        #expect(OverlayURLValidator.isAllowed(value))
    }

    @Test(arguments: [
        "javascript:alert(1)",
        "file:///private/test.html",
        "data:text/html,test",
        "https:///missing-host",
        "not a url",
    ])
    func rejectsNonWebOverlayURLs(_ value: String) {
        #expect(!OverlayURLValidator.isAllowed(value))
    }

    @MainActor
    @Test func savedOrderOverridesRegistrationOrderAndCanBeRearranged() async throws {
        let bundle = OverlayBundleActor()
        let bundler = OverlayBundler()
        let backURL = try #require(URL(string: "https://example.com/back"))
        let frontURL = try #require(URL(string: "https://example.com/front"))
        let back = Overlay(url: backURL, bundler: bundler)
        let front = Overlay(url: frontURL, bundler: bundler)

        // Deliberately register in the opposite order to the saved stack.
        await bundle.addOverlay(url: frontURL, overlay: front)
        await bundle.addOverlay(url: backURL, overlay: back)
        let initial = await bundle.getOverlays(in: [backURL, frontURL])
        #expect(initial == [back, front])

        // Existing instances are reused when the user rearranges the stack.
        let rearranged = await bundle.getOverlays(in: [frontURL, backURL])
        #expect(rearranged == [front, back])

        await bundle.removeOverlay(url: frontURL)
        let afterRemoval = await bundle.getOverlays(in: [frontURL, backURL])
        #expect(afterRemoval == [back])
    }

    @MainActor
    @Test func outputCompositeUsesTheSameBackToFrontOrderAsInput() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format)
        let red = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let blueRightHalf = renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 4, y: 0, width: 4, height: 8))
        }
        let combined = try #require(UIImage.composite(images: [red, blueRightHalf]))
        let reversed = try #require(UIImage.composite(images: [blueRightHalf, red]))

        func rgb(_ image: UIImage, x: Int) throws -> [UInt8] {
            let ciImage = try #require(CIImage(image: image))
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                CIContext().render(ciImage, toBitmap: $0.baseAddress!, rowBytes: 4,
                                   bounds: CGRect(x: CGFloat(x) * image.scale, y: 4 * image.scale,
                                                  width: 1, height: 1),
                                   format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
            }
            return Array(pixel.prefix(3))
        }
        #expect(try rgb(combined, x: 2) == [255, 0, 0])
        #expect(try rgb(combined, x: 6) == [0, 0, 255])
        #expect(try rgb(reversed, x: 6) == [255, 0, 0])
    }
}
