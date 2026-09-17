import AVFoundation

struct AudioInput: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct AudioInputSnapshot: Equatable, Sendable {
    var available: [AudioInput] = []
    var selected: AudioInput?
    var active: [AudioInput] = []

    var selectionIsAvailable: Bool {
        selected == nil || available.contains { $0.id == selected?.id }
    }

    var status: String {
        let current = active.isEmpty ? "No active microphone" : "Using: \(active.map(\.name).joined(separator: ", "))"
        return selectionIsAvailable ? current : "Selected microphone disconnected. \(current)"
    }

    func displayName(for input: AudioInput) -> String {
        let sameName = available.filter { $0.name == input.name }.sorted { $0.id < $1.id }
        guard sameName.count > 1, let index = sameName.firstIndex(where: { $0.id == input.id }) else {
            return input.name
        }
        return "\(input.name) (\(index + 1))"
    }
}

extension Notification.Name {
    static let tubeistAudioInputsChanged = Notification.Name("TubeistAudioInputsChanged")
}

@PipelineActor
protocol AudioInputSession: AnyObject {
    var availableInputs: [AudioInput] { get }
    var activeInputs: [AudioInput] { get }
    var preferredInputID: String? { get }
    func setPreferredInput(id: String?) throws
}

@PipelineActor
private final class SystemAudioInputSession: AudioInputSession {
    private var session: AVAudioSession { .sharedInstance() }

    var availableInputs: [AudioInput] {
        (session.availableInputs ?? []).map { AudioInput(id: $0.uid, name: $0.portName) }
    }
    var activeInputs: [AudioInput] {
        session.currentRoute.inputs.map { AudioInput(id: $0.uid, name: $0.portName) }
    }
    var preferredInputID: String? { session.preferredInput?.uid }

    func setPreferredInput(id: String?) throws {
        guard let id else {
            try session.setPreferredInput(nil)
            return
        }
        guard let port = session.availableInputs?.first(where: { $0.uid == id }) else {
            throw CaptureSetupError.noMicrophone
        }
        try session.setPreferredInput(port)
    }
}

/// AVFoundation exposes one logical microphone on iOS. Choose its physical
/// source through the audio session, without rebuilding the camera session.
@PipelineActor
final class AudioInputRouter {
    static let shared = AudioInputRouter(
        session: SystemAudioInputSession(),
        selected: Settings.audioInputPortID.map {
            AudioInput(id: $0, name: Settings.audioInputPortName ?? "Selected microphone")
        },
        save: {
            Settings.audioInputPortID = $0?.id
            Settings.audioInputPortName = $0?.name
        },
        changed: {
            NotificationCenter.default.post(name: .tubeistAudioInputsChanged, object: nil)
        }
    )

    private let session: any AudioInputSession
    private let save: (AudioInput?) -> Void
    private let changed: () -> Void
    private var selected: AudioInput?
    private var isActive = false
    private var lastAttempt: RouteRequest?
    private(set) var snapshot = AudioInputSnapshot()

    private struct RouteRequest: Equatable {
        let inputID: String?
        let availableIDs: Set<String>
    }

    init(session: any AudioInputSession, selected: AudioInput? = nil,
         save: @escaping (AudioInput?) -> Void = { _ in },
         changed: @escaping () -> Void = {}) {
        self.session = session
        self.selected = selected
        self.save = save
        self.changed = changed
    }

    // Call only after setting category/mode and activating AVAudioSession.
    func activate() {
        isActive = true
        lastAttempt = nil
        refresh()
    }

    func suspend() { isActive = false }

    @discardableResult
    func refresh() -> AudioInputSnapshot {
        let available = session.availableInputs
        if let current = available.first(where: { $0.id == selected?.id }), current != selected {
            selected = current
            save(current)
        }
        if isActive {
            // Keep an unplugged preference, but let iOS supply a fallback until
            // it returns. Do not repeatedly request a route iOS cannot apply.
            let desired = available.first { $0.id == selected?.id }?.id
            let request = RouteRequest(inputID: desired, availableIDs: Set(available.map(\.id)))
            if session.preferredInputID == desired {
                lastAttempt = nil
            } else if lastAttempt != request {
                lastAttempt = request
                do {
                    try session.setPreferredInput(id: desired)
                } catch {
                    LOG("Could not restore microphone selection: \(error.localizedDescription)", level: .warning)
                }
            }
        }
        return publish()
    }

    func select(id: String?) throws {
        guard isActive else { throw CaptureSetupError.audioOutputUnavailable }
        let input: AudioInput?
        if let id {
            guard let available = session.availableInputs.first(where: { $0.id == id }) else {
                refresh()
                throw CaptureSetupError.noMicrophone
            }
            input = available
        } else {
            input = nil
        }
        // Save only successful requests. The snapshot reports currentRoute,
        // independently of the preference, since a route change can be delayed.
        do {
            try session.setPreferredInput(id: id)
        } catch {
            publish()
            throw error
        }
        selected = input
        save(input)
        lastAttempt = RouteRequest(inputID: id, availableIDs: Set(session.availableInputs.map(\.id)))
        publish()
    }

    @discardableResult
    private func publish() -> AudioInputSnapshot {
        let inputs = session.availableInputs.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }
        let next = AudioInputSnapshot(available: inputs, selected: selected, active: session.activeInputs)
        if next != snapshot {
            if next.available != snapshot.available, !next.available.isEmpty {
                LOG("Microphones: \(next.available.map(\.name))", level: .info)
            }
            if next.active != snapshot.active {
                LOG("Microphone route: \(next.active.map(\.name).joined(separator: ", "))", level: .debug)
            }
            snapshot = next
            changed()
        }
        return snapshot
    }
}
