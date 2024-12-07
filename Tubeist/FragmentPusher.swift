import Foundation

struct Fragment {
    let sequence: Int
    let segment: Data
    let ext: String
    let duration: Double
}

private actor FragmentBufferActor {
    private var buffer: [Fragment] = []

    func append(_ fragment: Fragment) {
        buffer.append(fragment)
    }
    
    func insertFirst(_ fragment: Fragment) {
        buffer.insert(fragment, at: 0)
    }

    func removeFirst() -> Fragment? {
        guard !buffer.isEmpty else { return nil }
        return buffer.removeFirst()
    }

    func isEmpty() -> Bool {
        buffer.isEmpty
    }
    
    func release() {
        buffer.removeAll()
    }
}

private actor HLSServerActor {
    private var hlsServer = UserDefaults.standard.string(forKey: "HLSServer") ?? ""
    func getHLSServer() -> String {
        self.hlsServer
    }
    func setHLSServer(_ hlsServer: String) {
        self.hlsServer = hlsServer
    }
}

final class FragmentPusher: Sendable {
    public static let shared = FragmentPusher()
    private let uploadQueue: OperationQueue
    private let maxRetryAttempts = 30
    private let fragmentBuffer = FragmentBufferActor()
    private let hlsServer = HLSServerActor()

    init() {
        // Initialize upload queue with concurrent operations
        self.uploadQueue = OperationQueue()
        self.uploadQueue.maxConcurrentOperationCount = 3
    }
    
    func setHLSServer(_ hlsServer: String) {
        Task {
            await self.hlsServer.setHLSServer(hlsServer)
        }
    }
    
    func addFragment(_ fragment: Fragment) {
        Task {
            await fragmentBuffer.append(fragment)
        }
    }
    
    func uploadFragment(attempt: Int) {
        Task {
            if await self.fragmentBuffer.isEmpty() {
                return // poor man's guard
            }
            
            // Inside the task block to avoid race conditions
            self.uploadQueue.addOperation { [self] in
                Task {
                    if await self.fragmentBuffer.isEmpty() {
                        return // poor man's guard
                    }
                    
                    let bufferedfragment = await fragmentBuffer.removeFirst()
                    guard let bufferedfragment = bufferedfragment else {
                        return
                    }
                    
                    let sequence = bufferedfragment.sequence
                    let duration = bufferedfragment.duration
                    let ext = bufferedfragment.ext
                    let segment = bufferedfragment.segment
                    let isInit = ext == "mp4"
                    let hlsServer = await hlsServer.getHLSServer()
                    
                    guard let hlsServerURL = URL(string: hlsServer) else {
                        print("Invalid HLS server URL: ", hlsServer)
                        await fragmentBuffer.insertFirst(bufferedfragment)
                        return
                    }
                                        
                    let request = self.createUploadRequest(
                        url: hlsServerURL,
                        segment: segment,
                        duration: duration,
                        sequence: sequence,
                        isInit: isInit
                    )
                    
                    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                        guard let self = self else { return }
                        
                        print("Attempting [\(attempt)] to upload \(sequence).\(ext)")
                        
                        Task {
                            if let error = error {
                                print("Upload error: \(error.localizedDescription). Retrying...")
                                // Optionally retry a failed upload
                                if attempt < maxRetryAttempts {
                                    await fragmentBuffer.insertFirst(bufferedfragment)
                                    STREAMING_QUEUE.asyncAfter(deadline: .now() + 1.0) {
                                        self.uploadFragment(attempt: attempt + 1)
                                    }
                                }
                                return
                            }
                            
                            if let httpResponse = response as? HTTPURLResponse,
                               !(200...299).contains(httpResponse.statusCode) {
                                print("Server returned an error: \(httpResponse.statusCode). Retrying...")
                                if attempt < maxRetryAttempts {
                                    await fragmentBuffer.insertFirst(bufferedfragment)
                                    STREAMING_QUEUE.asyncAfter(deadline: .now() + 1.0) {
                                        self.uploadFragment(attempt: attempt + 1)
                                    }
                                }
                                return
                            }
                            
                            // Successful upload
                            print("Successfully uploaded \(sequence).\(ext) with duration \(duration)")
                        }
                    }
                    task.resume()
                }
            }
        }
    }

    private func createUploadRequest(url: URL, segment: Data, duration: Double, sequence: Int, isInit: Bool) -> URLRequest {
        var request = URLRequest(url: url.appendingPathComponent("upload_fragment"))
        request.httpMethod = "POST"
        
        // Boundary for multipart form data
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Add Basic Authentication header
        let username = UserDefaults.standard.string(forKey: "Username") ?? "brute"
        let password = UserDefaults.standard.string(forKey: "Password") ?? "force"

        let loginString = String(format: "%@:%@", username, password)
        let loginData = loginString.data(using: .utf8)!
        let base64LoginString = loginData.base64EncodedString()
        request.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
        
        // Create multipart form data
        var body = Data()
        
        // Add `is_init` field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"is_init\"\r\n\r\n")
        body.append("\(isInit ? "true" : "false")\r\n")
        
        // Add `duration` field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"duration\"\r\n\r\n")
        body.append("\(duration)\r\n")
        
        // Add `sequence` field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"sequence\"\r\n\r\n")
        body.append("\(sequence)\r\n")
        
        // Add the file
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"fragment\"; filename=\"fragment_\(sequence).mp4\"\r\n")
        body.append("Content-Type: application/mp4\r\n\r\n")
        body.append(segment)
        body.append("\r\n")
        
        // End of multipart data
        body.append("--\(boundary)--\r\n")
        
        request.httpBody = body
        return request
    }
}

// Helper method to append data to `Data`
private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
