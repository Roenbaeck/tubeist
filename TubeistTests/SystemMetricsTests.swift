//
//  SystemMetricsTests.swift
//  TubeistTests
//

import Testing
@preconcurrency import Darwin
@testable import Tubeist

@MainActor
struct SystemMetricsTests {
    @Test func streamHealthKeepsItsRulesWhenComputedApartFromTheMetrics() {
        func health(streaming: Bool = true, failed: Bool = false, capture: CaptureLiveness.State? = .healthy,
                    utilization: Int = 50, buffered: Int = 1, belowFloor: Bool = false,
                    current: StreamHealth = .awaiting) -> StreamHealth {
            SystemMetricsView.streamHealth(streaming: streaming, outputFailed: failed, captureState: capture,
                                           networkUtilization: utilization, bufferedFragments: buffered,
                                           belowQualityFloor: belowFloor, current: current)
        }
        #expect(health() == .pristine)
        #expect(health(failed: true) == .unusable)
        #expect(health(capture: .failed) == .unusable)
        #expect(health(capture: .recovering, utilization: 120) == .unusable)
        #expect(health(utilization: 100) == .degraded)
        #expect(health(buffered: 2) == .degraded)
        #expect(health(belowFloor: true) == .degraded)
        #expect(health(capture: .concealing) == .degraded)
        #expect(health(streaming: false, buffered: 0, current: .pristine) == .silenced)
        // A stopped stream still draining keeps its last health.
        #expect(health(streaming: false, buffered: 3, current: .degraded) == .degraded)
    }

    @Test func repeatedCPUSamplingReleasesCurrentThreadSendRights() throws {
        let sampler = SystemCPUSampler()
        let referencesBefore = try currentThreadSendReferences()

        for _ in 0..<500 {
            let usage = sampler.usage()
            #expect(usage.isFinite)
            #expect(usage >= 0)
        }

        let referencesAfter = try currentThreadSendReferences()
        #expect(referencesAfter <= referencesBefore + 1)
    }

    private func currentThreadSendReferences() throws -> mach_port_urefs_t {
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }

        var references: mach_port_urefs_t = 0
        let result = mach_port_get_refs(
            mach_task_self_,
            thread,
            mach_port_right_t(MACH_PORT_RIGHT_SEND),
            &references
        )
        guard result == KERN_SUCCESS else {
            throw SystemMetricsTestError.couldNotReadSendReferences(result)
        }
        return references
    }
}

private enum SystemMetricsTestError: Error {
    case couldNotReadSendReferences(kern_return_t)
}
