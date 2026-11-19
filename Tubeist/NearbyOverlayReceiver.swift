@preconcurrency import CoreBluetooth
import CryptoKit
import SwiftUI

struct NearbyOverlayPairing {
    enum Result: Equatable {
        case accepted, wrongCode, occupied
    }

    private(set) var code: String
    private(set) var authorizedCentral: UUID?
    private var failedAttempts = 0

    init(code: String = String(Int.random(in: 100_000...999_999))) {
        self.code = code
    }

    mutating func renew() {
        let previousCode = code
        repeat { self = Self() } while code == previousCode
    }

    mutating func authorize(_ central: UUID, code suppliedCode: Data) -> Result {
        guard suppliedCode == Data(code.utf8) else {
            if authorizedCentral == nil {
                failedAttempts += 1
                if failedAttempts >= 8 { renew() }
            }
            return .wrongCode
        }
        guard authorizedCentral == nil || authorizedCentral == central else { return .occupied }
        authorizedCentral = central
        failedAttempts = 0
        return .accepted
    }
}

@MainActor @Observable
final class NearbyOverlayReceiver: NSObject, @preconcurrency CBPeripheralManagerDelegate {
    private static let serviceID = CBUUID(string: NearbyOverlayWire.service)
    private static let inputID = CBUUID(string: NearbyOverlayWire.input)

    private var pairing: NearbyOverlayPairing?
    var code: String? { pairing?.code }
    var hasPairedSender: Bool { pairing?.authorizedCentral != nil }
    private(set) var status = "Start receiving to pair an overlay app."
    private(set) var isServicePublished = false
    private(set) var document: NearbyOverlayDocument?
    private(set) var update: String?

    @ObservationIgnored private var bluetooth: CBPeripheralManager?
    @ObservationIgnored private var packageDigest: Data?
    @ObservationIgnored private var assembler = NearbyOverlayWire.Assembler()

    func start() {
        guard code == nil else { return }
        pairing = NearbyOverlayPairing()
        status = "Starting Bluetooth…"
        if let bluetooth {
            peripheralManagerDidUpdateState(bluetooth)
        } else {
            bluetooth = CBPeripheralManager(delegate: self, queue: .main)
        }
    }

    func stop() {
        pairing = nil
        isServicePublished = false
        assembler = .init()
        bluetooth?.stopAdvertising()
        bluetooth?.removeAllServices()
        status = "Receiving stopped."
    }

    func removeOverlay() {
        document = nil
        update = nil
        packageDigest = nil
        // A fresh pairing is required so no further updates are accepted for a removed overlay.
        if code != nil { stop() }
    }

    func renewPairing() {
        guard pairing != nil else { return }
        pairing?.renew()
        assembler = .init()
        status = "Enter the new code on the overlay device."
    }

    func refreshDiscovery() {
        guard let bluetooth, bluetooth.state == .poweredOn, isServicePublished, !hasPairedSender else { return }
        advertise(on: bluetooth)
    }

