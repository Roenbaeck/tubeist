//
//  OverlayTests.swift
//  TubeistTests
//

import Testing
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
}
