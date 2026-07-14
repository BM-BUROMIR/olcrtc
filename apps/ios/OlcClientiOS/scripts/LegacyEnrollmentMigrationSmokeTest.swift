import CryptoKit
import Foundation

@main
struct LegacyEnrollmentMigrationSmokeTest {
    // ai-generated: validates credential-bound legacy enrollment decryption and rejection.
    static func main() throws {
        let legacyYAML = "mode: cnc\ncrypto:\n  key: \"legacy-secret\"\n"
        let enrollment = """
        [{"id":"telemost","name":"Telemost","bootstrap":{"url":"https://example.invalid/device/telemost.olcb","client_key":"\(String(repeating: "a", count: 64))"}}]
        """
        let blob = try makeBlob(enrollment: Data(enrollment.utf8), legacyYAML: legacyYAML)

        let clear = try LegacyEnrollmentMigration.decrypt(blob, legacyYAML: legacyYAML)
        check(clear == enrollment, "matching legacy configuration should decrypt enrollment")

        do {
            _ = try LegacyEnrollmentMigration.decrypt(blob, legacyYAML: legacyYAML + "changed")
            check(false, "different legacy configuration must not decrypt enrollment")
        } catch {}

        do {
            _ = try LegacyEnrollmentMigration.decrypt(Data("invalid".utf8), legacyYAML: legacyYAML)
            check(false, "invalid migration blob must be rejected")
        } catch {}

        let resolved = LegacyEnrollmentMigration.resolve(
            blobs: [Data("invalid".utf8), blob],
            legacyYAML: legacyYAML
        )
        check(resolved == enrollment, "resolver should skip unrelated migration blobs")
        check(
            LegacyEnrollmentMigration.resolve(blobs: [blob], legacyYAML: "other") == nil,
            "resolver must not return enrollment for another legacy credential"
        )

        print("LegacyEnrollmentMigrationSmokeTest passed")
    }

    // ai-generated: creates a deterministic-format migration fixture for the smoke test.
    private static func makeBlob(enrollment: Data, legacyYAML: String) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 7, count: 12))
        let box = try AES.GCM.seal(
            enrollment,
            using: LegacyEnrollmentMigration.key(legacyYAML: legacyYAML),
            nonce: nonce,
            authenticating: LegacyEnrollmentMigration.magic
        )
        var blob = LegacyEnrollmentMigration.magic
        blob.append(contentsOf: nonce)
        blob.append(box.ciphertext)
        blob.append(box.tag)
        return blob
    }

    // ai-generated: reports a focused smoke-test assertion failure.
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
