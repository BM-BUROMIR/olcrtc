import CryptoKit
import Foundation

enum BootstrapResolverError: Error {
    case invalidURL
    case invalidBlob
    case invalidKey
    case staleGeneration
    case noUsableConfiguration
}

struct BootstrapResolver {
    static let magic = Data("OLCB1".utf8)
    let cache: BootstrapCache
    var fetch: (URL) async throws -> Data = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func decrypt(_ blob: Data, keyHex: String) throws -> BootstrapEnvelope {
        guard blob.count > 33, blob.prefix(5) == magic else { throw BootstrapResolverError.invalidBlob }
        guard let key = Data(hexString: keyHex), key.count == 32 else { throw BootstrapResolverError.invalidKey }
        let nonce = blob.subdata(in: 5..<17)
        let body = blob.subdata(in: 17..<blob.count)
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: body.prefix(body.count - 16),
            tag: body.suffix(16)
        )
        let clear = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: magic)
        return try BootstrapEnvelope.decoder().decode(BootstrapEnvelope.self, from: clear)
    }

    func resolve(descriptor: BootstrapDescriptor, profileID: String, now: Date = Date()) async throws -> BootstrapEnvelope {
        let cached = try? cache.load(profileID: profileID)
        do {
            guard let url = URL(string: descriptor.url) else { throw BootstrapResolverError.invalidURL }
            let envelope = try Self.decrypt(try await fetch(url), keyHex: descriptor.client_key)
            try envelope.validate(profileID: profileID, now: now, minimumGeneration: nil)
            if let cached, envelope.generation < cached.generation {
                throw BootstrapResolverError.staleGeneration
            }
            try cache.save(envelope)
            return envelope
        } catch {
            if let cached {
                try cached.validate(profileID: profileID, now: now, minimumGeneration: nil)
                return cached
            }
            throw BootstrapResolverError.noUsableConfiguration
        }
    }
}
