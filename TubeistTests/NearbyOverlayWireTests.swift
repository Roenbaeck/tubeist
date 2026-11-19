import Foundation
import Testing
@testable import Tubeist

struct NearbyOverlayWireTests {
    @Test func newPairingCodeReleasesStaleSenderAndRejectsThePreviousCode() {
        var pairing = NearbyOverlayPairing(code: "123456")
        let original = UUID()
        let other = UUID()
        let firstCode = Data(pairing.code.utf8)
        #expect(pairing.authorize(original, code: firstCode) == .accepted)
        #expect(pairing.authorize(original, code: firstCode) == .accepted)
        #expect(pairing.authorize(other, code: firstCode) == .occupied)

        pairing.renew()
        let newCode = Data(pairing.code.utf8)
        #expect(newCode != firstCode)
        #expect(pairing.authorizedCentral == nil)
        #expect(pairing.authorize(original, code: firstCode) == .wrongCode)
        #expect(pairing.authorize(other, code: newCode) == .accepted)
        #expect(pairing.authorizedCentral == other)
    }

    @Test(arguments: [20, 185, 244])
    func reassemblesAcknowledgedWrites(limit: Int) throws {
        let payload = Data((0..<1_024).map { UInt8(truncatingIfNeeded: $0) })
        let sent = NearbyOverlayWire.Frame(kind: .package, payload: payload)
        var receiver = NearbyOverlayWire.Assembler()
        var offset = 0
        var received: NearbyOverlayWire.Frame?
        repeat {
            let chunk = sent.chunk(from: offset, limit: limit)
            #expect(chunk.bytes.count <= limit)
            #expect(chunk.nextOffset > offset)
            offset = chunk.nextOffset
            received = try receiver.receive(chunk.bytes)
            if offset < payload.count { #expect(received == nil) }
        } while offset < payload.count
        #expect(received?.kind == .package)
        #expect(received?.payload == payload)
    }

    @Test func newTransferReplacesPartiallyReceivedData() throws {
        let previous = NearbyOverlayWire.Frame(kind: .package, payload: Data(repeating: 5, count: 64))
        let update = NearbyOverlayWire.Frame(kind: .update, payload: Data("7".utf8))
        var receiver = NearbyOverlayWire.Assembler()
        #expect(try receiver.receive(previous.chunk(from: 0, limit: 20).bytes) == nil)
        let received = try receiver.receive(update.chunk(from: 0, limit: 20).bytes)
        #expect(received?.kind == .update)
        #expect(received?.payload == Data("7".utf8))
    }

    @Test func rejectsOversizedHeadersAndStrayContinuations() {
        var receiver = NearbyOverlayWire.Assembler()
        #expect(throws: NearbyOverlayWire.FormatError.self) {
            try receiver.receive(Data([NearbyOverlayWire.Kind.update.rawValue, 0x01, 0x00, 0x00, 0x00]))
        }
        #expect(throws: NearbyOverlayWire.FormatError.self) {
            try receiver.receive(Data([0, 1]))
        }
    }

    @Test(arguments: ["../outside.html", "/absolute.html", "folder/../index.html", "folder//index.html"])
    func rejectsEscapingPackagePaths(path: String) {
        let package = NearbyOverlayWire.Package(name: "Test", entry: "index.html",
                                                files: ["index.html": Data(), path: Data()])
        #expect(throws: NearbyOverlayWire.FormatError.self) {
            try NearbyOverlayDocument(package: package)
        }
    }
}
