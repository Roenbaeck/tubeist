//
//  MetalKernelTests.swift
//  TubeistTests
//

import Metal
import Testing
@testable import Tubeist

struct MetalKernelTests {
    @Test func appLibraryContainsEveryConfiguredKernel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try #require(device.makeDefaultLibrary())
        let configuredKernels =
            AVAILABLE_STYLES.filter { $0 != NO_STYLE } +
            AVAILABLE_EFFECTS.filter { $0 != NO_EFFECT } +
            ["imprint"]

        for configuredName in configuredKernels {
            let functionName = configuredName.lowercased()
            let function = try #require(
                library.makeFunction(name: functionName),
                "Missing Metal function '\(functionName)'"
            )
            _ = try device.makeComputePipelineState(function: function)
        }
    }
}
