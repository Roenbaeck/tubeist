import Foundation

struct YouTubeViewerResource: Decodable, Sendable {
    let id: String
    let liveStreamingDetails: Details?
    struct Details: Decodable, Sendable {
        let concurrentViewers: Int?
        enum CodingKeys: CodingKey { case concurrentViewers }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let number = (try? values.decode(Int.self, forKey: .concurrentViewers))
                ?? (try? values.decode(String.self, forKey: .concurrentViewers)).flatMap(Int.init)
            concurrentViewers = number.flatMap { $0 >= 0 ? $0 : nil }
        }
    }
}
