import Foundation
import SystemConfiguration

struct Fragment {
    let sequence: Int
    let segment: Data
    let ext: String
    let duration: Double
    var discontinuity: Bool = false
}

actor FragmentBufferActor {
    private var buffer: [Fragment] = []
    private var attachedFragments: [Int : Fragment] = [:]  // fragments in flight
    private var fragment2Task: [Int : Int] = [:]
    private var task2Fragment: [Int : Int] = [:]
    private let maxBufferSize: Int
    
    init(maxBufferSize: Int) {
        self.maxBufferSize = maxBufferSize
    }
    
    func handleBounds() {
        if buffer.count > maxBufferSize {
            buffer.removeFirst()
            buffer[0].discontinuity = true
        }
    }
    
    func append(_ fragment: Fragment) {
        self.handleBounds()
        buffer.append(fragment)
    }
    
    func withdrawFragment() -> Fragment? {
        guard !buffer.isEmpty else { return nil }
        let fragment = buffer.removeFirst()
        return fragment
    }
    
    func returnFragment(_ fragment: Fragment) {
        self.handleBounds()
        buffer.insert(fragment, at: buffer.startIndex)
    }
        
    func attachFragment(to taskId: Int, with fragment: Fragment) {
        fragment2Task[fragment.sequence] = taskId
        task2Fragment[taskId] = fragment.sequence
        attachedFragments[taskId] = fragment
    }
    
    func detachFragment(forSequence sequence: Int) {
        guard let taskId = fragment2Task.removeValue(forKey: sequence),
              let _ = task2Fragment.removeValue(forKey: taskId),
              let fragment = attachedFragments.removeValue(forKey: taskId)
        else {
            LOG("Cannot detach fragment \(sequence) from its associated task", level: .error)
            return
        }
        self.returnFragment(fragment)
    }
    
    func detachFragment(forTask taskId: Int) {
        guard let fragment = attachedFragments.removeValue(forKey: taskId),
              let sequence = task2Fragment.removeValue(forKey: taskId),
              let _ = fragment2Task.removeValue(forKey: sequence)
        else {
            LOG("Cannot detach task \(taskId) from its associated fragment", level: .error)
            return
        }
        self.handleBounds()
        buffer.insert(fragment, at: buffer.startIndex)
    }
    
    func expelFragment(forTask taskId: Int) {
        guard let sequence = task2Fragment.removeValue(forKey: taskId) else {
            return
        }
        fragment2Task.removeValue(forKey: sequence)
        attachedFragments.removeValue(forKey: taskId)
    }

    func expelFragment(forSequence sequence: Int) {
        guard let taskId = fragment2Task.removeValue(forKey: sequence) else {
            return
        }
        task2Fragment.removeValue(forKey: taskId)
        attachedFragments.removeValue(forKey: taskId)
    }

    func expelAllFragments() {
        buffer.removeAll()
        attachedFragments.removeAll()
        task2Fragment.removeAll()
        fragment2Task.removeAll()
    }
    
    func isEmpty() -> Bool {
        buffer.isEmpty
    }
    
    func count() -> Int {
        buffer.count
    }
    
    func countAll() -> Int {
        buffer.count + attachedFragments.count
    }
}

actor URLSessionActor {
    private var session: URLSession?
    private var baseURL: URL?
    private var baseURLRequest: URLRequest?
    init(queue: OperationQueue, delegate: URLSessionDelegate) {
        // For HTTP 1.1 persistent connections without cookies and extra fluff
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.networkServiceType = .video
//        configuration.multipathServiceType = .aggregate // not working right now
        configuration.httpMaximumConnectionsPerHost = MAX_CONCURRENT_UPLOADS
        configuration.timeoutIntervalForRequest = TimeInterval(FRAGMENT_DURATION)
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        // initialize this with whatever the user has set, if anything is set
        baseURLRequest = URLSessionActor.createBaseUploadRequest()
    }
    func setSession(_ session: URLSession) {
        self.session = session
    }
    func getSession() -> URLSession? {
        session
    }
    func getBaseURLRequest() -> URLRequest? {
        baseURLRequest
    }
    func refresh() {
        baseURLRequest = URLSessionActor.createBaseUploadRequest()
    }
    private static func createBaseUploadRequest() -> URLRequest? {
        let hlsServer = UserDefaults.standard.string(forKey: "HLSServer") ?? ""
        if let url = URL(string: hlsServer) {
            var request = URLRequest(url: url.appendingPathComponent("upload_segment"))
            request.httpMethod = "POST"
//            request.assumesHTTP3Capable = true // too soon to use this since server side code is shaky
            
            // Add Basic Authentication header
            let username = UserDefaults.standard.string(forKey: "Username") ?? "brute"
            let password = UserDefaults.standard.string(forKey: "Password") ?? "force"
            
            let loginString = String(format: "%@:%@", username, password)
            let loginData = loginString.data(using: .utf8)!
            let base64LoginString = loginData.base64EncodedString()
            
            request.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            
            let streamKey = UserDefaults.standard.string(forKey: "StreamKey") ?? ""
            request.setValue(streamKey, forHTTPHeaderField: "Stream-Key")
            
            return request
        }
        else {
            LOG(hlsServer + " is not a valid URL", level: .error)
            return nil
        }
    }
}

