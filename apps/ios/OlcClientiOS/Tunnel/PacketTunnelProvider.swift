import NetworkExtension
import OlcMobile
import Tun2SocksKit
import Foundation

// NEPacketTunnelProvider: поднимает olcrtc cnc (OlcMobile, gomobile) → SOCKS5 :1080,
// затем tun2socks (hev-socks5-tunnel) гонит весь трафик tun → SOCKS. Весь трафик устройства
// идёт в whitelisted-видеозвонок → srv → интернет.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let statsQueue = DispatchQueue(label: "com.oxi717.olc.tunnel.stats")
    private let bootstrapQueue = DispatchQueue(label: "com.oxi717.olc.tunnel.bootstrap")
    private let healthQueue = DispatchQueue(label: "com.oxi717.olc.tunnel.health")
    private var statsTimer: DispatchSourceTimer?
    private var bootstrapTimer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    private var consecutiveHealthFailures = 0
    private var bootstrapRefreshInFlight = false

    // лог в app-group (читается из приложения для диагностики физического устройства)
    private func dbg(_ m: String) {
        NSLog("olc-tun: \(m)")
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.oxi717.olc")?
            .appendingPathComponent("olc") else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("tunnel.log")
        let line = "\(Date()) \(m)\n"
        guard let d = line.data(using: .utf8) else { return }
        // ai-generated: keeps extension diagnostics bounded across on-demand retries.
        BoundedLog.append(d, to: f, maxBytes: 1_048_576)
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        dbg("=== startTunnel ===")
        stopStatsLoop()
        stopHealthLoop()
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        let providerConfiguration = proto?.providerConfiguration ?? [:]
        let managed = ManagedTunnelDescriptor(providerConfiguration: providerConfiguration)
        var activeGeneration = managed?.generation
        var baseYAML = (providerConfiguration["cnc_yaml"] as? String) ?? ""
        if let managed {
            do {
                let envelope = try await resolveManagedBootstrap(managed)
                baseYAML = envelope.subscription.renderYAML()
                activeGeneration = envelope.generation
                dbg("managed bootstrap ready profile=\(managed.profileID) generation=\(envelope.generation)")
            } catch {
                dbg("managed bootstrap fallback profile=\(managed.profileID) generation=\(managed.generation) error=\(error.localizedDescription)")
            }
        }
        // динамический порт SOCKS: зомби-инстанс extension может держать старый порт
        // (переживает uninstall/kill, невидим devicectl). Каждый запуск — свой свободный
        // порт → конфликта "bind: address already in use" больше нет.
        let port = Self.freePort()
        let yaml = baseYAML
            .replacingOccurrences(of: "port: 1080", with: "port: \(port)")
        dbg("cnc_yaml len=\(yaml.count) dynamic SOCKS port=\(port)")
        let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.oxi717.olc")?
            .appendingPathComponent("olc").path ?? (NSTemporaryDirectory() + "olc")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // перехват stderr/stdout Go-cnc → файл (внутренние логи olcrtc: ICE/vp8channel/welcome)
        let cncLog = (dir as NSString).appendingPathComponent("cnc-stderr.log")
        // ai-generated: rotates the native log before attaching a new tunnel process.
        BoundedLog.rotateIfNeeded(URL(fileURLWithPath: cncLog), maxBytes: 8_388_608)
        freopen(cncLog, "a+", stderr)
        freopen(cncLog, "a+", stdout)
        dbg("cnc stderr → cnc-stderr.log")

        // olcrtc cnc (gomobile) — БЛОКИРУЕТ, в отдельном потоке. Поднимает SOCKS5 127.0.0.1:1080.
        // ОДНА попытка: olcrtc internal liveness держит установленную сессию (vp8 rebuild без
        // ре-бинда listener). Повторный StartCnc течёт SOCKS-listener (session.Run не закрывает
        // его на возврате) → bind: address already in use. На провал инициализации просим систему
        // перезапустить туннель свежим процессом (чистый порт).
        // ОДНА попытка (НЕ retry-цикл): пере-джойн Telemost плодит старые cnc-участники в SFU,
        // их control-кадры (другой epoch, не loopback) сыплются в ЕДИНЫЙ control KCP → поток
        // перемешан → welcome теряется → timeout. Один cnc-участник = единственный чужой
        // control-epoch (srv) = чистый KCP. olcrtc internal liveness держит установленную сессию.
        // На провал инициализации — cancelTunnelWithError (система перезапустит свежим процессом).
        Thread.detachNewThread {
            var err: NSError?
            self.dbg("cnc start")
            OlcmobileStartCnc(yaml, dir, &err)
            if let err { self.dbg("cnc ENDED err: \(err.localizedDescription)") }
            else { self.dbg("cnc ENDED clean") }
            self.cancelTunnelWithError(err)
        }

        var readyErr: NSError?
        OlcmobileWaitReady(120_000, &readyErr)
        if let readyErr {
            dbg("cnc not ready err: \(readyErr.localizedDescription)")
            throw readyErr
        }
        dbg("cnc session ready")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["10.66.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["198.18.0.2"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = 1400
        try await setTunnelNetworkSettings(settings)
        dbg("network settings applied (v4 default route, mapdns 198.18.0.2, v6 passthrough)")

        if Self.canConnect(host: "127.0.0.1", port: port) {
            dbg("SOCKS ready")
        } else {
            dbg("WARN: cnc reported ready but SOCKS port is not reachable")
        }

        // tun2socks: tun → SOCKS5 1080
        let t2s = """
        tunnel:
          mtu: 1400
        socks5:
          port: \(port)
          address: 127.0.0.1
        mapdns:
          address: 198.18.0.2
          port: 53
          network: 240.0.0.0
          netmask: 240.0.0.0
          cache-size: 10000
        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          max-session-count: 48
          connect-timeout: 5000
          read-write-timeout: 60000
          log-file: stderr
          log-level: error
        """
        dbg("tun2socks starting mapdns=198.18.0.2 udp=disabled sessions=48 log=stderr/error")
        Socks5Tunnel.run(withConfig: .string(content: t2s)) { code in
            self.dbg("tun2socks exited code=\(code)")
            self.stopStatsLoop()
        }
        startStatsLoop()
        startHealthLoop()
        if let managed, let activeGeneration {
            startManagedBootstrapLoop(managed, activeGeneration: activeGeneration)
        }
        dbg("=== startTunnel done ===")
    }

    private func bootstrapCache() throws -> BootstrapCache {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.oxi717.olc") else {
            throw NSError(
                domain: "com.oxi717.olc.bootstrap",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "app group unavailable"]
            )
        }
        return BootstrapCache(directory: base.appendingPathComponent("olc/bootstrap"))
    }

    private func resolveManagedBootstrap(
        _ managed: ManagedTunnelDescriptor
    ) async throws -> BootstrapEnvelope {
        try await BootstrapResolver(cache: bootstrapCache()).resolve(
            descriptor: managed.bootstrap,
            profileID: managed.profileID,
            minimumAcceptedGeneration: managed.generation
        )
    }

    private func startManagedBootstrapLoop(
        _ managed: ManagedTunnelDescriptor,
        activeGeneration: Int
    ) {
        stopManagedBootstrapLoop()
        let timer = DispatchSource.makeTimerSource(queue: bootstrapQueue)
        timer.schedule(
            deadline: .now() + .seconds(30),
            repeating: .seconds(60),
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            guard let self, !self.bootstrapRefreshInFlight else { return }
            self.bootstrapRefreshInFlight = true
            Task {
                defer {
                    self.bootstrapQueue.async { self.bootstrapRefreshInFlight = false }
                }
                do {
                    let candidate = try await self.resolveManagedBootstrap(managed)
                    guard ManagedBootstrapDecision.shouldReconnect(
                        activeGeneration: activeGeneration,
                        candidateGeneration: candidate.generation
                    ) else { return }
                    self.dbg("managed bootstrap update profile=\(managed.profileID) generation=\(candidate.generation) restarting")
                    self.restartTunnel(
                        NSError(
                            domain: "com.oxi717.olc.bootstrap",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "managed configuration updated"]
                        )
                    )
                } catch {
                    self.dbg("managed bootstrap refresh failed profile=\(managed.profileID) error=\(error.localizedDescription)")
                }
            }
        }
        bootstrapTimer = timer
        timer.resume()
    }

    private func stopManagedBootstrapLoop() {
        bootstrapTimer?.cancel()
        bootstrapTimer = nil
    }

    private func startStatsLoop() {
        stopStatsLoop()
        let timer = DispatchSource.makeTimerSource(queue: statsQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(10), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            let stats = Socks5Tunnel.stats
            self?.dbg("tun2socks stats up_packets=\(stats.up.packets) up_bytes=\(stats.up.bytes) down_packets=\(stats.down.packets) down_bytes=\(stats.down.bytes)")
        }
        statsTimer = timer
        timer.resume()
    }

    private func stopStatsLoop() {
        statsTimer?.cancel()
        statsTimer = nil
    }

    private func startHealthLoop() {
        stopHealthLoop()
        consecutiveHealthFailures = 0
        let timer = DispatchSource.makeTimerSource(queue: healthQueue)
        timer.schedule(
            deadline: .now() + .seconds(20),
            repeating: .seconds(30),
            leeway: .seconds(3)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var probeError: NSError?
            OlcmobileProbeSocks(10_000, &probeError)
            if let probeError {
                self.consecutiveHealthFailures += 1
                self.dbg("tunnel health failed count=\(self.consecutiveHealthFailures) error=\(probeError.localizedDescription)")
                if self.consecutiveHealthFailures >= 3 {
                    self.dbg("tunnel health exhausted; restarting")
                    self.restartTunnel(
                        NSError(
                            domain: "com.oxi717.olc.health",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "tunnel data path unavailable"]
                        )
                    )
                }
                return
            }
            if self.consecutiveHealthFailures > 0 {
                self.dbg("tunnel health recovered after=\(self.consecutiveHealthFailures)")
            }
            self.consecutiveHealthFailures = 0
        }
        healthTimer = timer
        timer.resume()
    }

    private func stopHealthLoop() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func restartTunnel(_ error: NSError) {
        stopManagedBootstrapLoop()
        stopStatsLoop()
        stopHealthLoop()
        Socks5Tunnel.quit()
        OlcmobileStop()
        cancelTunnelWithError(error)
    }

    // TCP-probe готовности SOCKS listener
    static func canConnect(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    // выбирает свободный TCP-порт (bind :0 → getsockname) — обход зомби на 1080
    static func freePort() -> UInt16 {
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

    override func stopTunnel(with reason: NEProviderStopReason) async {
        dbg("stopTunnel reason=\(reason.rawValue)")
        stopManagedBootstrapLoop()
        stopStatsLoop()
        stopHealthLoop()
        Socks5Tunnel.quit()
        OlcmobileStop()
    }
}
