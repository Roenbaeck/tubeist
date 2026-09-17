import Testing
@testable import Tubeist

struct CameraZoomTests {
    @Test func tripleCameraUsesMainWideAsOneTimesReference() {
        let factors = [1.0, 2.0, 10.0]
        #expect(CameraZoomState.lensScale(nativeFactors: factors, wideIndex: 1, selectedIndex: 0) == 0.5)
        #expect(CameraZoomState.lensScale(nativeFactors: factors, wideIndex: 1, selectedIndex: 1) == 1)
        #expect(CameraZoomState.lensScale(nativeFactors: factors, wideIndex: 1, selectedIndex: 2) == 5)
        var zoom = CameraZoomState(displayMultiplier: 0.5)
        #expect(zoom.label == "0.5×")
        zoom.factor = 2
        #expect(zoom.label == "1×")
        zoom.factor = 10
        #expect(zoom.label == "5×")
    }

    @Test(arguments: [2.0, 3.0, 5.0, 8.0])
    func physicalTelephotoKeepsItsNativeMagnification(_ lensScale: Double) {
        let scale = CameraZoomState.displayScale(reported: 1, lensScale: lensScale)
        let zoom = CameraZoomState(factor: 1, displayMultiplier: scale)
        #expect(zoom.displayedFactor == lensScale)
        #expect(!zoom.requiresUpscaling)
    }

    @Test func reportedDisplayMultiplierTakesPrecedenceAndInvalidMetadataIsSafe() {
        #expect(CameraZoomState.displayScale(reported: 0.5, lensScale: 1) == 0.5)
        #expect(CameraZoomState.displayScale(reported: 5, lensScale: 3) == 5)
        #expect(CameraZoomState.displayScale(reported: .nan, lensScale: nil) == 1)
        #expect(CameraZoomState.displayScale(reported: 1, lensScale: .infinity) == 1)
        #expect(CameraZoomState.lensScale(nativeFactors: [1], wideIndex: 1, selectedIndex: 0) == nil)
        #expect(CameraZoomState.lensScale(nativeFactors: [0, 2], wideIndex: 0, selectedIndex: 1) == nil)
    }

    @Test func telephotoTurnsYellowOnlyPastItsOwnUpscaleThreshold() {
        var zoom = CameraZoomState(displayMultiplier: 5)
        #expect(!zoom.requiresUpscaling) // Native telephoto is 5x, not digital 5x.
        zoom.factor = 1.2
        #expect(zoom.displayedFactor == 6)
        #expect(zoom.requiresUpscaling)
        zoom.upscaleThreshold = 1.5 // A lower-resolution format allows more cropping.
        #expect(!zoom.requiresUpscaling)
        zoom.factor = 1.51
        #expect(zoom.requiresUpscaling)
    }

    @Test func virtualCameraQualityFollowsTheActualLensIncludingFallback() {
        var zoom = CameraZoomState(factor: 10, displayMultiplier: 0.5, activeLensBaseFactor: 10)
        #expect(zoom.label == "5×")
        #expect(!zoom.requiresUpscaling) // Telephoto at its native field of view.
        zoom.activeLensBaseFactor = 2 // Low light/close focus falls back to wide.
        #expect(zoom.label == "5×")
        #expect(zoom.requiresUpscaling)
        zoom.factor = 2
        #expect(zoom.label == "1×")
        #expect(!zoom.requiresUpscaling)
    }

    @Test func secondaryNativeModesAreSpecificPointsNotAnOpticalRange() {
        var zoom = CameraZoomState(secondaryNativeFactors: [2, 4])
        #expect(!zoom.requiresUpscaling)
        zoom.factor = 1.5
        #expect(zoom.requiresUpscaling)
        zoom.factor = 2
        #expect(!zoom.requiresUpscaling)
        zoom.factor = 3
        #expect(zoom.requiresUpscaling)
        zoom.factor = 4
        #expect(!zoom.requiresUpscaling)
        zoom.factor = 4.01
        #expect(zoom.requiresUpscaling)
    }

    @Test func pinchLimitsRemainInDeviceUnitsWithoutChangingTheDisplayScale() {
        let zoom = CameraZoomState(factor: 2, minimum: 1, maximum: 4, displayMultiplier: 5)
        #expect(zoom.clamped(0.5) == 1)
        #expect(zoom.clamped(3) == 3)
        #expect(zoom.clamped(8) == 4)
        #expect(zoom.clamped(.nan) == 2)
        #expect(zoom.clamped(.infinity) == 2)
        #expect(zoom.factor == 2)
        #expect(zoom.displayedFactor == 10)
    }
}
