import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct BootstrapResolverSmokeTest {
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_783_852_800)
        let subscription = Subscription(
            carrier: "telemost",
            room: "https://example.invalid/room/current",
            channel: "field",
            crypto_key: String(repeating: "a", count: 64),
            transport: "vp8channel"
        )
        let current = BootstrapEnvelope(
            schema_version: 1,
            profile_id: "telemost",
            generation: 4,
            issued_at: now.addingTimeInterval(-60),
            expires_at: now.addingTimeInterval(3600),
            subscription: subscription
        )

        try current.validate(profileID: "telemost", now: now, minimumGeneration: 3)
        do {
            try current.validate(profileID: "wb", now: now, minimumGeneration: nil)
            require(false, "profile mismatch must fail")
        } catch BootstrapValidationError.profileMismatch {}
        do {
            try current.validate(profileID: "telemost", now: now.addingTimeInterval(7200), minimumGeneration: nil)
            require(false, "expired envelope must fail")
        } catch BootstrapValidationError.expired {}
        do {
            try current.validate(profileID: "telemost", now: now, minimumGeneration: 4)
            require(false, "replayed generation must fail")
        } catch BootstrapValidationError.replayedGeneration {}

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("olc-bootstrap-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BootstrapCache(directory: directory)
        try cache.save(current)
        let cachedCurrent = try cache.load(profileID: "telemost")
        let cachedOther = try cache.load(profileID: "wb")
        require(cachedCurrent == current, "cache round trip")
        require(cachedOther == nil, "cache must be profile isolated")
        require(
            !ManagedBootstrapDecision.shouldReconnect(activeGeneration: 4, candidateGeneration: 4),
            "same generation must not reconnect"
        )
        require(
            ManagedBootstrapDecision.shouldReconnect(activeGeneration: 4, candidateGeneration: 5),
            "new generation must reconnect"
        )
        let tunnelDescriptor = ManagedTunnelDescriptor(
            profileID: "telemost",
            bootstrap: BootstrapDescriptor(
                url: "https://example.invalid/profile",
                client_key: String(repeating: "b", count: 64)
            ),
            generation: 4
        )
        var providerConfiguration: [String: Any] = ["cnc_yaml": "test"]
        tunnelDescriptor.add(to: &providerConfiguration)
        require(
            ManagedTunnelDescriptor(providerConfiguration: providerConfiguration) == tunnelDescriptor,
            "provider configuration round trip"
        )

        let offline = BootstrapResolver(cache: cache, fetch: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await offline.resolve(
                descriptor: BootstrapDescriptor(url: "https://example.invalid/profile", client_key: String(repeating: "b", count: 64)),
                profileID: "telemost",
                minimumAcceptedGeneration: 5,
                now: now
            )
            require(false, "cache below configured generation must be rejected")
        } catch BootstrapResolverError.noUsableConfiguration {}

        print("BootstrapResolverSmokeTest passed")
    }
}
