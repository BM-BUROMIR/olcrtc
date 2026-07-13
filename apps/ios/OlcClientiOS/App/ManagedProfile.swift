import Foundation

struct Subscription: Codable, Equatable {
    let carrier: String
    let room: String
    let channel: String
    let crypto_key: String
    var transport: String? = "vp8channel"

    func renderYAML() -> String {
        let dnsServer = carrier == "wbstream" ? "77.88.8.8:53" : "8.8.8.8:53"
        return """
        mode: cnc
        auth:
          provider: \(carrier)
        room:
          id: "\(room)"
          channel: "\(channel)"
        crypto:
          key: "\(crypto_key)"
        net:
          transport: \(transport ?? "vp8channel")
          dns: "\(dnsServer)"
        vp8:
          fps: 30
          batch_size: 8
          max_bytes_per_sec: 60000
        socks:
          host: "127.0.0.1"
          port: 1080
          max_sessions: 24
          slot_wait_ms: 500
          block_ports: [993, 5223]
          block_hosts: ["*.apple.com", "*.icloud.com", "*.cdn-apple.com"]
          block_cidrs: ["17.0.0.0/8"]
        data: "data"
        """
    }
}

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

    var isValid: Bool {
        guard Data(hexString: client_key)?.count == 32,
              let components = URLComponents(string: url),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        return true
    }

    func sibling(from sourceProfileID: String, to targetProfileID: String) -> BootstrapDescriptor? {
        let knownProfiles = Set(["telemost", "wb"])
        guard knownProfiles.contains(sourceProfileID),
              knownProfiles.contains(targetProfileID),
              sourceProfileID != targetProfileID,
              isValid,
              let source = URL(string: url),
              source.lastPathComponent == "\(sourceProfileID).olcb" else {
            return nil
        }
        let deviceDirectory = source.deletingLastPathComponent()
        guard !deviceDirectory.lastPathComponent.isEmpty else { return nil }
        return BootstrapDescriptor(
            url: deviceDirectory.appendingPathComponent("\(targetProfileID).olcb").absoluteString,
            client_key: client_key
        )
    }
}

struct ManagedTunnelDescriptor: Equatable {
    let profileID: String
    let bootstrap: BootstrapDescriptor
    let generation: Int

    private enum Key {
        static let profileID = "managed_profile_id"
        static let bootstrapURL = "managed_bootstrap_url"
        static let bootstrapKey = "managed_bootstrap_key"
        static let generation = "managed_generation"
    }

    init(profileID: String, bootstrap: BootstrapDescriptor, generation: Int) {
        self.profileID = profileID
        self.bootstrap = bootstrap
        self.generation = generation
    }

    init?(providerConfiguration: [String: Any]) {
        guard let profileID = providerConfiguration[Key.profileID] as? String,
              let url = providerConfiguration[Key.bootstrapURL] as? String,
              let clientKey = providerConfiguration[Key.bootstrapKey] as? String,
              let generation = providerConfiguration[Key.generation] as? Int,
              !profileID.isEmpty,
              generation > 0 else {
            return nil
        }
        let bootstrap = BootstrapDescriptor(url: url, client_key: clientKey)
        guard bootstrap.isValid else { return nil }
        self.init(
            profileID: profileID,
            bootstrap: bootstrap,
            generation: generation
        )
    }

    func add(to providerConfiguration: inout [String: Any]) {
        providerConfiguration[Key.profileID] = profileID
        providerConfiguration[Key.bootstrapURL] = bootstrap.url
        providerConfiguration[Key.bootstrapKey] = bootstrap.client_key
        providerConfiguration[Key.generation] = generation
    }
}

enum ManagedBootstrapDecision {
    static func shouldReconnect(activeGeneration: Int, candidateGeneration: Int) -> Bool {
        candidateGeneration > activeGeneration
    }
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
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        let options: Data.WritingOptions = .atomic
        #endif
        try data.write(to: try file(profileID: envelope.profile_id), options: options)
    }
}
