import Testing
@testable import Tubeist

struct HEVCFrameRecoveryTests {
    @Test func queuedDependentPicturesStayBlockedUntilAnActualKeyframe() throws {
        var recovery = HEVCFrameRecovery(maximumWaitingFrames: 60)
        #expect(try recovery.shouldEmit(isKeyframe: true))
        #expect(try recovery.shouldEmit(isKeyframe: false))
        try recovery.failed(-12911)
        for _ in 0..<8 {
            #expect(recovery.requiresKeyframe)
            #expect(try !recovery.shouldEmit(isKeyframe: false))
        }
        #expect(try recovery.shouldEmit(isKeyframe: true))
        #expect(!recovery.requiresKeyframe)
        #expect(try recovery.shouldEmit(isKeyframe: false))
    }

    @Test func aFailedInitialOrRecoveryKeyframeKeepsTheGateClosed() throws {
        var recovery = HEVCFrameRecovery(maximumWaitingFrames: 60)
        try recovery.failed(-12911)
        #expect(try !recovery.shouldEmit(isKeyframe: false))
        try recovery.failed(-12911)
        try recovery.discarded() // VideoToolbox may also drop a requested keyframe.
        #expect(recovery.requiresKeyframe)
        #expect(try !recovery.shouldEmit(isKeyframe: false))
        #expect(try recovery.shouldEmit(isKeyframe: true))
    }

    @Test func unusableDependentOutputDoesNotResetTheFailureLimit() throws {
        var recovery = HEVCFrameRecovery(maximumWaitingFrames: 60)
        for _ in 1..<HEVCFrameRecovery.maximumFailures {
            try recovery.failed(-12911)
            #expect(try !recovery.shouldEmit(isKeyframe: false))
        }
        #expect(throws: MediaEncodingError.self) { try recovery.failed(-12911) }
    }

    @Test func aConfirmedKeyframeResetsTheFailureBudget() throws {
        var recovery = HEVCFrameRecovery(maximumWaitingFrames: 60)
        for _ in 0..<10 {
            try recovery.failed(-12911)
            #expect(try recovery.shouldEmit(isKeyframe: true))
        }
    }

    @Test(arguments: [false, true])
    func ignoredKeyframeRequestsCannotDiscardVideoIndefinitely(dropped: Bool) throws {
        var recovery = HEVCFrameRecovery(maximumWaitingFrames: 3)
        try recovery.failed(-12911)
        for _ in 0..<2 {
            if dropped { try recovery.discarded() }
            else { #expect(try !recovery.shouldEmit(isKeyframe: false)) }
        }
        #expect(throws: MediaEncodingError.self) {
            if dropped { try recovery.discarded() }
            else { _ = try recovery.shouldEmit(isKeyframe: false) }
        }
    }
}
