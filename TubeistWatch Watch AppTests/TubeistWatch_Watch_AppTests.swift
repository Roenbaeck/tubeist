import Foundation
import Testing
@testable import TubeistWatch_Watch_App

struct WatchStateTests {
    @Test func phonePayloadRoundTripsInWatchModuleAndExpiresOffline() throws {
        let now = Date()
        let original = WatchStateSnapshot(generatedAt: now, phase: .recording,
            startedAt: now.addingTimeInterval(-60), stoppedAt: now, externalStatusConfigured: true,
            externalStatus: try ExternalStatusSnapshot(text: "Stage 2 👩‍💻", receivedAt: now))
        let data = try PropertyListEncoder().encode(original)
        let received = try PropertyListDecoder().decode(WatchStateSnapshot.self, from: data)
        #expect(received == original)
        #expect(received.externalStatus?.isFresh(at: now.addingTimeInterval(31)) == false)
        #expect(received.isFresh(at: now.addingTimeInterval(91)) == false)
        #expect(received.stoppedAt == now)
    }

    @Test func uploadFailureTakesPriorityOverRemoteHealth() {
        let now = Date()
        let state = WatchStateSnapshot(generatedAt: now, phase: .streaming, health: .good,
            healthTracked: true, healthValidUntil: now.addingTimeInterval(120), link: .failed)
        #expect(state.healthIndicator(at: now) == .problem)
        #expect(state.healthIndicator(at: now.addingTimeInterval(91)) == .unknown)
    }
}
