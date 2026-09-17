import Testing
@testable import Tubeist

@PipelineActor
private final class AudioInputSessionStub: AudioInputSession {
    static let phone = AudioInput(id: "built-in-port", name: "iPhone Microphone")
    static let usb = AudioInput(id: "usb-port", name: "USB Lavalier")
    var availableInputs = [phone, usb]
    var activeInputs = [usb]
    var preferredInputID: String?
    var requests: [String?] = []
    var rejectsRequests = false
    var ignoresRequests = false
    var delaysRouteChanges = false

    func setPreferredInput(id: String?) throws {
        requests.append(id)
        if rejectsRequests { throw CaptureSetupError.audioSession("Test failure") }
        if ignoresRequests { return }
        preferredInputID = id
        if !delaysRouteChanges {
            activeInputs = id.map { id in availableInputs.filter { $0.id == id } }
                ?? Array(availableInputs.suffix(1))
        }
    }
}

@PipelineActor
struct AudioInputRoutingTests {
    private var phone: AudioInput { AudioInputSessionStub.phone }
    private var usb: AudioInput { AudioInputSessionStub.usb }

    @Test func automaticListsPhysicalPortsAndReportsTheActualRoute() {
        let session = AudioInputSessionStub()
        let router = AudioInputRouter(session: session)
        router.activate()
        #expect(router.snapshot.selected == nil)
        #expect(Set(router.snapshot.available.map(\.id)) == [phone.id, usb.id])
        #expect(router.snapshot.active == [usb])
        #expect(session.requests.isEmpty)
    }

    @Test func selectsBuiltInWhileUSBRemainsConnectedAndSavesThePortUID() throws {
        let session = AudioInputSessionStub()
        var saved: AudioInput?
        let router = AudioInputRouter(session: session, save: { saved = $0 })
        router.activate()
        try router.select(id: phone.id)
        #expect(session.requests == [phone.id])
        #expect(router.snapshot.active == [phone])
        #expect(router.snapshot.selected == phone)
        #expect(saved == phone)
        #expect(router.snapshot.available.contains(usb))
    }

    @Test func automaticClearsPreferenceAndFollowsSubsequentSystemChanges() throws {
        let session = AudioInputSessionStub()
        var saved: [AudioInput?] = []
        let router = AudioInputRouter(session: session, save: { saved.append($0) })
        router.activate()
        try router.select(id: phone.id)
        try router.select(id: nil)
        #expect(saved == [phone, nil])
        #expect(session.preferredInputID == nil)
        #expect(router.snapshot.selected == nil)
        session.availableInputs = [phone]
        session.activeInputs = [phone]
        router.refresh()
        session.availableInputs = [phone, usb]
        session.activeInputs = [usb]
        router.refresh()
        #expect(router.snapshot.active == [usb])
        #expect(session.requests == [phone.id, nil])
    }

    @Test func disconnectedSelectionFallsBackAndReturnsWhenReconnected() throws {
        let session = AudioInputSessionStub()
        let router = AudioInputRouter(session: session, selected: usb)
        router.activate()
        #expect(session.requests == [usb.id])
        session.availableInputs = [phone]
        // Model both iOS clearing the route and an old preferred port still
        // visible while the disconnect notification is delivered.
        session.activeInputs = [phone]
        router.refresh()
        #expect(session.preferredInputID == nil)
        #expect(router.snapshot.selected == usb)
        #expect(!router.snapshot.selectionIsAvailable)
        #expect(router.snapshot.active == [phone])
        #expect(router.snapshot.status.contains("disconnected"))
        session.availableInputs = [phone, usb]
        router.refresh()
        #expect(session.requests == [usb.id, nil, usb.id])
        #expect(router.snapshot.active == [usb])
        #expect(router.snapshot.selectionIsAvailable)
    }

    @Test func savedUnpluggedInputDoesNotPreventStartup() {
        let session = AudioInputSessionStub()
        session.availableInputs = [phone]
        session.activeInputs = [phone]
        let router = AudioInputRouter(session: session, selected: usb)
        router.activate()
        #expect(session.requests.isEmpty)
        #expect(router.snapshot.selected == usb)
        #expect(router.snapshot.active == [phone])
        session.availableInputs.append(usb)
        router.refresh()
        #expect(session.requests == [usb.id])
    }

