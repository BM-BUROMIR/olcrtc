import CryptoKit
import Foundation

enum LegacyEnrollmentMigrationError: Error {
    case invalidBlob
    case invalidEnrollment
}

enum LegacyEnrollmentMigration {
    static let magic = Data("OLCM1".utf8)
    private static let context = Data("OLC legacy enrollment migration v1\0".utf8)

    // ai-generated: derives a migration key from the full legacy tunnel credential.
    static func key(legacyYAML: String) -> SymmetricKey {
        var material = context
        material.append(Data(legacyYAML.utf8))
        return SymmetricKey(data: SHA256.hash(data: material))
    }

    // ai-generated: decrypts an enrollment bound to one legacy tunnel configuration.
    static func decrypt(_ blob: Data, legacyYAML: String) throws -> String {
        guard blob.count > 33, blob.prefix(magic.count) == magic else {
            throw LegacyEnrollmentMigrationError.invalidBlob
        }
        let nonceStart = magic.count
        let bodyStart = nonceStart + 12
        let body = blob.subdata(in: bodyStart..<blob.count)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: blob.subdata(in: nonceStart..<bodyStart)),
            ciphertext: body.prefix(body.count - 16),
            tag: body.suffix(16)
        )
        let clear = try AES.GCM.open(
            box,
            using: key(legacyYAML: legacyYAML),
            authenticating: magic
        )
        guard let enrollment = String(data: clear, encoding: .utf8) else {
            throw LegacyEnrollmentMigrationError.invalidEnrollment
        }
        return enrollment
    }

    // ai-generated: finds the enrollment encrypted for the installed legacy credential.
    static func resolve(blobs: [Data], legacyYAML: String) -> String? {
        for blob in blobs {
            if let enrollment = try? decrypt(blob, legacyYAML: legacyYAML) {
                return enrollment
            }
        }
        return nil
    }

    // ai-generated: loads credential-bound migration resources from an application bundle.
    static func resolve(bundle: Bundle, legacyYAML: String) -> String? {
        let urls = (bundle.urls(forResourcesWithExtension: "olcm", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("LegacyEnrollment.") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return resolve(
            blobs: urls.compactMap { try? Data(contentsOf: $0) },
            legacyYAML: legacyYAML
        )
    }
}
