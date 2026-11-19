import Foundation

/// Keep this wire format in sync with Tubeist Scorer. The update payload belongs to the web page.
enum NearbyOverlayWire {
    static let service = "84C68D03-123A-4601-8A1D-9275F6807001"
    static let input = "84C68D03-123A-4601-8A1D-9275F6807002"
    static let headerSize = 5
    // Render the same logical 16:9 viewport in the companion and in Tubeist.
    static let canvasWidth = 1280
    static let canvasHeight = 720

    enum Kind: UInt8 {
        case pair = 1
        case checkPackage = 2
        case package = 3
        case update = 4

        var maximumLength: Int {
            switch self {
            case .pair: 6
            case .checkPackage: 32
            case .package: 512 * 1024
            case .update: 32 * 1024
            }
        }
    }

    struct Package: Codable {
        let name: String
        let entry: String
        let files: [String: Data]
    }

    struct Frame {
        let kind: Kind
        let payload: Data

        func chunk(from offset: Int, limit: Int) -> (bytes: Data, nextOffset: Int) {
            var bytes: Data
            if offset == 0 {
                var length = UInt32(payload.count).bigEndian
                bytes = Data([kind.rawValue])
                withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            } else {
                bytes = Data([0])
            }
            let end = min(payload.count, offset + limit - bytes.count)
            bytes.append(payload[offset..<end])
            return (bytes, end)
        }
    }

    struct Assembler {
        private var pendingKind: Kind?
        private var expectedLength = 0
        private var payload = Data()

        mutating func receive(_ chunk: Data) throws -> Frame? {
            guard let tag = chunk.first else { throw FormatError.invalidChunk }
            if tag == 0 {
                guard pendingKind != nil else { throw FormatError.invalidChunk }
                payload.append(chunk.dropFirst())
            } else {
                guard let kind = Kind(rawValue: tag), chunk.count >= headerSize else {
                    throw FormatError.invalidChunk
                }
                let length = chunk.dropFirst().prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0, length <= kind.maximumLength else { throw FormatError.invalidChunk }
                pendingKind = kind
                expectedLength = length
                payload = Data(chunk.dropFirst(headerSize))
            }
            guard payload.count <= expectedLength else { throw FormatError.invalidChunk }
            guard payload.count == expectedLength, let kind = pendingKind else { return nil }
            let frame = Frame(kind: kind, payload: payload)
            self = Self()
            return frame
        }
    }

    enum FormatError: Error {
        case invalidChunk
    }
}