    private func advertise(on bluetooth: CBPeripheralManager) {
        status = hasPairedSender ? "Waiting for the paired scorer to reconnect…" : "Refreshing Bluetooth discovery…"
        if bluetooth.isAdvertising { bluetooth.stopAdvertising() }
        bluetooth.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceID],
            CBAdvertisementDataLocalNameKey: "Tubeist"
        ])
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard code != nil else { return }
        if peripheral.state != .poweredOn { isServicePublished = false }
        switch peripheral.state {
        case .poweredOn:
            guard !isServicePublished else { return }
            let input = CBMutableCharacteristic(
                type: Self.inputID,
                properties: [.write],
                value: nil,
                permissions: [.writeable, .writeEncryptionRequired]
            )
            let service = CBMutableService(type: Self.serviceID, primary: true)
            service.characteristics = [input]
            peripheral.add(service)
        case .poweredOff: status = "Turn on Bluetooth to receive overlays."
        case .unauthorized: status = "Allow Bluetooth for Tubeist in iOS Settings."
        case .unsupported: status = "Bluetooth LE is unavailable on this device."
        default: status = "Starting Bluetooth…"
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard code != nil, service.uuid == Self.serviceID else { return }
        if let error {
            status = "Could not start receiving. Try again."
            LOG("Nearby overlay service could not start: \(error.localizedDescription)", level: .warning)
        } else {
            isServicePublished = true
            advertise(on: peripheral)
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard code != nil else { return }
        if let error {
            status = "Could not advertise. Try again."
            LOG("Nearby overlay advertisement failed: \(error.localizedDescription)", level: .warning)
        } else if !hasPairedSender {
            status = "Enter this code on the overlay device."
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let request = requests.first else { return }
        let result: CBATTError.Code
        if requests.count == 1, request.offset == 0, request.characteristic.uuid == Self.inputID,
           let bytes = request.value, pairing != nil {
            result = receive(bytes, from: request.central)
        } else {
            result = .writeNotPermitted
        }
        peripheral.respond(to: request, withResult: result)
    }

    private func receive(_ bytes: Data, from central: CBCentral) -> CBATTError.Code {
        if bytes.first == NearbyOverlayWire.Kind.pair.rawValue {
            var pairingFrame = NearbyOverlayWire.Assembler()
            guard let frame = try? pairingFrame.receive(bytes),
                  let result = pairing?.authorize(central.identifier, code: frame.payload) else {
                return .insufficientAuthorization
            }
            switch result {
            case .wrongCode:
                return .insufficientAuthorization
            case .occupied:
                status = "Another overlay sender is paired. Use New pairing code to switch."
                return .insufficientAuthorization
            case .accepted:
                assembler = .init()
                bluetooth?.setDesiredConnectionLatency(.low, for: central)
                status = "Paired. Waiting for the overlay…"
                return .success
            }
        }

        guard pairing?.authorizedCentral == central.identifier else { return .insufficientAuthorization }
        do {
            if let frame = try assembler.receive(bytes) {
                return try accept(frame)
            }
            return .success
        } catch {
            assembler = .init()
            LOG("Rejected an invalid nearby overlay message", level: .warning)
            return .invalidAttributeValueLength
        }
    }

    private func accept(_ frame: NearbyOverlayWire.Frame) throws -> CBATTError.Code {
        switch frame.kind {
        case .pair:
            return .insufficientAuthorization
        case .checkPackage:
            return document != nil && frame.payload == packageDigest ? .success : .attributeNotFound
        case .package:
            let package = try JSONDecoder().decode(NearbyOverlayWire.Package.self, from: frame.payload)
            let installed = try NearbyOverlayDocument(package: package)
            update = nil
            document = installed
            packageDigest = Data(SHA256.hash(data: frame.payload))
            status = "Received \(installed.name). Waiting for live updates…"
            LOG("Received nearby overlay package (\(frame.payload.count) bytes)", level: .info)
        case .update:
            guard let document, let json = String(data: frame.payload, encoding: .utf8) else {
                return .invalidAttributeValueLength
            }
            _ = try JSONSerialization.jsonObject(with: frame.payload, options: .fragmentsAllowed)
            update = json
            status = "Latest update received for \(document.name)."
            LOG("Applied nearby overlay update (\(frame.payload.count) bytes)", level: .debug)
        }
        return .success
    }
}

struct NearbyOverlayPanel: View {
    let receiver: NearbyOverlayReceiver
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("Bluetooth") {
                    Text(receiver.status)
                        .accessibilityIdentifier("nearby-overlay-status")
                    if let code = receiver.code {
                        LabeledContent("Pairing code") {
                            Text(code)
                                .monospacedDigit()
                                .textSelection(.enabled)
                                .accessibilityIdentifier("nearby-overlay-code")
                        }
                        if receiver.hasPairedSender {
                            Button("New pairing code") { receiver.renewPairing() }
                        } else if receiver.isServicePublished {
                            Button("Refresh discovery") { receiver.refreshDiscovery() }
                        }
                        Button("Stop receiving") { receiver.stop() }
                    } else {
                        Button("Start receiving") { receiver.start() }
                    }
                }
                if let document = receiver.document {
                    Section("Overlay") {
                        Text(document.name)
                        Button("Remove overlay", role: .destructive) { receiver.removeOverlay() }
                    }
                }
            }
            .navigationTitle("Nearby Overlay")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { receiver.refreshDiscovery() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { receiver.refreshDiscovery() }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