    @Test func routeNotificationsDoNotContinuouslyReapplySelection() throws {
        let session = AudioInputSessionStub()
        let router = AudioInputRouter(session: session)
        router.activate()
        try router.select(id: phone.id)
        for _ in 0..<10 { router.refresh() }
        #expect(session.requests == [phone.id])
        // A new device can cause iOS to drop an earlier preference.
        session.preferredInputID = nil
        session.activeInputs = [usb]
        router.refresh()
        #expect(session.requests == [phone.id, phone.id])
        #expect(router.snapshot.active == [phone])
    }

    @Test func reportsCurrentRouteEvenWhenPreferenceHasNotTakenEffect() throws {
        let session = AudioInputSessionStub()
        session.delaysRouteChanges = true
        let router = AudioInputRouter(session: session)
        router.activate()
        try router.select(id: phone.id)
        #expect(router.snapshot.selected == phone)
        #expect(router.snapshot.active == [usb])
        session.activeInputs = [phone]
        router.refresh()
        #expect(router.snapshot.active == [phone])
        #expect(session.requests == [phone.id])
    }

    @Test func failedSelectionDoesNotReplaceTheSavedPreference() throws {
        let session = AudioInputSessionStub()
        var saved: [AudioInput?] = []
        let router = AudioInputRouter(session: session, save: { saved.append($0) })
        router.activate()
        try router.select(id: phone.id)
        session.rejectsRequests = true
        #expect(throws: CaptureSetupError.audioSession("Test failure")) {
            try router.select(id: usb.id)
        }
        #expect(router.snapshot.selected == phone)
        #expect(router.snapshot.active == [phone])
        #expect(saved == [phone])
    }

    @Test func unplugBetweenOpeningPickerAndSelectingIsRecoverable() {
        let session = AudioInputSessionStub()
        let router = AudioInputRouter(session: session)
        router.activate()
        session.availableInputs = [phone]
        session.activeInputs = [phone]
        #expect(throws: CaptureSetupError.noMicrophone) { try router.select(id: usb.id) }
        #expect(session.requests.isEmpty)
        #expect(router.snapshot.available == [phone])
        #expect(router.snapshot.selected == nil)
    }

    @Test func inactiveCaptureDoesNotReconfigureAudioInResponseToNotifications() {
        let session = AudioInputSessionStub()
        let router = AudioInputRouter(session: session, selected: phone)
        router.refresh()
        #expect(session.requests.isEmpty)
        router.activate()
        #expect(session.requests == [phone.id])
        router.suspend()
        session.preferredInputID = nil
        router.refresh()
        #expect(session.requests == [phone.id])
        #expect(throws: CaptureSetupError.audioOutputUnavailable) { try router.select(id: usb.id) }
        router.activate()
        #expect(session.requests == [phone.id, phone.id])
    }

    @Test(arguments: [false, true])
    func refusedRestorationDoesNotCauseANotificationLoop(throwsError: Bool) {
        let session = AudioInputSessionStub()
        session.rejectsRequests = throwsError
        session.ignoresRequests = !throwsError
        let router = AudioInputRouter(session: session, selected: phone)
        router.activate()
        for _ in 0..<10 { router.refresh() }
        #expect(session.requests == [phone.id])
        #expect(router.snapshot.selected == phone)
        #expect(router.snapshot.active == [usb])
        session.rejectsRequests = false
        session.ignoresRequests = false
        router.activate()
        #expect(session.requests == [phone.id, phone.id])
        #expect(router.snapshot.active == [phone])
    }

    @Test func duplicateNamesRemainDistinctAndRenamesKeepThePreference() throws {
        let session = AudioInputSessionStub()
        let other = AudioInput(id: "usb-port-2", name: usb.name)
        session.availableInputs.append(other)
        var saved: AudioInput?
        let router = AudioInputRouter(session: session, selected: usb, save: { saved = $0 })
        router.activate()
        #expect(router.snapshot.available.count == 3)
        #expect(router.snapshot.displayName(for: usb) != router.snapshot.displayName(for: other))
        let renamed = AudioInput(id: usb.id, name: "Renamed Lavalier")
        session.availableInputs = [phone, renamed, other]
        router.refresh()
        #expect(router.snapshot.selected == renamed)
        #expect(saved == renamed)
        #expect(session.requests == [usb.id])
    }
}
