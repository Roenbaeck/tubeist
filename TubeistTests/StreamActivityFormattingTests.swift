//
//  StreamActivityFormattingTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

struct StreamActivityFormattingTests {
    private func state(bitrateKbps: Int?) -> StreamActivityAttributes.ContentState {
        StreamActivityAttributes.ContentState(
            phase: .live,
            health: .good,
            isStale: false,
            warning: nil,
            viewers: nil,
            bitrateKbps: bitrateKbps,
            link: nil,
            thermal: nil,
            batteryPercent: nil
        )
    }

    @Test func megabitRatesKeepOneDecimal() {
        #expect(StreamActivityAttributes.ContentState.bitrateLabel(kbps: 6000) == "6.0 Mbps")
        #expect(StreamActivityAttributes.ContentState.bitrateLabel(kbps: 4500) == "4.5 Mbps")
        #expect(StreamActivityAttributes.ContentState.bitrateLabel(kbps: 1000) == "1.0 Mbps")
    }

    @Test func subMegabitRatesStayInKbps() {
        // Integer division used to render each of these as a stream-is-dead "0 Mbps".
        #expect(StreamActivityAttributes.ContentState.bitrateLabel(kbps: 999) == "999 kbps")
        #expect(StreamActivityAttributes.ContentState.bitrateLabel(kbps: 800) == "800 kbps")
        #expect(StreamActivityAttributes.ContentState.bitrateLabel(kbps: 0) == "0 kbps")
    }

    @Test func labelIsNilWhenBitrateIsUnknown() {
        #expect(state(bitrateKbps: nil).bitrateLabel == nil)
        #expect(state(bitrateKbps: 4500).bitrateLabel == "4.5 Mbps")
    }
}
