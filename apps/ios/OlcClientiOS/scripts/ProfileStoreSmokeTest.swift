import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ProfileStoreSmokeTest {
    static func main() throws {
        let telemost = VPNProfile(
            id: "telemost",
            name: "Telemost",
            subscription: Subscription(
                carrier: "telemost",
                room: "https://example.invalid/room/test",
                channel: "tmtest",
                crypto_key: String(repeating: "a", count: 64),
                transport: "vp8channel"
            ),
            isBuiltIn: true
        )

        let wb = VPNProfile(
            id: "wb",
            name: "WB",
            subscription: Subscription(
                carrier: "wbstream",
                room: "wb-room",
                channel: "wbtest",
                crypto_key: String(repeating: "b", count: 64),
                transport: "vp8channel"
            ),
            isBuiltIn: true
        )

        let suiteName = "com.oxi717.olc.profile-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProfileStore(defaults: defaults, builtInProfiles: [telemost, wb])
        check(store.profiles.map(\.id) == ["telemost", "wb"], "built-in profiles should be available in order")
        check(store.selectedProfile?.id == "telemost", "first built-in profile should be selected by default")

        store.selectProfile(id: "wb")
        check(store.selectedProfile?.id == "wb", "selected profile should update")

        let customJSON = """
        {"carrier":"telemost","room":"https://example.invalid/room/custom","channel":"custom","crypto_key":"\(String(repeating: "c", count: 64))","transport":"vp8channel"}
        """
        let custom = try store.addProfileFromJSON(name: "Custom", json: customJSON)
        check(custom.isBuiltIn == false, "imported profile should be custom")
        check(store.profiles.contains { $0.id == custom.id }, "custom profile should be present")
        check(store.selectedProfile?.id == custom.id, "imported profile should become selected")

        let reloaded = ProfileStore(defaults: defaults, builtInProfiles: [telemost, wb])
        check(reloaded.selectedProfile?.id == custom.id, "selection should persist")
        check(reloaded.profiles.contains { $0.name == "Custom" }, "custom profile should persist")

        let managedJSON = """
        {"id":"telemost","name":"Managed Telemost","bootstrap":{"url":"https://example.invalid/bootstrap/device/telemost.olcb","client_key":"\(String(repeating: "d", count: 64))"}}
        """
        let managed = try reloaded.addManagedProfileFromJSON(json: managedJSON)
        check(managed.bootstrap?.url.contains("example.invalid") == true, "managed descriptor should import")
        let managedReload = ProfileStore(defaults: defaults, builtInProfiles: [telemost, wb])
        check(managedReload.profiles.first { $0.id == managed.id }?.bootstrap == managed.bootstrap, "managed descriptor should persist")
        check(managedReload.profiles.filter { $0.id == "telemost" }.count == 1, "managed enrollment should replace template")

        let universalSuiteName = "com.oxi717.olc.profile-universal-smoke-\(UUID().uuidString)"
        let universalDefaults = UserDefaults(suiteName: universalSuiteName)!
        defer { universalDefaults.removePersistentDomain(forName: universalSuiteName) }
        let templates = [telemost, wb].map {
            VPNProfile(id: $0.id, name: $0.name, subscription: nil, bootstrap: nil, isBuiltIn: true)
        }
        let universal = ProfileStore(defaults: universalDefaults, builtInProfiles: templates)
        check(universal.selectedProfile?.isConfigured == false, "universal template should not be connectable before enrollment")
        let enrollmentJSON = """
        [
          {"id":"telemost","name":"Telemost","bootstrap":{"url":"https://example.invalid/bootstrap/second/telemost.olcb","client_key":"\(String(repeating: "e", count: 64))"}},
          {"id":"wb","name":"WB","bootstrap":{"url":"https://example.invalid/bootstrap/second/wb.olcb","client_key":"\(String(repeating: "e", count: 64))"}}
        ]
        """
        let enrolled = try universal.addManagedProfilesFromJSON(json: enrollmentJSON)
        check(enrolled.map(\.id) == ["telemost", "wb"], "batch enrollment should import both profiles")
        check(universal.profiles.allSatisfy { $0.bootstrap != nil }, "batch enrollment should replace universal templates")
        check(universal.selectedProfile?.isConfigured == true, "enrolled managed profile should be connectable")

        let rejectedSuiteName = "com.oxi717.olc.profile-rejected-smoke-\(UUID().uuidString)"
        let rejectedDefaults = UserDefaults(suiteName: rejectedSuiteName)!
        defer { rejectedDefaults.removePersistentDomain(forName: rejectedSuiteName) }
        let rejected = ProfileStore(defaults: rejectedDefaults, builtInProfiles: templates)
        let invalidEnrollmentJSON = """
        [
          {"id":"telemost","name":"Telemost","bootstrap":{"url":"https://example.invalid/bootstrap/bad/telemost.olcb","client_key":"\(String(repeating: "f", count: 64))"}},
          {"id":"wb","name":"WB","bootstrap":{"url":"https://example.invalid/bootstrap/bad/wb.olcb","client_key":"short"}}
        ]
        """
        do {
            _ = try rejected.addManagedProfilesFromJSON(json: invalidEnrollmentJSON)
            check(false, "invalid batch enrollment should fail")
        } catch {
            check(rejected.profiles.allSatisfy { $0.bootstrap == nil }, "failed batch enrollment should be atomic")
        }

        let relativeHTTPSEnrollmentJSON = """
        {"id":"telemost","name":"Telemost","bootstrap":{"url":"https:relative","client_key":"\(String(repeating: "f", count: 64))"}}
        """
        do {
            _ = try rejected.addManagedProfilesFromJSON(json: relativeHTTPSEnrollmentJSON)
            check(false, "managed enrollment without an HTTPS host should fail")
        } catch {
            check(rejected.profiles.allSatisfy { $0.bootstrap == nil }, "invalid URL must not persist enrollment")
        }

        let restored = rejected.restoreManagedProfile(
            id: "wb",
            name: "WB",
            bootstrap: BootstrapDescriptor(
                url: "https://example.invalid/bootstrap/owner/wb.olcb",
                client_key: String(repeating: "1", count: 64)
            )
        )
        check(restored, "existing VPN bootstrap should restore a universal profile")
        check(rejected.selectedProfile?.id == "wb", "restored VPN profile should become selected")

        let migrationSuiteName = "com.oxi717.olc.profile-migration-smoke-\(UUID().uuidString)"
        let migrationDefaults = UserDefaults(suiteName: migrationSuiteName)!
        defer { migrationDefaults.removePersistentDomain(forName: migrationSuiteName) }
        let migration = ProfileStore(defaults: migrationDefaults, builtInProfiles: templates)
        let recovered = migration.restoreManagedEnrollment(
            from: ManagedTunnelDescriptor(
                profileID: "telemost",
                bootstrap: BootstrapDescriptor(
                    url: "https://example.invalid/bootstrap/owner-device/telemost.olcb",
                    client_key: String(repeating: "2", count: 64)
                ),
                generation: 7
            )
        )
        check(recovered == ["telemost", "wb"], "active VPN descriptor should recover both managed profiles")
        check(migration.selectedProfile?.id == "telemost", "migration should preserve the active VPN profile")
        check(
            migration.profiles.first { $0.id == "wb" }?.bootstrap?.url ==
                "https://example.invalid/bootstrap/owner-device/wb.olcb",
            "sibling profile should keep the device path"
        )

        let unsafeSuiteName = "com.oxi717.olc.profile-unsafe-migration-smoke-\(UUID().uuidString)"
        let unsafeDefaults = UserDefaults(suiteName: unsafeSuiteName)!
        defer { unsafeDefaults.removePersistentDomain(forName: unsafeSuiteName) }
        let unsafeMigration = ProfileStore(defaults: unsafeDefaults, builtInProfiles: templates)
        let unsafeRecovered = unsafeMigration.restoreManagedEnrollment(
            from: ManagedTunnelDescriptor(
                profileID: "telemost",
                bootstrap: BootstrapDescriptor(
                    url: "https://example.invalid/unrelated/current.json",
                    client_key: String(repeating: "3", count: 64)
                ),
                generation: 7
            )
        )
        check(unsafeRecovered == ["telemost"], "non-contract URL should restore only the active profile")
        check(
            unsafeMigration.profiles.first { $0.id == "wb" }?.bootstrap == nil,
            "non-contract URL must not synthesize a sibling profile"
        )

        managedReload.deleteProfile(id: custom.id)
        check(!managedReload.profiles.contains { $0.id == custom.id }, "custom profile should delete")

        print("ProfileStoreSmokeTest passed")
    }
}
