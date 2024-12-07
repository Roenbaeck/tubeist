import Foundation

struct Fragment {
    let sequence: Int
    let segment: Data
    let ext: String
    let duration: Double
}

private actor FragmentBufferActor {
    private var buffer: [Fragment] = []
    private let maxBufferSize: Int

    init(maxBufferSize: Int) {
        self.maxBufferSize = maxBufferSize
    }
    
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

actor NetworkPerformanceActor: NSObject, URLSessionDelegate {
    private var session: URLSession?
    override init() {
        super.init()
    }
    func setSession(_ session: URLSession) {
        self.session = session
    }
    func getSession() -> URLSession? {
        session
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        // Monitor upload progress
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        print("Upload progress: \(progress * 100)%")
    }
}

final class FragmentPusher: Sendable {
    public static let shared = FragmentPusher()
    private let uploadQueue: OperationQueue
    private let maxRetryAttempts = 30
    private let fragmentBuffer = FragmentBufferActor(maxBufferSize: 90)
    private let networkPerformance = NetworkPerformanceActor()

    init() {
        // For HTTP 1.1 persistent connections
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldUsePipelining = true
        // 10 second timeout
        configuration.timeoutIntervalForRequest = 10
        // Initialize upload queue with concurrent operations
        self.uploadQueue = OperationQueue()
        self.uploadQueue.maxConcurrentOperationCount = 3
        Task {
            await self.networkPerformance.setSession(
                URLSession(configuration: configuration, delegate: networkPerformance, delegateQueue: uploadQueue)
            )
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
                    
                    guard let fragment = await fragmentBuffer.removeFirst() else {
                        return
                    }
                                        
                    guard let request = self.createUploadRequest(fragment) else {
                        print("Failed to create upload request")
                        return
                    }
                    
                    guard let session = await self.networkPerformance.getSession() else {
                        print("Failed to get session")
                        return
                    }
                    
                    let task = session.dataTask(with: request) { [weak self] data, response, error in
                        guard let self = self else { return }
                        
                        print("Attempting [\(attempt)] to upload \(fragment.sequence).\(fragment.ext) with duration \(fragment.duration).")
                        
                        Task {
                            if let error = error {
                                print("Upload error: \(error.localizedDescription). Retrying...")
                                // Optionally retry a failed upload
                                if attempt < maxRetryAttempts {
                                    await fragmentBuffer.insertFirst(fragment)
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
                                    await fragmentBuffer.insertFirst(fragment)
                                    STREAMING_QUEUE.asyncAfter(deadline: .now() + 1.0) {
                                        self.uploadFragment(attempt: attempt + 1)
                                    }
                                }
                                return
                            }
                        }
                    }
                    task.resume()
                }
            }
        }
    }

    private func createUploadRequest(_ fragment: Fragment) -> URLRequest? {
        let url = URL(string: UserDefaults.standard.string(forKey: "HLSServer") ?? "")
        guard let url = url else {
            print("Invalid URL")
            return nil
        }

        var request = URLRequest(url: url.appendingPathComponent("upload_segment"))
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
        body.append("\((fragment.ext == "mp4") ? "true" : "false")\r\n")
        
        // Add `duration` field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"duration\"\r\n\r\n")
        body.append("\(fragment.duration)\r\n")
        
        // Add `sequence` field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"sequence\"\r\n\r\n")
        body.append("\(fragment.sequence)\r\n")
        
        // Add the file
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"segment\"; filename=\"segment_\(fragment.sequence).\(fragment.ext)\"\r\n")
        body.append("Content-Type: application/mp4\r\n\r\n")
        body.append(fragment.segment)
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


