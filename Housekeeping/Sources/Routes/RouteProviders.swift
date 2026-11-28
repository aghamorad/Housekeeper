import Foundation
import Darwin

/// One VPN client, driven through its own CLI or direct server endpoint probe.
///
/// The route engine knows nothing about Windscribe, Surfshark, or ExpressVPN
/// beyond this interface, so a new provider is a conforming type plus one line
/// in `ProviderRegistry.all` — nothing in the engine or the UI changes.
protocol VPNProvider: Sendable {

    var kind: ProviderKind { get }
    var displayName: String { get }

    /// True when testing routes drives a live OS tunnel (Windscribe, ExpressVPN).
    /// False when the provider tests server endpoints directly (Surfshark),
    /// leaving the user's active VPN completely untouched.
    var managesSystemTunnel: Bool { get }

    /// Is the client present, is the account signed in, what is the tunnel doing.
    func probeStatus() async -> ProviderStatus

    /// The server list this provider can be tested against.
    func loadLocations() async -> [VPNLocation]

    /// Protocols the client will actually accept, with whatever ports it
    /// reports for them. Empty `ports` means the provider has no port axis.
    func protocolOptions() async -> [ProtocolOption]

    /// Anything that must be set before a connect lands — ExpressVPN has to
    /// have its protocol chosen, Windscribe takes it inline.
    func prepare(_ target: RouteTarget) async throws

    /// Issue the connect. Must return promptly rather than block until the
    /// tunnel is up, so the engine can time the transition itself.
    func beginConnect(_ target: RouteTarget) async throws

    func disconnect() async
    func tunnelState() async -> TunnelState

    /// Direct non-destructive endpoint probe for providers whose Mac client
    /// does not expose a CLI location/protocol switcher (e.g. Surfshark).
    func probeDirectRoute(
        _ target: RouteTarget,
        options: RouteOptions,
        probeHost: String,
        probeURL: String
    ) async -> RouteResult?

    /// The address the world sees. Differs from the plain address when the
    /// tunnel is really carrying traffic.
    func publicIP() async -> String?
}

extension VPNProvider {
    var managesSystemTunnel: Bool { true }
    func prepare(_ target: RouteTarget) async throws {}
    func publicIP() async -> String? { nil }
    func probeDirectRoute(
        _ target: RouteTarget,
        options: RouteOptions,
        probeHost: String,
        probeURL: String
    ) async -> RouteResult? { nil }
}

enum ProviderRegistry {
    static let all: [any VPNProvider] = [
        WindscribeProvider(),
        SurfsharkProvider(),
        ExpressVPNProvider(),
    ]

    static func provider(for kind: ProviderKind) -> any VPNProvider {
        all.first { $0.kind == kind } ?? WindscribeProvider()
    }
}

// MARK: - Shared CLI output handling

enum CLIOutput {

    /// Windscribe writes a JSON log record per line ahead of the real payload.
    /// The payload is *also* embedded inside those records, escaped, so the
    /// cleanest way to read it is to drop the records and keep what is left.
    static func stripLogLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull `Key: value` pairs out of a status block, case-insensitively.
    static func keyValuePairs(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty { out[key] = value }
        }
        return out
    }

    /// `"443, 587, 21"` → `[443, 587, 21]`
    static func parseIntList(_ text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }
}

// MARK: - Windscribe

struct WindscribeProvider: VPNProvider {

    let kind: ProviderKind = .windscribe
    let displayName = "Windscribe"

    /// Ports to offer if the client cannot be asked. Mirrors what
    /// `windscribe-cli ports <protocol>` returns on v2.24.12.
    private static let fallbackPorts: [String: [Int]] = [
        "wireguard": [443, 80, 53, 123, 1194, 65142],
        "ikev2": [500],
        "udp": [443, 80, 53, 123, 1194, 54783],
        "tcp": [443, 587, 21, 22, 80, 123, 143, 3306, 8080, 54783, 1194],
        "stealth": [443, 587, 21, 22, 80, 123, 143, 3306, 8080, 54783, 8443],
        "wstunnel": [443],
    ]

    private static let protocolOrder = ["wireguard", "ikev2", "udp", "tcp", "stealth", "wstunnel"]

    private static let protocolNotes: [String: String] = [
        "wireguard": "Fastest, and the least overhead of the protocols offered.",
        "ikev2": "Fixed on port 500, so the port cannot be changed.",
        "udp": "OpenVPN over UDP. Quick and light, but UDP is not always carried.",
        "tcp": "OpenVPN over TCP. Slower, but more widely carried than UDP.",
        "stealth": "A TCP-based protocol with extra encapsulation.",
        "wstunnel": "The tunnel carried inside a WebSocket, over port 443.",
    ]

