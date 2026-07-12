import Foundation

extension Data {
    init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count % 2 == 0 else { return nil }
        var decoded = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            decoded.append(byte)
            index = next
        }
        self = decoded
    }
}

struct BootstrapDescriptor: Codable, Equatable {
    let url: String
    let client_key: String
}

enum BootstrapValidationError: Error {
    case unsupportedSchema
    case profileMismatch
    case invalidGeneration
    case replayedGeneration
    case invalidLifetime
    case expired
    case invalidSubscription
}

struct BootstrapEnvelope: Codable, Equatable {
    let schema_version: Int
    let profile_id: String
    let generation: Int
    let issued_at: Date
    let expires_at: Date
    let subscription: Subscription

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func validate(profileID: String, now: Date = Date(), minimumGeneration: Int?) throws {
        guard schema_version == 1 else { throw BootstrapValidationError.unsupportedSchema }
        guard profile_id == profileID else { throw BootstrapValidationError.profileMismatch }
        guard generation > 0 else { throw BootstrapValidationError.invalidGeneration }
        if let minimumGeneration, generation <= minimumGeneration {
            throw BootstrapValidationError.replayedGeneration
        }
        guard expires_at > issued_at else { throw BootstrapValidationError.invalidLifetime }
        guard expires_at > now else { throw BootstrapValidationError.expired }
        let key = subscription.crypto_key
        let isHex64 = key.count == 64 && key.allSatisfy { $0.isHexDigit }
        guard !subscription.carrier.isEmpty,
              !subscription.room.isEmpty,
              !subscription.channel.isEmpty,
              isHex64 else {
            throw BootstrapValidationError.invalidSubscription
        }
    }
}

struct BootstrapCache {
    let directory: URL

    private func file(profileID: String) throws -> URL {
        let valid = !profileID.isEmpty && profileID.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        guard valid else { throw BootstrapValidationError.profileMismatch }
        return directory.appendingPathComponent("\(profileID).json")
    }

    func load(profileID: String) throws -> BootstrapEnvelope? {
        let url = try file(profileID: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try BootstrapEnvelope.decoder().decode(BootstrapEnvelope.self, from: Data(contentsOf: url))
    }

    func save(_ envelope: BootstrapEnvelope) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try BootstrapEnvelope.encoder().encode(envelope)
        try data.write(to: try file(profileID: envelope.profile_id), options: [.atomic, .completeFileProtection])
    }
}
