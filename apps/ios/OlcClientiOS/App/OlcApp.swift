import SwiftUI
import NetworkExtension
import CryptoKit
import OlcMobile

@main
struct OlcApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

enum Sub {
    static let MAGIC = Data("OLCB1".utf8)

    static func decrypt(_ blob: Data, keyHex: String) throws -> Subscription {
        guard blob.count > 17, blob.prefix(5) == MAGIC else { throw err("не olc blob") }
        guard let key = Data(hexString: keyHex), key.count == 32 else { throw err("ключ hex64") }
        let nonce = blob.subdata(in: 5..<17), body = blob.subdata(in: 17..<blob.count)
        let ct = body.prefix(body.count - 16), tag = body.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: ct, tag: tag)
        let pt = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: MAGIC)
        return try JSONDecoder().decode(Subscription.self, from: pt)
    }

    static func fetch(_ url: String, keyHex: String) async throws -> Subscription {
        guard let u = URL(string: url) else { throw err("плохой URL") }
        let (data, _) = try await URLSession.shared.data(from: u)
        return try decrypt(data, keyHex: keyHex)
    }

    static func renderYAML(_ s: Subscription) -> String {
        let dnsServer = s.carrier == "wbstream" ? "77.88.8.8:53" : "8.8.8.8:53"
        return """
        mode: cnc
        auth:
          provider: \(s.carrier)
        room:
          id: "\(s.room)"
          channel: "\(s.channel)"
        crypto:
          key: "\(s.crypto_key)"
        net:
          transport: \(s.transport ?? "vp8channel")
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

    static func err(_ m: String) -> NSError { NSError(domain: "olc", code: -1, userInfo: [NSLocalizedDescriptionKey: m]) }
}

enum AppDiag {
    static func log(_ message: String) {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.oxi717.olc") else { return }
        let dir = base.appendingPathComponent("olc", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("app.log")
        guard let data = "\(Date()) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }
}

enum DirectDiag {
    private static let lock = NSLock()
    private static var running = false

    static func start(subscription: Subscription) {
        lock.lock()
        if running {
            lock.unlock()
            log("already running")
            return
        }
        running = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            run(subscription: subscription)
        }
    }

    private static func run(subscription: Subscription) {
        defer {
            lock.lock()
            running = false
            lock.unlock()
        }

        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.oxi717.olc") else {
            return
        }
        let dir = base.appendingPathComponent("olc-direct", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let port = freePort()
        let yaml = Sub.renderYAML(subscription)
            .replacingOccurrences(of: "port: 1080", with: "port: \(port)")

        log("start provider=\(subscription.carrier) transport=\(subscription.transport ?? "vp8channel") port=\(port) yaml_len=\(yaml.count)")

        let cncLog = dir.appendingPathComponent("cnc-stderr.log").path
        freopen(cncLog, "a+", stderr)
        freopen(cncLog, "a+", stdout)
        log("cnc stderr -> cnc-stderr.log")

        let done = DispatchSemaphore(value: 0)
        var runError: NSError?
        Thread.detachNewThread {
            let ok = OlcmobileStartCnc(yaml, dir.path, &runError)
            if let runError {
                log("cnc ended ok=\(ok) err=\(runError.localizedDescription)")
            } else {
                log("cnc ended ok=\(ok) clean")
            }
            done.signal()
        }

        var ready = false
        for i in 0..<80 {
            if canConnect(host: "127.0.0.1", port: port) {
                ready = true
                log("SOCKS ready @\(i * 500)ms")
                break
            }
            if done.wait(timeout: .now()) == .success {
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if !ready {
            log("SOCKS not ready")
        } else {
            runSocksHTTPProbes(port: port)
        }

        for second in 0..<150 {
            if done.wait(timeout: .now()) == .success {
                log("cnc exited before hold second=\(second)")
                return
            }
            if second % 10 == 0 {
                log("hold second=\(second)")
            }
            Thread.sleep(forTimeInterval: 1.0)
        }

        log("stopping after hold")
        OlcmobileStop()
        _ = done.wait(timeout: .now() + 10)
        log("stop complete")
    }

    private static func log(_ message: String) {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.oxi717.olc") else { return }
        let dir = base.appendingPathComponent("olc-direct", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ios-direct.log")
        guard let data = "\(Date()) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func canConnect(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func runSocksHTTPProbes(port: UInt16) {
        let stamp = Int(Date().timeIntervalSince1970)
        socksHTTPProbe(
            label: "ipify",
            port: port,
            host: "api.ipify.org",
            path: "/?format=text&cb=ios-\(stamp)",
            maxBytes: 64 * 1024
        )
        socksHTTPProbe(
            label: "cf1m",
            port: port,
            host: "speed.cloudflare.com",
            path: "/__down?bytes=1048576&cb=ios-\(stamp)",
            maxBytes: 2 * 1024 * 1024
        )
    }

    private static func socksHTTPProbe(label: String, port: UInt16, host: String, path: String, maxBytes: Int) {
        let started = Date()
        do {
            let result = try socksHTTPGet(port: port, host: host, path: path, maxBytes: maxBytes)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            log("probe \(label) status=\(result.status) bytes=\(result.bytes) elapsed_ms=\(elapsedMs) capped=\(result.capped)")
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            log("probe \(label) error=\(error.localizedDescription) elapsed_ms=\(elapsedMs)")
        }
    }

    private static func socksHTTPGet(port: UInt16, host: String, path: String, maxBytes: Int) throws -> (status: String, bytes: Int, capped: Bool) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { throw diagError("socket failed errno=\(errno)") }
        defer { close(fd) }
        setSocketTimeouts(fd, seconds: 20)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 { throw diagError("connect SOCKS failed errno=\(errno)") }

        try writeAll(fd, [0x05, 0x01, 0x00])
        let greeting = try readExact(fd, count: 2)
        if greeting != [0x05, 0x00] {
            throw diagError("SOCKS greeting rejected")
        }

        let hostBytes = Array(host.utf8)
        if hostBytes.count > 255 { throw diagError("SOCKS host too long") }
        var request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)]
        request += hostBytes
        request += [0x00, 0x50]
        try writeAll(fd, request)

        let head = try readExact(fd, count: 4)
        if head[0] != 0x05 || head[1] != 0x00 {
            throw diagError("SOCKS connect rejected rep=\(head[1])")
        }
        switch head[3] {
        case 0x01:
            _ = try readExact(fd, count: 6)
        case 0x03:
            let length = Int(try readExact(fd, count: 1)[0])
            _ = try readExact(fd, count: length + 2)
        case 0x04:
            _ = try readExact(fd, count: 18)
        default:
            throw diagError("SOCKS atyp=\(head[3])")
        }

        let http = "GET \(path) HTTP/1.1\r\n" +
            "Host: \(host)\r\n" +
            "User-Agent: OlcDirectDiag/1\r\n" +
            "Accept: */*\r\n" +
            "Connection: close\r\n\r\n"
        try writeAll(fd, Array(http.utf8))

        var total = 0
        var sample: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 8192)
        while total < maxBytes {
            let readLimit = min(buffer.count, maxBytes - total)
            let n = buffer.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress, readLimit, 0)
            }
            if n == 0 { break }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                throw diagError("recv failed errno=\(errno)")
            }
            if sample.count < 512 {
                sample += buffer.prefix(min(n, 512 - sample.count))
            }
            total += n
        }

        let firstLine = String(bytes: sample, encoding: .utf8)?
            .components(separatedBy: "\r\n")
            .first?
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(64) ?? "no-status"
        return (String(firstLine), total, total >= maxBytes)
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes {
                send(fd, $0.baseAddress?.advanced(by: written), bytes.count - written, 0)
            }
            if n <= 0 { throw diagError("send failed errno=\(errno)") }
            written += n
        }
    }

    private static func readExact(_ fd: Int32, count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = out.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress?.advanced(by: offset), count - offset, 0)
            }
            if n <= 0 { throw diagError("short read errno=\(errno)") }
            offset += n
        }
        return out
    }

    private static func setSocketTimeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func diagError(_ message: String) -> NSError {
        NSError(domain: "olc-direct-diag", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return 1080 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 { return 1080 }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        if got != 0 { return 1080 }
        return UInt16(bigEndian: addr.sin_port)
    }
}

@MainActor
final class VPN: ObservableObject {
    @Published var status = "—"
    @Published var raw: NEVPNStatus = .invalid
    private var mgr: NETunnelProviderManager?

    func load() async {
        let all = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        mgr = all.first ?? NETunnelProviderManager()
        refresh()
    }

    func refresh() {
        raw = mgr?.connection.status ?? .invalid
        status = mgr.map { String(describing: $0.connection.status) } ?? "—"
    }

    func connect(yaml: String) async throws {
        let m = mgr ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.oxi717.olc.tunnel"
        proto.serverAddress = "OlcRTC"
        proto.providerConfiguration = ["cnc_yaml": yaml]
        m.protocolConfiguration = proto
        m.localizedDescription = "OLC"
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        try m.connection.startVPNTunnel()
        mgr = m
        refresh()
    }

    func disconnect() { mgr?.connection.stopVPNTunnel(); refresh() }

    func disconnectAndWait(timeoutSeconds: TimeInterval) async {
        guard let m = mgr else {
            refresh()
            return
        }
        m.connection.stopVPNTunnel()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            refresh()
            if raw == .disconnected || raw == .invalid {
                AppDiag.log("vpn disconnect complete status=\(raw)")
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        refresh()
        AppDiag.log("vpn disconnect wait timeout status=\(raw)")
    }
}

struct ContentView: View {
    @StateObject private var vpn = VPN()
    @StateObject private var profiles = ProfileStore()
    @AppStorage("bootstrapURL") private var url = ""
    @AppStorage("clientKey") private var key = ""
    @AppStorage("localSub") private var localSub = ""
    @AppStorage("autoDirectDiag") private var autoDirectDiag = false
    @AppStorage("autoVPN") private var autoVPN = false
    @State private var err = ""
    @State private var tlog = ""
    @State private var isShowingAddProfile = false

    private struct HTTPProbeConfig {
        let customURL: String?
        let rounds: Int
        let intervalSeconds: Double
        let downloadBytes: Int
    }

    static func readTunnelLog() -> String {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.oxi717.olc") else { return "(нет app-group)" }
        let f = dir.appendingPathComponent("olc/tunnel.log")
        return (try? String(contentsOf: f, encoding: .utf8)) ?? "(лог пуст)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Профиль") {
                    if profiles.profiles.isEmpty {
                        Text("Нет конфигураций").foregroundStyle(.secondary)
                    } else {
                        Picker("Активный", selection: Binding(
                            get: { profiles.selectedProfileID },
                            set: { profiles.selectProfile(id: $0) }
                        )) {
                            ForEach(profiles.profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                    }

                    if let profile = profiles.selectedProfile {
                        LabeledContent("Канал", value: profile.subscription.carrier)
                        LabeledContent("Транспорт", value: profile.subscription.transport ?? "vp8channel")
                        LabeledContent("Тип", value: profile.isBuiltIn ? "built-in" : "custom")
                        if !profile.isBuiltIn {
                            Button("Удалить профиль", role: .destructive) {
                                profiles.deleteProfile(id: profile.id)
                            }
                        }
                    }

                    Button("Добавить конфигурацию") {
                        isShowingAddProfile = true
                    }
                }

                Section("Fallback") {
                    DisclosureGroup("Bootstrap / JSON") {
                        TextField("Bootstrap URL", text: $url)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Client key (hex64)", text: $key)
                        TextField("subscription JSON", text: $localSub, axis: .vertical)
                            .lineLimit(3...8)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }

                Section {
                    Toggle("Авто direct diag", isOn: $autoDirectDiag)
                    Toggle("Авто VPN", isOn: $autoVPN)
                    Button("Диагностика без VPN") { Task { await directDiag() } }
                    Button("Подключить VPN") { Task { await go() } }
                    Button("Отключить", role: .destructive) { vpn.disconnect() }
                    LabeledContent("Статус", value: vpn.status)
                    if !err.isEmpty { Text(err).foregroundStyle(.red).font(.caption) }
                }
                Section("Лог туннеля (extension)") {
                    Button("Обновить лог") { tlog = Self.readTunnelLog() }
                    if !tlog.isEmpty {
                        Text(tlog).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("OLC")
            .sheet(isPresented: $isShowingAddProfile) {
                AddProfileView(store: profiles)
            }
        }
        .task {
            Self.applyProfileOverride(to: profiles)
            await vpn.load()
            AppDiag.log("task vpn status=\(vpn.raw)")
            let forceConnect = Self.connectOnLaunchOverride
            if autoDirectDiag {
                await directDiag()
                return
            }
            if forceConnect, (vpn.raw == .connected || vpn.raw == .connecting || vpn.raw == .reasserting) {
                AppDiag.log("force reconnect existing status=\(vpn.raw)")
                await vpn.disconnectAndWait(timeoutSeconds: 15)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await vpn.load()
            }
            // идемпотентно: НЕ disconnect→connect (плодит конфликтующие инстансы extension за порт);
            // подключаем только если ещё не активны
            if (autoVPN || forceConnect), vpn.raw != .connected, vpn.raw != .connecting, vpn.raw != .reasserting,
               profiles.selectedProfile != nil || !localSub.isEmpty || !url.isEmpty {
                AppDiag.log("auto connect trigger autoVPN=\(autoVPN) force=\(forceConnect)")
                await go()
            } else {
                AppDiag.log("skip connect status=\(vpn.raw) autoVPN=\(autoVPN) force=\(forceConnect)")
            }
            if let probeConfig = Self.httpProbeConfig {
                if await waitForVPNConnectedForProbes(timeoutSeconds: 90) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await Self.runHTTPProbeLoop(probeConfig)
                } else {
                    AppDiag.log("http probe loop skipped vpn_status=\(vpn.raw)")
                }
            }
        }
    }

    private func waitForVPNConnectedForProbes(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            vpn.refresh()
            if vpn.raw == .connected {
                AppDiag.log("http probe vpn ready status=\(vpn.raw)")
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        vpn.refresh()
        AppDiag.log("http probe vpn wait timeout status=\(vpn.raw)")
        return vpn.raw == .connected
    }

    private static func applyProfileOverride(to store: ProfileStore) {
        #if DEBUG
        guard let profileID = argumentValue("--profile-id") ??
            ProcessInfo.processInfo.environment["OLC_PROFILE_ID"] else {
            return
        }
        if store.profiles.contains(where: { $0.id == profileID }) {
            store.selectProfile(id: profileID)
            AppDiag.log("profile override id=\(profileID)")
        } else {
            AppDiag.log("profile override ignored id=\(profileID)")
        }
        #endif
    }

    private static var connectOnLaunchOverride: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--connect-on-launch") ||
            ProcessInfo.processInfo.environment["OLC_CONNECT_ON_LAUNCH"] == "1"
        #else
        false
        #endif
    }

    private static var httpProbeConfig: HTTPProbeConfig? {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        let customURL = argumentValue("--http-probe-url") ?? env["OLC_HTTP_PROBE_URL"]
        let requestedRounds = intArgument("--probe-rounds", envName: "OLC_PROBE_ROUNDS")
        let downloadBytes = max(0, intArgument("--probe-download-bytes", envName: "OLC_PROBE_DOWNLOAD_BYTES") ?? 0)
        guard customURL != nil || requestedRounds != nil || downloadBytes > 0 else {
            return nil
        }
        let rounds = max(1, requestedRounds ?? 1)
        let interval = max(1, doubleArgument("--probe-interval", envName: "OLC_PROBE_INTERVAL") ?? 15)
        return HTTPProbeConfig(customURL: customURL, rounds: rounds, intervalSeconds: interval, downloadBytes: downloadBytes)
        #else
        return nil
        #endif
    }

    private static func argumentValue(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: name) else { return nil }
        let next = args.index(after: index)
        guard args.indices.contains(next) else { return nil }
        return args[next]
    }

    private static func intArgument(_ name: String, envName: String) -> Int? {
        if let value = argumentValue(name), let parsed = Int(value) {
            return parsed
        }
        if let value = ProcessInfo.processInfo.environment[envName], let parsed = Int(value) {
            return parsed
        }
        return nil
    }

    private static func doubleArgument(_ name: String, envName: String) -> Double? {
        if let value = argumentValue(name), let parsed = Double(value) {
            return parsed
        }
        if let value = ProcessInfo.processInfo.environment[envName], let parsed = Double(value) {
            return parsed
        }
        return nil
    }

    private static func runHTTPProbeLoop(_ config: HTTPProbeConfig) async {
        #if DEBUG
        let stamp = Int(Date().timeIntervalSince1970)
        AppDiag.log("http probe loop start rounds=\(config.rounds) interval_s=\(config.intervalSeconds) download_bytes=\(config.downloadBytes)")
        for round in 1...config.rounds {
            var okCount = 0
            var failCount = 0
            AppDiag.log("http probe round=\(round) start")

            if let customURL = config.customURL {
                if await runHTTPProbeWithRetries([customURL], label: "custom", timeout: 25, attempts: 2) {
                    okCount += 1
                } else {
                    failCount += 1
                }
            }

            let publicIPURLs = [
                "https://api.ipify.org?format=json&olc_probe=\(stamp)-\(round)",
                "https://www.cloudflare.com/cdn-cgi/trace?olc_probe=\(stamp)-\(round)"
            ]
            if await runHTTPProbeWithRetries(publicIPURLs, label: "ipify", timeout: 25, attempts: 3) {
                okCount += 1
            } else {
                failCount += 1
            }

            let exampleURL = "https://example.com/?olc_probe=\(stamp)-\(round)"
            if await runHTTPProbeWithRetries([exampleURL], label: "example", timeout: 25, attempts: 2) {
                okCount += 1
            } else {
                failCount += 1
            }

            if config.downloadBytes > 0 {
                let downloadURL = "https://speed.cloudflare.com/__down?bytes=\(config.downloadBytes)&olc_probe=\(stamp)-\(round)"
                if await runHTTPProbeWithRetries([downloadURL], label: "download", timeout: 60, expectedMinBytes: config.downloadBytes, attempts: 2) {
                    okCount += 1
                } else {
                    failCount += 1
                }
            }

            AppDiag.log("http probe round=\(round) done ok=\(okCount) fail=\(failCount)")
            if round < config.rounds {
                let ns = UInt64(config.intervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
        AppDiag.log("http probe loop done")
        #endif
    }

    @discardableResult
    private static func runHTTPProbeWithRetries(
        _ urlStrings: [String],
        label: String = "custom",
        timeout: TimeInterval = 25,
        expectedMinBytes: Int? = nil,
        attempts: Int = 3
    ) async -> Bool {
        #if DEBUG
        let safeAttempts = max(1, attempts)
        var totalAttempts = 0
        var lastHost = "(none)"
        var lastDetail = "no usable URL"

        for (urlIndex, urlString) in urlStrings.enumerated() {
            guard let url = URL(string: urlString) else {
                AppDiag.log("http probe retry label=\(label) host=(none) attempt=0/\(safeAttempts) error=invalid_url")
                continue
            }
            lastHost = url.host ?? "(none)"

            for attempt in 1...safeAttempts {
                totalAttempts += 1
                let result = await runHTTPProbeAttempt(url, label: label, timeout: timeout, expectedMinBytes: expectedMinBytes)
                if result.ok {
                    if totalAttempts > 1 {
                        AppDiag.log("http probe recovered label=\(label) host=\(lastHost) total_attempts=\(totalAttempts)")
                    }
                    return true
                }

                lastDetail = result.detail
                let hasMoreAttempts = attempt < safeAttempts
                let hasFallbackURL = urlIndex < urlStrings.count - 1
                if hasMoreAttempts || hasFallbackURL {
                    AppDiag.log("http probe retry label=\(label) host=\(lastHost) attempt=\(attempt)/\(safeAttempts) duration_ms=\(result.durationMS) error=\(result.detail)")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        AppDiag.log("http probe error label=\(label) host=\(lastHost) attempts=\(totalAttempts) \(lastDetail)")
        return false
        #else
        return false
        #endif
    }

    private static func runHTTPProbeAttempt(
        _ url: URL,
        label: String,
        timeout: TimeInterval,
        expectedMinBytes: Int?
    ) async -> (ok: Bool, detail: String, durationMS: Int) {
        #if DEBUG
        let started = Date()
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 25)
            request.timeoutInterval = timeout
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            request.setValue("close", forHTTPHeaderField: "Connection")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            AppDiag.log("http probe start label=\(label) host=\(url.host ?? "(none)") timeout_s=\(Int(timeout))")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let durationMS = Int(Date().timeIntervalSince(started) * 1000)
            let enoughBytes = expectedMinBytes.map { data.count >= $0 } ?? true
            let ok = (200..<400).contains(status) && enoughBytes
            AppDiag.log("http probe \(ok ? "ok" : "bad") label=\(label) host=\(url.host ?? "(none)") status=\(status) bytes=\(data.count) duration_ms=\(durationMS)")
            return (ok, "status=\(status) bytes=\(data.count)", durationMS)
        } catch {
            let durationMS = Int(Date().timeIntervalSince(started) * 1000)
            return (false, error.localizedDescription, durationMS)
        }
        #else
        return (false, "disabled", 0)
        #endif
    }

    private func go() async {
        do {
            let sub = try await resolveSubscription()
            AppDiag.log("connect start provider=\(sub.carrier) transport=\(sub.transport ?? "vp8channel")")
            try await vpn.connect(yaml: Sub.renderYAML(sub))
            AppDiag.log("connect ok provider=\(sub.carrier)")
            err = ""
        } catch {
            AppDiag.log("connect error \(error.localizedDescription)")
            err = "\(error.localizedDescription)"
        }
    }

    private func directDiag() async {
        do {
            let sub = try await resolveSubscription()
            AppDiag.log("direct diag start provider=\(sub.carrier) transport=\(sub.transport ?? "vp8channel")")
            DirectDiag.start(subscription: sub)
            err = ""
        } catch {
            AppDiag.log("direct diag error \(error.localizedDescription)")
            err = "\(error.localizedDescription)"
        }
    }

    private func resolveSubscription() async throws -> Subscription {
        if let profile = profiles.selectedProfile {
            return profile.subscription
        }
        if !localSub.isEmpty, let data = localSub.data(using: .utf8) {
            return try JSONDecoder().decode(Subscription.self, from: data)
        }
        if !url.isEmpty {
            return try await Sub.fetch(url, keyHex: key)
        }
        throw Sub.err("нет выбранной конфигурации")
    }
}

struct AddProfileView: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var carrier = "telemost"
    @State private var room = ""
    @State private var channel = ""
    @State private var cryptoKey = ""
    @State private var transport = "vp8channel"
    @State private var json = ""
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("JSON") {
                    TextField("subscription JSON", text: $json, axis: .vertical)
                        .lineLimit(3...8)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Поля") {
                    TextField("Название", text: $name)
                    Picker("Канал", selection: $carrier) {
                        Text("Telemost").tag("telemost")
                        Text("WB").tag("wbstream")
                    }
                    TextField("Room", text: $room)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Channel", text: $channel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Crypto key hex64", text: $cryptoKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Transport", text: $transport)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if !error.isEmpty {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Добавить профиль")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                }
            }
        }
    }

    private func save() {
        do {
            let trimmedJSON = json.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedJSON.isEmpty {
                let subscription = try JSONDecoder().decode(Subscription.self, from: Data(trimmedJSON.utf8))
                try validate(subscription)
                store.addProfile(name: name, subscription: subscription)
            } else {
                let trimmedKey = cryptoKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedTransport = transport.trimmingCharacters(in: .whitespacesAndNewlines)
                let subscription = Subscription(
                    carrier: carrier,
                    room: room.trimmingCharacters(in: .whitespacesAndNewlines),
                    channel: channel.trimmingCharacters(in: .whitespacesAndNewlines),
                    crypto_key: trimmedKey,
                    transport: trimmedTransport.isEmpty ? "vp8channel" : trimmedTransport
                )
                try validate(subscription)
                store.addProfile(name: name, subscription: subscription)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func validate(_ subscription: Subscription) throws {
        if subscription.carrier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Sub.err("carrier обязателен")
        }
        if subscription.room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Sub.err("room обязателен")
        }
        if subscription.channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Sub.err("channel обязателен")
        }
        guard Data(hexString: subscription.crypto_key)?.count == 32 else {
            throw Sub.err("crypto_key должен быть hex64")
        }
    }
}

extension Data {
    init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count % 2 == 0 else { return nil }
        var d = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let n = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<n], radix: 16) else { return nil }
            d.append(b); i = n
        }
        self = d
    }
}