struct NetworkMetric {
    var actualDuration: TimeInterval?
    var networkDuration: TimeInterval?
    var bytesSent: Int64?
    var timestamp: Date
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
    func removeStaleMetrics() {
        let now = Date()
        networkMetrics = networkMetrics.filter {
            now.timeIntervalSince($0.value.timestamp) <= NETWORK_METRICS_SLIDING_WINDOW
        }
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
                    metric.timestamp = metrics.taskInterval.end
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
    
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        LOG("Task is waiting for connectivity", level: .warning)
        Task {
            task.cancel()
            await FragmentPusher.shared.getFragmentBuffer().detachFragment(forTask: task.taskIdentifier)
        }
    }
    
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        if let error = error {
            LOG("URLSession became invalid with error: \(error.localizedDescription)", level: .error)
        }
    }
    
    // this is not called?
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            LOG("URLSession task \(task.taskIdentifier) failed with error: \(error.localizedDescription)", level: .error)
            Task {
                await FragmentPusher.shared.getFragmentBuffer().detachFragment(forTask: task.taskIdentifier)
            }
        }
        LOG("URLSession task \(task.taskIdentifier) completed successfully", level: .debug)
        Task {
            await FragmentPusher.shared.getFragmentBuffer().expelFragment(forTask: task.taskIdentifier)
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
            await self.netowrkMetrics.removeStaleMetrics()
            return (actualDuration, networkDuration, bitsSent)
        }.value
        
        guard totalActualDuration > 0, totalNetworkDuration > 0 else { return (0, 0) }
        
        let mbps = Int(Double(totalBitsSent) / (totalNetworkDuration * 1_000_000.0))
        let utilization = Int((totalNetworkDuration / totalActualDuration) * 100)
        return (mbps, utilization)
    }
    func removeAllMetrics() async {
        await netowrkMetrics.removeAllMetrics()
    }
}

final class FragmentPusher: Sendable {
    public static let shared = FragmentPusher()
    private let uploadQueue: OperationQueue
    private let maxRetryAttempts = MAX_UPLOAD_RETRIES
    private let fragmentBuffer = FragmentBufferActor(maxBufferSize: MAX_BUFFERED_FRAGMENTS)
    private let urlSession: URLSessionActor
    private let networkPerformance = NetworkPerformanceDelegate()

    init() {
        self.uploadQueue = OperationQueue()
        self.uploadQueue.maxConcurrentOperationCount = MAX_CONCURRENT_UPLOADS
        self.urlSession = URLSessionActor(queue: uploadQueue, delegate: networkPerformance)
        LOG("The FragmentPusher is initialized", level: .info)
    }
    
    func immediatePreparation() async {
        uploadQueue.cancelAllOperations()
        await urlSession.refresh()
        await fragmentBuffer.expelAllFragments()
        await networkPerformance.removeAllMetrics()
    }
    
