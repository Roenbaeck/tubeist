import AVFoundation

enum CaptureMedia: CaseIterable, Hashable, Sendable {
    case camera, microphone

    var mediaType: AVMediaType { self == .camera ? .video : .audio }
    var permissionError: CaptureSetupError {
        self == .camera ? .cameraPermissionDenied : .microphonePermissionDenied
    }
}

actor CapturePermissionRequester {
    static let shared = CapturePermissionRequester()
    private var pending: [CaptureMedia: Task<Bool, Never>] = [:]
    private let requestAccess: @Sendable (CaptureMedia) async -> Bool

    init(requestAccess: @escaping @Sendable (CaptureMedia) async -> Bool = {
        await AVCaptureDevice.requestAccess(for: $0.mediaType)
    }) {
        self.requestAccess = requestAccess
    }

    func request(_ media: CaptureMedia) async -> Bool {
        if let task = pending[media] { return await task.value }
        let task = Task { await requestAccess(media) }
        pending[media] = task
        let granted = await task.value
        pending[media] = nil
        return granted
    }
}

enum CaptureAuthorization {
    static func ensureAccess(
        status: @Sendable (CaptureMedia) -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: $0.mediaType)
        },
        request: @Sendable (CaptureMedia) async -> Bool = {
            await CapturePermissionRequester.shared.request($0)
        }
    ) async throws {
        for media in CaptureMedia.allCases {
            try Task.checkCancellation()
            switch status(media) {
            case .authorized:
                break
            case .notDetermined:
                let granted = await request(media)
                try Task.checkCancellation()
                guard granted else { throw media.permissionError }
            default:
                throw media.permissionError
            }
        }
    }
}
