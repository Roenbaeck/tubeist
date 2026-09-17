import Foundation

/// Device zoom is relative to that capture device's widest view. Display zoom
/// is relative to the main wide camera (for example 0.5x, 1x, or 5x).
struct CameraZoomState: Equatable, Sendable {
    var revision: UInt64 = 0
    var deviceID = ""
    var factor = 1.0
    var minimum = 1.0
    var maximum = 20.0
    var displayMultiplier = 1.0
    var activeLensBaseFactor = 1.0
    var upscaleThreshold = 1.0
    var secondaryNativeFactors: [Double] = []

    var displayedFactor: Double { factor * displayMultiplier }

    var label: String {
        let number = String(format: "%.1f", displayedFactor)
        return (number.hasSuffix(".0") ? String(number.dropLast(2)) : number) + "×"
    }

    var requiresUpscaling: Bool {
        let lensZoom = factor / activeLensBaseFactor
        // Secondary sensor readout modes are native at specific zoom factors;
        // they don't make the entire interval up to that factor optical.
        return lensZoom > upscaleThreshold + 0.0001 &&
            !secondaryNativeFactors.contains { abs($0 - lensZoom) <= 0.0001 }
    }

    func clamped(_ requested: Double) -> Double {
        guard requested.isFinite else { return factor }
        return max(minimum, min(requested, maximum))
    }

    static func displayScale(reported: Double, lensScale: Double?) -> Double {
        // Some standalone lenses report 1 even though the same physical lens
        // has a different magnification within a virtual multi-camera device.
        if reported.isFinite, reported > 0, abs(reported - 1) > 0.0001 { return reported }
        if let lensScale, lensScale.isFinite, lensScale > 0 { return lensScale }
        return 1
    }

    static func lensScale(nativeFactors: [Double], wideIndex: Int, selectedIndex: Int) -> Double? {
        guard nativeFactors.indices.contains(wideIndex), nativeFactors.indices.contains(selectedIndex),
              nativeFactors[wideIndex] > 0 else { return nil }
        let scale = nativeFactors[selectedIndex] / nativeFactors[wideIndex]
        return scale.isFinite && scale > 0 ? scale : nil
    }
}
