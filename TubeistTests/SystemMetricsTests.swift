//
//  SystemMetricsTests.swift
//  TubeistTests
//

import Testing
@preconcurrency import Darwin
@testable import Tubeist

struct SystemMetricsTests {
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