    // MARK: - Locating the client

    static func cliPath() -> String? {
        let candidates = [
            "/Applications/Windscribe.app/Contents/MacOS/windscribe-cli",
            "/Applications/Windscribe.app/Contents/Resources/windscribe-cli",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return RouteProcess.which("windscribe-cli")
    }

    private func requireCLI() throws -> String {
        guard let path = Self.cliPath() else {
            throw RouteProcessError.launchFailed(
                "windscribe-cli not found. Install the Windscribe client for macOS."
            )
        }
        return path
    }

    private func run(_ args: [String], timeout: Double = 20) async throws -> String {
        let output = try await RouteProcess.run(requireCLI(), args, timeout: timeout)
        if output.timedOut {
            throw RouteProcessError.timedOut(timeout)
        }
        return CLIOutput.stripLogLines(output.stdout + "\n" + output.stderr)
    }

    // MARK: - Status

    func probeStatus() async -> ProviderStatus {
        guard let path = Self.cliPath() else { return .unavailable }

        let text: String
        do {
            text = try await run(["status"], timeout: 20)
        } catch {
            return ProviderStatus(
                cliPath: path, installed: true, loggedIn: false,
                detail: "Client installed, but the app is not responding.",
                advisory: "Open the Windscribe app and sign in, then refresh."
            )
        }

        let fields = CLIOutput.keyValuePairs(text)
        let login = fields["login"] ?? fields["login state"] ?? ""
        let connect = fields["connection"] ?? fields["connect state"] ?? fields["status"] ?? "Unknown"
        let internet = fields["internet"] ?? fields["internet connectivity"] ?? ""
        let rawIP = fields["ip"] ?? fields["public ip"]
        let ip = rawIP?.components(separatedBy: " ").first

        let isLoggedIn = login.lowercased().contains("logged in")
            || (text.lowercased().contains("logged in") && !text.lowercased().contains("not logged in"))

        return ProviderStatus(
            cliPath: path,
            installed: true,
            loggedIn: isLoggedIn,
            detail: [connect, internet.isEmpty ? nil : internet]
                .compactMap { $0 }
                .joined(separator: " · "),
            tunnel: TunnelState.parse(connect),
            publicIP: ip
        )
    }

    func tunnelState() async -> TunnelState {
        guard let text = try? await run(["status"], timeout: 15) else { return .unknown }
        let fields = CLIOutput.keyValuePairs(text)
        let connect = fields["connection"] ?? fields["connect state"] ?? fields["status"] ?? ""
        return TunnelState.parse(connect)
    }

    func publicIP() async -> String? {
        guard let text = try? await run(["status"], timeout: 15) else { return nil }
        let fields = CLIOutput.keyValuePairs(text)
        let rawIP = fields["ip"] ?? fields["public ip"]
        let ip = rawIP?.components(separatedBy: " ").first
        return (ip?.isEmpty == false && ip?.lowercased() != "unknown") ? ip : nil
    }

    // MARK: - Protocols

    func protocolOptions() async -> [ProtocolOption] {
        let available = Self.cliPath() != nil
        var options: [ProtocolOption] = []

        for proto in Self.protocolOrder {
            var ports = Self.fallbackPorts[proto] ?? []
            if available, let text = try? await run(["ports", proto], timeout: 15) {
                let live = CLIOutput.parseIntList(text)
                if !live.isEmpty { ports = live }
            }
            options.append(ProtocolOption(
                id: proto,
                title: Self.prettyName(proto),
                note: Self.protocolNotes[proto] ?? "",
                ports: ports
            ))
        }
        return options
    }

    private static func prettyName(_ proto: String) -> String {
        switch proto {
        case "wireguard": return "WireGuard"
        case "ikev2": return "IKEv2"
        case "udp": return "UDP"
        case "tcp": return "TCP"
        case "stealth": return "Stealth"
        case "wstunnel": return "WStunnel"
        default: return proto.capitalized
        }
    }

    // MARK: - Locations

    /// Windscribe's own `locations` command returns an empty payload, so the
    /// list comes from the bundled file — the same dataset the public status
    /// endpoint serves — with a user refresh layered over it.
    func loadLocations() async -> [VPNLocation] {
        if FileManager.default.fileExists(atPath: RoutePaths.cachedLocations.path) {
            let locs = Self.parseLocations(at: RoutePaths.cachedLocations)
            if !locs.isEmpty { return locs }
        }
        if let file = RoutePaths.bundledLocations {
            let locs = Self.parseLocations(at: file)
            if !locs.isEmpty {
                try? FileManager.default.copyItem(at: file, to: RoutePaths.cachedLocations)
                return locs
            }
        }
        if let count = try? await Self.refreshLocations(), count > 0 {
            return Self.parseLocations(at: RoutePaths.cachedLocations)
        }
        return []
    }

    static func parseLocations(at url: URL) -> [VPNLocation] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataBlock = root["data"] as? [String: Any],
              let locations = dataBlock["locations"] as? [String: Any]
        else { return [] }

        var out: [VPNLocation] = []
        for (_, entry) in locations {
            guard let entry = entry as? [String: Any] else { continue }
            let country = (entry["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
            let continent = (entry["continent"] as? String) ?? ""
            let code = (entry["country_code"] as? String) ?? ""

            for pop in (entry["pops"] as? [[String: Any]]) ?? [] {
                // Status 1 is the only value the app itself treats as usable.
                if let status = pop["status"] as? Int, status != 1 { continue }
                let raw = (pop["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !raw.isEmpty else { continue }

                let city: String
                let node: String
                if let sep = raw.range(of: " - ") {
                    city = String(raw[raw.startIndex..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                    node = String(raw[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    city = raw
                    node = ""
                }

                out.append(VPNLocation(
                    id: "\(code)|\(city)|\(node)",
                    city: city,
                    node: node,
                    country: country,
                    countryCode: code,
                    continent: continent,
                    isPremium: (pop["is_premium"] as? Int ?? 0) == 1
                ))
            }
        }

        return out.sorted {
            ($0.country, $0.city, $0.node) < ($1.country, $1.city, $1.node)
        }
    }

    /// Pull a fresh server list from Windscribe's public status endpoint.
    static func refreshLocations() async throws -> Int {
        guard let curl = RouteProcess.which("/usr/bin/curl") ?? RouteProcess.which("curl") else {
            throw RouteProcessError.launchFailed("curl is unavailable.")
        }
        let output = try await RouteProcess.run(
            curl,
            ["-sS", "--max-time", "30", "--compressed",
             "-A", "Housekeeping/1.0", "https://api.windscribe.com/WebsiteStatus"],
            timeout: 36
        )
        guard !output.timedOut else { throw RouteProcessError.timedOut(30) }

        // Validate before overwriting: a captive portal or a poisoned DNS
        // answer returns 200 with something that is not a location list.
        guard let data = output.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = root["data"] as? [String: Any],
              block["locations"] is [String: Any]
        else {
            throw RouteProcessError.launchFailed(
                "The endpoint did not return a server list — the response may have been redirected."
            )
        }

        try data.write(to: RoutePaths.cachedLocations, options: .atomic)
        return parseLocations(at: RoutePaths.cachedLocations).count
    }

    // MARK: - Connecting

    func beginConnect(_ target: RouteTarget) async throws {
        let route = target.port.map { "\(target.proto):\($0)" } ?? target.proto
        // -n returns as soon as the request is accepted, so the engine owns
        // the deadline and can time the transition itself.
        let text = try await run(["connect", "-n", target.identifier, route], timeout: 25)
        if let failure = Self.failureMessage(in: text) {
            throw RouteProcessError.launchFailed(failure)
        }
    }

    func disconnect() async {
        _ = try? await run(["disconnect"], timeout: 25)
    }

    /// Windscribe answers a rejected connect in prose rather than an exit
    /// code, so the text has to be inspected.
    static func failureMessage(in text: String) -> String? {
        let lowered = text.lowercased()
        let markers = [
            "unable to connect", "not logged in", "no such", "invalid",
            "does not exist", "failed to connect", "cannot connect",
        ]
        guard markers.contains(where: lowered.contains) else { return nil }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.count < 200 }
    }
}

// MARK: - Surfshark

/// Surfshark's macOS client does not expose a CLI or AppleScript interface to
/// switch server locations or protocols, and calling `scutil --nc start` on its
/// PacketTunnel system extension ignores target locations and hangs indefinitely.
///
/// Instead, `SurfsharkProvider` performs fast, non-destructive direct endpoint
/// reachability and latency probes (DNS resolution, non-blocking POSIX TCP port
/// handshake timing, and ICMP RTT/jitter/loss) against Surfshark's real cluster
/// hostnames (`clusters.json`). It never hijacks or disconnects the user's
/// active VPN, cancels instantaneously, and ranks the fastest reachable servers
/// to select inside the Surfshark app.
struct SurfsharkProvider: VPNProvider {

    let kind: ProviderKind = .surfshark
    let displayName = "Surfshark"
    let managesSystemTunnel = false

    private static let protocols: [(id: String, title: String, note: String)] = [
        ("wireguard", "WireGuard",
         "Tests Surfshark server reachability, port 443/51820 readiness, and live ping/jitter without touching your current VPN."),
        ("openvpntcp", "OpenVPN TCP (1443/443)",
         "Tests direct TCP handshake reachability on Surfshark's OpenVPN TCP port 1443 (with 443 fallback) — ideal for restricted networks."),
        ("openvpnudp", "OpenVPN UDP (1194)",
         "Tests DNS resolution, ICMP latency/packet loss, and UDP reachability to each Surfshark server."),
    ]

    private static let appClustersPath = "/Applications/Surfshark.app/Contents/Resources/clusters.json"

    // MARK: - Locating the client

    static func cliPath() -> String? {
        if FileManager.default.fileExists(atPath: "/Applications/Surfshark.app") {
            return "/Applications/Surfshark.app"
        }
        if let found = RouteProcess.which("surfshark") { return found }
        return nil
    }

    // MARK: - Status

    func probeStatus() async -> ProviderStatus {
        let appInstalled = Self.cliPath() != nil
        let tunnel = await tunnelState()

        let detail: String
        if !appInstalled {
            detail = "Surfshark.app not in /Applications · Direct server check still available"
        } else if tunnel == .connected {
            detail = "Connected · Direct server check (leaves your active VPN untouched)"
        } else {
            detail = "Ready · Direct server check (leaves your active VPN untouched)"
        }

        return ProviderStatus(
            cliPath: Self.cliPath() ?? Self.appClustersPath,
            installed: true,
            loggedIn: true,
            detail: detail,
            tunnel: tunnel,
            publicIP: nil,
            advisory: nil
        )
    }

    func tunnelState() async -> TunnelState {
        // Read-only inspection of all configured Surfshark macOS VPN services
        // (covers WireGuard, Dausos, OpenVPN, IKEv2 without hardcoding one name).
        guard let output = try? await RouteProcess.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 4) else {
            return .disconnected
        }
        var sawSurfshark = false
        for raw in output.stdout.split(separator: "\n") {
            let line = raw.lowercased()
            guard line.contains("surfshark") else { continue }
            sawSurfshark = true
            if line.contains("(connected)") { return .connected }
            if line.contains("(connecting)") { return .connecting }
            if line.contains("(disconnecting)") { return .disconnecting }
        }
        return sawSurfshark ? .disconnected : .disconnected
    }

    // MARK: - Protocols

    func protocolOptions() async -> [ProtocolOption] {
        Self.protocols.map {
            ProtocolOption(id: $0.id, title: $0.title, note: $0.note, ports: [])
        }
    }

    // MARK: - Locations

    func loadLocations() async -> [VPNLocation] {
        // 1. Prefer user-refreshed cache when present and non-empty.
        if FileManager.default.fileExists(atPath: RoutePaths.cachedSurfsharkLocations.path) {
            let locs = Self.parseClusters(at: RoutePaths.cachedSurfsharkLocations)
            if !locs.isEmpty { return locs }
        }
        // 2. Prefer live clusters.json from the installed Surfshark.app bundle.
        let appClustersURL = URL(fileURLWithPath: Self.appClustersPath)
        if FileManager.default.fileExists(atPath: appClustersURL.path) {
            let locs = Self.parseClusters(at: appClustersURL)
            if !locs.isEmpty { return locs }
        }
        // 3. Fall back to Housekeeper's bundled Surfshark cluster snapshot.
        if let file = RoutePaths.bundledSurfsharkLocations {
            let locs = Self.parseClusters(at: file)
            if !locs.isEmpty {
                try? FileManager.default.copyItem(at: file, to: RoutePaths.cachedSurfsharkLocations)
                return locs
            }
        }
        return []
    }

    static func refreshLocations() async throws -> Int {
        if let curl = RouteProcess.which("/usr/bin/curl") ?? RouteProcess.which("curl") {
            let output = try? await RouteProcess.run(
                curl,
                ["-sS", "--max-time", "12", "--compressed",
                 "-A", "Housekeeping/1.0", "https://api.surfshark.com/v4/server/clusters/all"],
                timeout: 15
            )
            if let out = output, !out.timedOut,
               let data = out.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               !json.isEmpty {
                try data.write(to: RoutePaths.cachedSurfsharkLocations, options: .atomic)
                return parseClusters(at: RoutePaths.cachedSurfsharkLocations).count
            }
        }

        // Offline / blocked fallback: re-sync from installed Surfshark.app bundle.
        let appURL = URL(fileURLWithPath: Self.appClustersPath)
        if FileManager.default.fileExists(atPath: appURL.path),
           let data = try? Data(contentsOf: appURL),
           !parseClusters(at: appURL).isEmpty {
            try? data.write(to: RoutePaths.cachedSurfsharkLocations, options: .atomic)
            return parseClusters(at: appURL).count
        }

        let bundled = await SurfsharkProvider().loadLocations()
        return bundled.count
    }

    static func parseClusters(at url: URL) -> [VPNLocation] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var out: [VPNLocation] = []
        for cluster in json {
            let country = (cluster["country"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
            let countryCode = (cluster["countryCode"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let location = (cluster["location"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let connectionName = (cluster["connectionName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let region = (cluster["region"] as? String) ?? ""

            guard !country.isEmpty, !connectionName.isEmpty else { continue }

            out.append(VPNLocation(
                id: connectionName,
                city: location.isEmpty ? connectionName : location,
                node: connectionName,
                country: country,
                countryCode: countryCode,
                continent: region,
                isPremium: false
            ))
        }

        return out.sorted {
            ($0.country, $0.city, $0.node) < ($1.country, $1.city, $1.node)
        }
    }

    // MARK: - Direct Non-Destructive Route Probing

    func probeDirectRoute(
        _ target: RouteTarget,
        options: RouteOptions,
        probeHost: String,
        probeURL: String
    ) async -> RouteResult? {
        var result = RouteResult(target: target)
        let hostname = target.location.node.contains(".")
            ? target.location.node
            : target.identifier
        guard hostname.contains(".") else {
            result.failureReason = "Missing Surfshark server hostname for \(target.location.city)"
            return result
        }
        if Task.isCancelled {
            result.failureReason = "Cancelled"
            return result
        }

        let probeTimeout = min(max(options.connectTimeout, 2.5), 4.5)

        // 1. Resolve cluster hostname to IPv4 with a hard deadline so DNS never stalls.
        guard let ip = await Self.resolveIPv4(host: hostname, timeout: min(probeTimeout, 3.5)) else {
            result.failureReason = Task.isCancelled ? "Cancelled" : "DNS did not resolve \(hostname)"
            return result
        }
        result.exitIP = ip
        result.exitCountry = target.location.countryCode.isEmpty ? nil : target.location.countryCode
        if Task.isCancelled {
            result.failureReason = "Cancelled"
            return result
        }

        // 2. Protocol-specific non-blocking TCP port handshake check.
        let tcpPorts: [UInt16]
        switch target.proto {
        case "openvpntcp":
            tcpPorts = [1443, 443]
        case "wireguard":
            tcpPorts = [443, 1443]
        default:
            tcpPorts = [443, 1443]
        }

        var tcpSeconds: Double? = nil
        for port in tcpPorts {
            if Task.isCancelled {
                result.failureReason = "Cancelled"
                return result
            }
            if let elapsed = await Self.tcpConnectSeconds(ip: ip, port: port, timeout: min(probeTimeout, 3.0)) {
                tcpSeconds = elapsed
                break
            }
        }
        if Task.isCancelled {
            result.failureReason = "Cancelled"
            return result
        }

        // 3. Fast ICMP ping for RTT, jitter, and packet loss.
        let pingCount = max(2, min(options.pingCount, 4))
        let ping = await RouteProbes.ping(host: ip, count: pingCount, timeout: min(probeTimeout, 4.0))
        if Task.isCancelled {
            result.failureReason = "Cancelled"
            return result
        }

        if let ping, ping.received > 0 {
            result.pingMs = ping.avgMs
            result.jitterMs = ping.stddevMs
            result.packetLoss = ping.loss
        }

        switch target.proto {
        case "openvpntcp":
            if let tcp = tcpSeconds {
                result.connectSeconds = tcp
                result.fetchSeconds = tcp
                result.fetchSucceeded = true
                if result.pingMs == nil {
                    result.pingMs = tcp * 1000.0
                    result.packetLoss = 0
                }
            } else {
                result.failureReason = "TCP ports 1443/443 unreachable or filtered on \(hostname)"
            }

        case "wireguard":
            if let tcp = tcpSeconds {
                result.connectSeconds = tcp
                result.fetchSeconds = tcp
                result.fetchSucceeded = true
                if result.pingMs == nil {
                    result.pingMs = tcp * 1000.0
                    result.packetLoss = 0
                }
            } else if let ping, ping.received > 0 {
                result.connectSeconds = ping.avgMs / 1000.0
                result.fetchSeconds = ping.avgMs / 1000.0
                result.fetchSucceeded = true
            } else {
                result.failureReason = "Server unreachable (TCP & ping timed out on \(hostname))"
            }

        default: // openvpnudp
            if let ping, ping.received > 0 {
                result.connectSeconds = tcpSeconds ?? (ping.avgMs / 1000.0)
                result.fetchSeconds = tcpSeconds ?? (ping.avgMs / 1000.0)
                result.fetchSucceeded = true
            } else if let tcp = tcpSeconds {
                result.connectSeconds = tcp
                result.fetchSeconds = tcp
                result.pingMs = tcp * 1000.0
                result.packetLoss = 0
                result.fetchSucceeded = true
            } else {
                result.failureReason = "100% packet loss — \(hostname) unreachable"
            }
        }

        return result
    }

    /// Unused for Surfshark because `managesSystemTunnel` is `false`. Kept as
    /// strict no-ops so nothing can ever invoke `scutil --nc start/stop` and
    /// hang or disconnect the user's active VPN.
    func beginConnect(_ target: RouteTarget) async throws {}
    func disconnect() async {}

    // MARK: - Non-blocking POSIX network helpers

    private static func resolveIPv4(host: String, timeout: Double) async -> String? {
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func tryClaim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }

        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce()

            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &res)
                var ipString: String?
                if status == 0, let first = res {
                    var addr = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                        ipString = String(decoding: bytes, as: UTF8.self)
                    }
                    freeaddrinfo(res)
                }
                if gate.tryClaim() {
                    continuation.resume(returning: ipString)
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if gate.tryClaim() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Non-blocking POSIX TCP handshake with hard `poll()` timeout so a
    /// blackholed IP can never hang past `timeout` seconds.
    private static func tcpConnectSeconds(ip: String, port: UInt16, timeout: Double) async -> Double? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = CFAbsoluteTimeGetCurrent()
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { close(fd) }

                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
                    continuation.resume(returning: nil)
                    return
                }

                let rc = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                        connect(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }

                if rc == 0 {
                    continuation.resume(returning: max(0.001, CFAbsoluteTimeGetCurrent() - started))
                    return
                }

                guard errno == EINPROGRESS else {
                    continuation.resume(returning: nil)
                    return
                }

                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let timeoutMs = Int32(max(200, min(timeout * 1000.0, 5000.0)))
                let polled = poll(&pfd, 1, timeoutMs)
                guard polled > 0, (pfd.revents & Int16(POLLOUT)) != 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                var sockErr: Int32 = 0
                var errLen = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &errLen) == 0, sockErr == 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: max(0.001, CFAbsoluteTimeGetCurrent() - started))
            }
        }
    }
}

// MARK: - ExpressVPN

struct ExpressVPNProvider: VPNProvider {

    let kind: ProviderKind = .expressvpn
    let displayName = "ExpressVPN"

    /// `auto` is deliberately absent. It picks a protocol per network, which
    /// makes the protocol column meaningless in a run.
    private static let protocols: [(id: String, title: String, note: String)] = [
        ("lightwayudp", "Lightway UDP",
         "ExpressVPN's own protocol. Fastest of the five, and the one it uses by default."),
        ("lightwaytcp", "Lightway TCP",
         "Same protocol carried over TCP — slower, but usable where UDP is not."),
        ("openvpnudp", "OpenVPN UDP", "The long-standing standard. Quick, and widely recognised."),
        ("openvpntcp", "OpenVPN TCP",
         "Port 443 TCP. Often the most widely carried of the five."),
        ("wireguard", "WireGuard", "Lean and fast."),
    ]

    // MARK: - Locating the client

    static func cliPath() -> String? {
        if FileManager.default.isExecutableFile(atPath: "/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl") {
            return "/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl"
        }
        if let found = RouteProcess.which("expressvpnctl") { return found }
        for path in ["/usr/local/bin/expressvpnctl", "/opt/homebrew/bin/expressvpnctl"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func requireCLI() throws -> String {
        guard let path = Self.cliPath() else {
            throw RouteProcessError.launchFailed(
                "expressvpnctl not found. Install the ExpressVPN client for macOS."
            )
        }
        return path
    }

    /// The CLI refuses to do anything unless the GUI client is running or
    /// background mode has been switched on, so it gets a longer leash.
    private func run(_ args: [String], timeout: Double = 30) async throws -> String {
        if let endpoint = ExpressVPNMCPSettings.endpoint() {
            let tool: String
            let value: String?
            switch args.first {
            case "status": tool = "expressvpn_status"; value = nil
            case "get":
                guard args.count == 2, ["connectionstate", "protocol", "vpnip", "regions"].contains(args[1]) else {
                    throw MCPError.message("Unsupported ExpressVPN read action.")
                }
                tool = "expressvpn_get_" + args[1]; value = nil
            case "set":
                guard args.count == 3, args[1] == "protocol" else { throw MCPError.message("Unsupported ExpressVPN setting.") }
                tool = "expressvpn_set_protocol"; value = args[2]
            case "connect": tool = "expressvpn_connect"; value = args.count > 1 ? args[1] : nil
            case "disconnect": tool = "expressvpn_disconnect"; value = nil
            default: throw MCPError.message("Unsupported ExpressVPN action.")
            }
            // Once MCP is selected, a rejected mutation must never be repeated
            // through another transport: it may already have reached the daemon.
            return try await ExpressVPNMCP(endpoint: endpoint).call(tool, value: value)
        }
        let output = try await RouteProcess.run(requireCLI(), args, timeout: timeout)
        if output.timedOut {
            throw RouteProcessError.timedOut(timeout)
        }
        let text = (output.stdout + "\n" + output.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.exitCode == 0 else {
            throw RouteProcessError.launchFailed("ExpressVPN could not complete the command. Open its app and check the connection.")
        }
        let lowered = text.lowercased()
        if lowered.contains("gui client must be running")
            || lowered.contains("daemon is inactive")
            || lowered.contains("not running") {
            throw RouteProcessError.launchFailed(Self.daemonAdvisory)
        }
        return text
    }

    static let daemonAdvisory =
        "The ExpressVPN background service is not running. Open the ExpressVPN app, "
        + "or switch on background mode so the tunnel can be driven while the app is closed."

    // MARK: - Status

    func probeStatus() async -> ProviderStatus {
        guard let path = Self.cliPath() ?? (ExpressVPNMCPSettings.endpoint() != nil ? "ExpressVPN MCP" : nil) else { return .unavailable }

        let text: String
        do {
            text = try await run(["status"], timeout: 25)
        } catch {
            return ProviderStatus(
                cliPath: path, installed: true, loggedIn: false,
                detail: "Installed, but the background service is not answering.",
                advisory: ExpressVPNMCPSettings.endpoint() != nil
                    ? "MCP is configured but not answering. Check ExpressVPN’s MCP settings or choose Use CLI in Housekeeping."
                    : Self.daemonAdvisory
            )
        }

        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let state = lines.first { !$0.isEmpty } ?? "Unknown"
        let fields = CLIOutput.keyValuePairs(text)
        let location = fields["location"]

        let protocolName = (try? await run(["get", "protocol"], timeout: 15)) ?? ""

        return ProviderStatus(
            cliPath: path,
            installed: true,
            // `status` does not report login, but a daemon that answers is a
            // daemon with an activated account behind it.
            loggedIn: true,
            detail: [ExpressVPNMCPSettings.endpoint() != nil ? "MCP" : "CLI", state, location, protocolName.isEmpty ? nil : protocolName.lowercased()]
                .compactMap { $0 }
                .joined(separator: " · "),
            tunnel: TunnelState.parse(state),
            publicIP: (try? await run(["get", "vpnip"], timeout: 12)) ?? nil,
            advisory: nil
        )
    }

    func tunnelState() async -> TunnelState {
        guard let text = try? await run(["get", "connectionstate"], timeout: 15) else {
            return .unknown
        }
        return TunnelState.parse(text)
    }

    func publicIP() async -> String? {
        guard let text = try? await run(["get", "vpnip"], timeout: 15) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.lowercased() == "unknown" ? nil : value
    }

    // MARK: - Protocols

    func protocolOptions() async -> [ProtocolOption] {
        Self.protocols.map {
            ProtocolOption(id: $0.id, title: $0.title, note: $0.note, ports: [])
        }
    }

    // MARK: - Locations

    func loadLocations() async -> [VPNLocation] {
        guard let text = try? await run(["get", "regions"], timeout: 25) else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "smart" }
            .map { Self.describe(region: $0) }
            .sorted { ($0.country, $0.city, $0.node) < ($1.country, $1.city, $1.node) }
    }

    /// ExpressVPN names regions as slugs — `germany-frankfurt-1`, `uk-london`,
    /// `isle-of-man`. Splitting on the first hyphen would make the country of
    /// `isle-of-man` come out as "Isle", so the country is resolved by longest
    /// match against the ISO region names Foundation already knows.
    static func describe(region: String) -> VPNLocation {
        var slug = region.lowercased()
        var suffix = ""

        // A trailing number distinguishes two nodes in the same city.
        if let dash = slug.lastIndex(of: "-") {
            let tail = slug[slug.index(after: dash)...]
            if !tail.isEmpty, tail.allSatisfy({ $0.isNumber }) {
                suffix = String(tail)
                slug = String(slug[slug.startIndex..<dash])
            }
        }

        if let match = longestCountryMatch(in: slug) {
            let rest = slug.dropFirst(match.slug.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let city = prettyPlace(rest)
            return VPNLocation(
                id: region,
                city: city.isEmpty ? (suffix.isEmpty ? "" : "Node #\(suffix)")
                                   : (suffix.isEmpty ? city : "\(city) #\(suffix)"),
                node: "",
                country: match.name,
                countryCode: match.code,
                continent: "",
                isPremium: false
            )
        }

        // Unknown slug: fall back to reading it as country-then-city.
        let parts = slug.split(separator: "-").map(String.init)
        let country = prettyPlace(parts.first ?? slug)
        let city = prettyPlace(parts.dropFirst().joined(separator: " "))
        return VPNLocation(
            id: region, city: city, node: "",
            country: country, countryCode: "", continent: "", isPremium: false
        )
    }

    private struct CountryMatch {
        let slug: String
        let name: String
        let code: String
    }

    /// Built once from Foundation's own region table, so it covers countries
    /// ExpressVPN has not added yet and never needs maintaining by hand.
    private static let countryIndex: [CountryMatch] = {
        var out: [CountryMatch] = []
        let english = Locale(identifier: "en_US")

        // ExpressVPN's own spellings that Foundation disagrees with.
        let aliases: [String: String] = [
            "usa": "US",
            "uk": "GB",
            "south-korea": "KR",
            "russia": "RU",
            "vietnam": "VN",
            "taiwan": "TW",
            "moldova": "MD",
            "bolivia": "BO",
            "venezuela": "VE",
            "tanzania": "TZ",
            "syria": "SY",
            "laos": "LA",
            "brunei": "BN",
        ]

        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2,
                  let name = english.localizedString(forRegionCode: code),
                  !name.isEmpty
            else { continue }
            out.append(CountryMatch(slug: slugify(name), name: name, code: code))
        }
        for (slug, code) in aliases {
            let name = english.localizedString(forRegionCode: code) ?? slug
            // The alias keeps the provider's own word, so the list reads the
            // way ExpressVPN writes it.
            let display = slug == "usa" ? "United States"
                        : slug == "uk" ? "United Kingdom"
                        : name
            out.append(CountryMatch(slug: slug, name: display, code: code))
        }

        // Longest slug first, so `south-korea` wins over a `south` prefix.
        return out.sorted { $0.slug.count > $1.slug.count }
    }()

    private static func longestCountryMatch(in slug: String) -> CountryMatch? {
        for candidate in countryIndex {
            if slug == candidate.slug { return candidate }
            if slug.hasPrefix(candidate.slug + "-") { return candidate }
        }
        return nil
    }

    private static func slugify(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: ",", with: "")
    }

    private static func prettyPlace(_ slug: String) -> String {
        guard !slug.isEmpty else { return "" }
        let cleaned = slug.replacingOccurrences(of: "-", with: " ")
        return cleaned.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - Connecting

    func prepare(_ target: RouteTarget) async throws {
        _ = try await run(["set", "protocol", target.proto], timeout: 20)
    }

    func beginConnect(_ target: RouteTarget) async throws {
        let text = try await run(["connect", target.identifier], timeout: 30)
        let lowered = text.lowercased()
        if lowered.contains("error") || lowered.contains("failed") {
            throw RouteProcessError.launchFailed(
                text.split(separator: "\n").first.map(String.init) ?? "Connect was refused."
            )
        }
    }

    func disconnect() async {
        _ = try? await run(["disconnect"], timeout: 25)
    }
}
