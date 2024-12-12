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
    func count() -> Int {
        buffer.count
    }
}

actor URLSessionActor {
    private var session: URLSession?
    func setSession(_ session: URLSession) {
        self.session = session
    }
    func getSession() -> URLSession? {
        session
    }
}

struct NetworkMetric {
    var actualDuration: TimeInterval?
    var networkDuration: TimeInterval?
    var bytesSent: Int64?
}

actor NetworkMetricsActor {
    private var networkMetrics: [Int: NetworkMetric] = [:]
    func setMetric(taskIdentifier: Int, metric: NetworkMetric) {
        self.networkMetrics[taskIdentifier] = metric
    }
    func getMetric(taskIdenfitier: Int) -> NetworkMetric? {
        networkMetrics[taskIdenfitier]
    }
    func getAllMetrics() -> [Int: NetworkMetric] {
        networkMetrics
    }
    func removeAllMetrics() {
        networkMetrics.removeAll()
    }
}

final class NetworkPerformanceDelegate: NSObject, URLSessionDelegate, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let netowrkMetrics = NetworkMetricsActor()
    private let queue = DispatchQueue(label: "com.tubeist.NetworkPerformanceQueue", attributes: .concurrent)
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        queue.async(flags: .barrier) {
            Task {
                if var metric = await self.netowrkMetrics.getMetric(taskIdenfitier: task.taskIdentifier) {
                    metric.networkDuration = metrics.taskInterval.duration
                    await self.setMetric(taskIdentifier: task.taskIdentifier, metric: metric)
                }
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        queue.async(flags: .barrier) {
            Task {
                if var metric = await self.netowrkMetrics.getMetric(taskIdenfitier: task.taskIdentifier) {
                    metric.bytesSent = bytesSent
                    await self.setMetric(taskIdentifier: task.taskIdentifier, metric: metric)
                }
            }
        }
    }
    
    func setMetric(taskIdentifier: Int, metric: NetworkMetric) async {
        await netowrkMetrics.setMetric(taskIdentifier: taskIdentifier, metric: metric)
    }
    
    func networkPerformance() async -> (mbps: Int, utilization: Int) {
        let totalActualDuration: TimeInterval
        let totalNetworkDuration: TimeInterval
        let totalBitsSent: Int64

        // Use a separate Task to perform the async operations
        (totalActualDuration, totalNetworkDuration, totalBitsSent) = await Task {
            var actualDuration: TimeInterval = 0
            var networkDuration: TimeInterval = 0
            var bitsSent: Int64 = 0
            let metrics = await self.netowrkMetrics.getAllMetrics()
            for (_, metric) in metrics {
                if let metricActualDuration = metric.actualDuration, let metricNetworkDuration = metric.networkDuration, let metricBytesSent = metric.bytesSent {
                    actualDuration += metricActualDuration
                    networkDuration += metricNetworkDuration
                    bitsSent += metricBytesSent * 8
                }
            }
            await self.netowrkMetrics.removeAllMetrics()
            return (actualDuration, networkDuration, bitsSent)
        }.value
        
        guard totalActualDuration > 0, totalNetworkDuration > 0 else { return (0, 0) }
        
        let mbps = Int(Double(totalBitsSent) / (totalNetworkDuration * 1_000_000.0))
        let utilization = Int((totalNetworkDuration / totalActualDuration) * 100)
        return (mbps, utilization)
    }
}

final class FragmentPusher: Sendable {
    public static let shared = FragmentPusher()
    private let uploadQueue: OperationQueue
    private let maxRetryAttempts = 30
    private let fragmentBuffer = FragmentBufferActor(maxBufferSize: 90)
    private let urlSession = URLSessionActor()
    private let networkPerformance = NetworkPerformanceDelegate()

    init() {
        // For HTTP 1.1 persistent connections
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldUsePipelining = true
        configuration.waitsForConnectivity = true
        // 10 second timeout
        configuration.timeoutIntervalForRequest = 10
        // Initialize upload queue with concurrent operations
        self.uploadQueue = OperationQueue()
        self.uploadQueue.maxConcurrentOperationCount = 3
        Task {
            await self.urlSession.setSession(
                URLSession(configuration: configuration, delegate: networkPerformance, delegateQueue: uploadQueue)
            )
        }
    }
    
    func networkPerformance() async -> (mbps: Int, utilization: Int) {
        var (mbps, utilization) = await networkPerformance.networkPerformance()
        // We are not sending fast enough, so the buffer have started to fill up
        if await fragmentBuffer.count() > 1 {
            utilization = 100
        }
        return (mbps, utilization)
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
                    
                    guard let session = await self.urlSession.getSession() else {
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
                                    STREAMING_QUEUE_CONCURRENT.asyncAfter(deadline: .now() + 1.0) {
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
                                    STREAMING_QUEUE_CONCURRENT.asyncAfter(deadline: .now() + 1.0) {
                                        self.uploadFragment(attempt: attempt + 1)
                                    }
                                }
                                return
                            }
                        }
                    }
                    Task {
                        let metric = NetworkMetric(
                            actualDuration: fragment.duration,
                            networkDuration: nil,
                            bytesSent: nil
                        )
                        await networkPerformance.setMetric(taskIdentifier: task.taskIdentifier, metric: metric)
                        task.resume()
                    }
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


