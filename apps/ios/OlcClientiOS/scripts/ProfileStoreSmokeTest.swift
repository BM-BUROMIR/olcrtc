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
        {"id":"managed-telemost","name":"Managed Telemost","bootstrap":{"url":"https://example.invalid/bootstrap/device/telemost.olcb","client_key":"\(String(repeating: "d", count: 64))"}}
        """
        let managed = try reloaded.addManagedProfileFromJSON(json: managedJSON)
        check(managed.bootstrap?.url.contains("example.invalid") == true, "managed descriptor should import")
        let managedReload = ProfileStore(defaults: defaults, builtInProfiles: [telemost, wb])
        check(managedReload.profiles.first { $0.id == managed.id }?.bootstrap == managed.bootstrap, "managed descriptor should persist")

        managedReload.deleteProfile(id: custom.id)
        check(!managedReload.profiles.contains { $0.id == custom.id }, "custom profile should delete")

        print("ProfileStoreSmokeTest passed")
    }
}