    func gracefulShutdown() async {
        if await !fragmentBuffer.isEmpty() {
            if uploadQueue.operationCount == 0 {
                self.uploadFragment(attempt: 1)
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * FRAGMENT_DURATION))
                await gracefulShutdown()
            } catch {
                LOG("Graceful shutdown was interrupted: \(error)", level: .warning)
                return
            }
        }
    }

    func getFragmentBuffer() -> FragmentBufferActor {
        fragmentBuffer
    }
    
    func networkPerformance() async -> (mbps: Int, utilization: Int) {
        var (mbps, utilization) = await networkPerformance.networkPerformance()
        // We are not sending fast enough, so the buffer have started to fill up
        if await fragmentBuffer.count() > 1 {
            utilization = 100
        }
        return (mbps, utilization)
    }
    
    func fragmentBufferCount() async -> Int {
        await fragmentBuffer.count()
    }

    func addFragment(_ fragment: Fragment) {
        Task {
            await fragmentBuffer.append(fragment)
        }
    }
        
    func uploadFragment(attempt: Int) {
        Task {
            if await self.fragmentBuffer.isEmpty() {
                LOG("Upload called on an empty buffer", level: .warning)
                return // poor man's guard
            }
            
            // Inside the task block to avoid race conditions
            self.uploadQueue.addOperation { [self] in
                Task {
                    if await self.fragmentBuffer.isEmpty() {
                        LOG("Upload task abandoned due to an empty buffer", level: .warning)
                        return // poor man's guard
                    }
                    
                    guard let fragment = await fragmentBuffer.withdrawFragment() else {
                        LOG("Failed to remove fragment from buffer", level: .error)
                        return
                    }
                    
                    guard let request = await self.createUploadRequest(fragment) else {
                        LOG("Failed to create upload request", level: .error)
                        await fragmentBuffer.returnFragment(fragment) // reinsert fragment for another attempt
                        return
                    }
                    
                    guard let session = await self.urlSession.getSession() else {
                        LOG("Failed to get session", level: .error)
                        await fragmentBuffer.returnFragment(fragment) // reinsert fragment for another attempt
                        return
                    }
                                        
                    LOG("Preparing upload of \(fragment.sequence).\(fragment.ext)", level: .debug)
                    
                    let task = session.uploadTask(with: request, from: fragment.segment) { [weak self] data, response, error in
                        guard let self = self else { return }
                        LOG("Attempt [\(attempt)] to upload \(fragment.sequence).\(fragment.ext) with duration \(fragment.duration)s", level: .debug)
                        Task {
                            if let error = error {
                                LOG("Upload error: \(error.localizedDescription)", level: .error)
                                if attempt < maxRetryAttempts {
                                    await fragmentBuffer.detachFragment(forSequence: fragment.sequence) // fragment already attached to task here
                                    STREAMING_QUEUE_CONCURRENT.asyncAfter(deadline: .now() + 1.0) {
                                        self.uploadFragment(attempt: attempt + 1)
                                    }
                                }
                                else {
                                    await fragmentBuffer.expelFragment(forSequence: fragment.sequence)
                                }
                                return
                            }
                            if let httpResponse = response as? HTTPURLResponse,
                               !(200...299).contains(httpResponse.statusCode) {
                                if let data = data, let errorMessage = String(data: data, encoding: .utf8) {
                                    LOG("Server returned an error (\(httpResponse.statusCode)): \(errorMessage)", level: .error)
                                } else {
                                    LOG("Server returned an error: \(httpResponse.statusCode)", level: .error)
                                }
                                if attempt < maxRetryAttempts {
                                    await fragmentBuffer.detachFragment(forSequence: fragment.sequence) // fragment already attached to task here
                                    STREAMING_QUEUE_CONCURRENT.asyncAfter(deadline: .now() + 1.0) {
                                        self.uploadFragment(attempt: attempt + 1)
                                    }
                                }
                                else {
                                    await fragmentBuffer.expelFragment(forSequence: fragment.sequence)
                                }
                                return
                            }
                            // success
                            await fragmentBuffer.expelFragment(forSequence: fragment.sequence)
                        }
                    }
                    let metric = NetworkMetric(
                        actualDuration: fragment.duration,
                        networkDuration: nil,
                        bytesSent: nil,
                        timestamp: Date()
                    )
                    Task {
                        await fragmentBuffer.attachFragment(to: task.taskIdentifier, with: fragment)
                        await networkPerformance.setMetric(taskIdentifier: task.taskIdentifier, metric: metric)
                        task.resume()
                    }
                }
            }
        }
    }
    
    private func createUploadRequest(_ fragment: Fragment) async -> URLRequest? {
        guard var request = await self.urlSession.getBaseURLRequest() else {
            LOG("Unable to get base URLRequest object for upload", level: .error)
            return nil
        }
          // Add custom headers for metadata
        request.setValue((fragment.ext == "mp4") ? "true" : "false", forHTTPHeaderField: "Initialization")
        request.setValue(String(fragment.duration), forHTTPHeaderField: "Duration")
        request.setValue(String(fragment.sequence), forHTTPHeaderField: "Sequence")
        request.setValue(fragment.discontinuity ? "true" : "false", forHTTPHeaderField: "Discontinuity")
        return request
    }
}
