// Housekeeping — the one-time privileged helper
//
// macOS asks for an administrator password every time a program wants to touch
// something it does not own: a root-owned VPN daemon, a network service in
// /Library/Preferences/SystemConfiguration, a launch daemon. Asking once is
// reasonable. Asking on every button press is not, and it is the single most
// common complaint about this app.
//
// So the password is asked once, and what it buys is a launch daemon: this same
// signed binary, started by launchd as root with `--privileged-helper`, listening
// on a Unix socket. The app sends it a small, fixed vocabulary of requests —
// never a shell command string. The helper checks that the caller is the user who
// installed it, then performs exactly one of those operations.
//
// The allow-list is the security model. Nothing here can run arbitrary text: the
// VPN service name is matched against the system's own configuration before it is
// removed, a process id is signalled directly, and a path is only chowned when it
// sits inside a real home folder.

import Foundation
import Darwin
import Security

// MARK: - Wire types

/// The complete set of things the helper will do. Adding a case is a deliberate
/// decision about what root access this app is allowed to have.
enum HelperCommand: String, Codable {
    case ping
    case stopVPN
    case killPID
    case removeVPNService
    case resetNetwork
    case setDNS
    case bootoutLabel
    case chownUser
}

struct HelperRequest: Codable {
    var command: HelperCommand
    var name: String?
    var pid: Int32?
    var signal: Int32?
    var label: String?
    var path: String?
    var servers: [String]?
}

struct HelperReply: Codable {
    var ok: Bool
    var message: String
}

enum PrivilegedHelperError: LocalizedError {
    case notInstalled
    case notInApplications
    case refused(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The one-time helper is not installed yet."
        case .notInApplications:
            return "Move Housekeeper to your Applications folder first, then install its helper. The helper has to point at a copy of the app that will still be there after the next restart."
        case .refused(let why):
            return why
        case .installFailed(let why):
            return why
        }
    }
}

// MARK: - Client

/// The app's side of the socket. Every call is a short round trip; no state is
/// kept open between them.
@MainActor
final class PrivilegedHelper: ObservableObject {

    static let shared = PrivilegedHelper()

    nonisolated static let launchdLabel = "com.housekeeping.helper"
    nonisolated static let daemonPlistPath = "/Library/LaunchDaemons/com.housekeeping.helper.plist"
    nonisolated static let socketPath = "/var/run/com.housekeeping.helper.sock"
    nonisolated static let ownerPath = "/var/db/com.housekeeping.helper.owner"

    /// Root's own copy of the helper. It must not live inside the app bundle:
    /// `/Applications/Housekeeper.app` belongs to the logged-in user, so a daemon
    /// pointed at it would let anything running as that user replace the binary
    /// and inherit root at the next login.
    nonisolated static let helperBinaryPath = "/Library/PrivilegedHelperTools/com.housekeeping.helper"

    /// The code-signing requirement of the app that is allowed to talk to the
    /// helper, written by root at install time. Checking the caller's signature
    /// is what stops any other program running as the same user from borrowing
    /// root through the socket.
    nonisolated static let clientRequirementPath = "/var/db/com.housekeeping.helper.clientreq"

    /// Last known reachability. Refreshed by `refresh()`; callers that need a
    /// privileged operation should try it and fall back, not gate on this.
    @Published private(set) var isAvailable = false
    @Published private(set) var isInstalling = false
    @Published private(set) var lastMessage: String?

    private init() {}

    var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: Self.daemonPlistPath),
              FileManager.default.fileExists(atPath: Self.ownerPath),
              FileManager.default.fileExists(atPath: Self.helperBinaryPath),
              let data = FileManager.default.contents(atPath: Self.daemonPlistPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(Self.helperBinaryPath)
    }

    /// True when an older build installed the helper inside the app bundle. That
    /// layout is the hole this version closes; the app reports it and offers the
    /// one-time setup again instead of using it.
    var isLegacyInstall: Bool {
        guard FileManager.default.fileExists(atPath: Self.daemonPlistPath),
              let data = FileManager.default.contents(atPath: Self.daemonPlistPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        return !text.contains(Self.helperBinaryPath)
    }

    func refresh() {
        isAvailable = (try? call(.init(command: .ping))) != nil
    }

    /// Synchronous by design: it is used from `applicationWillTerminate`, where
    /// there is no run loop left to await on.
    func call(_ request: HelperRequest, timeout: Double = 30) throws -> HelperReply {
        guard let reply = Self.send(request, timeout: timeout) else {
            throw PrivilegedHelperError.notInstalled
        }
        guard reply.ok else { throw PrivilegedHelperError.refused(reply.message) }
        lastMessage = reply.message
        return reply
    }

    /// Reads the app's own designated requirement. `codesign -d -r-` prints the
    /// stable rule macOS uses to recognise this exact app across rebuilds.
    nonisolated static func designatedRequirement(forApp url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "-r-", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("designated =>") else { continue }
            let value = trimmed.dropFirst("designated =>".count)
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Installs the daemon. One administrator prompt, once per Mac — not once
    /// per action.
    func install() async throws {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            throw PrivilegedHelperError.installFailed("This copy of Housekeeper has no executable path.")
        }
        guard executable.hasPrefix("/Applications/") else {
            throw PrivilegedHelperError.notInApplications
        }
        isInstalling = true
        defer { isInstalling = false }

        let uid = String(getuid())
        guard let requirement = Self.designatedRequirement(forApp: Bundle.main.bundleURL) else {
            throw PrivilegedHelperError.installFailed(
                "Housekeeper could not read its own code signature, so the helper would not know which app to trust. Reinstall Housekeeper from its GitHub release, then set the helper up again."
            )
        }
        let encodedRequirement = Data(requirement.utf8).base64EncodedString()

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(Self.launchdLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(Self.helperBinaryPath)</string>
                <string>--privileged-helper</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
            <key>ThrottleInterval</key><integer>5</integer>
            <key>ProcessType</key><string>Background</string>
            <key>StandardOutPath</key><string>/var/log/housekeeper-helper.log</string>
            <key>StandardErrorPath</key><string>/var/log/housekeeper-helper.log</string>
        </dict>
        </plist>
        """

        let script = """
        #!/bin/bash
        set -e
        /bin/launchctl bootout system/\(Self.launchdLabel) >/dev/null 2>&1 || true
        /bin/mkdir -p "/Library/PrivilegedHelperTools"
        /usr/bin/install -o root -g wheel -m 755 "\(executable)" "\(Self.helperBinaryPath)"
        /bin/cat > "\(Self.daemonPlistPath)" <<'HOUSEKEEPER_PLIST'
        \(plist)
        HOUSEKEEPER_PLIST
        /usr/sbin/chown root:wheel "\(Self.daemonPlistPath)"
        /bin/chmod 644 "\(Self.daemonPlistPath)"
        /bin/echo \(uid) > "\(Self.ownerPath)"
        /usr/sbin/chown root:wheel "\(Self.ownerPath)"
        /bin/chmod 600 "\(Self.ownerPath)"
        /bin/echo \(encodedRequirement) | /usr/bin/base64 -D > "\(Self.clientRequirementPath)"
        /usr/sbin/chown root:wheel "\(Self.clientRequirementPath)"
        /bin/chmod 600 "\(Self.clientRequirementPath)"
        /bin/launchctl bootstrap system "\(Self.daemonPlistPath)"
        /bin/launchctl enable system/\(Self.launchdLabel) >/dev/null 2>&1 || true
        """

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("housekeeper-helper-install-\(UUID().uuidString).sh")
        try script.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let apple = "do shell script \"/bin/bash \(temp.path)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", apple]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let raw = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw PrivilegedHelperError.installFailed(
                raw.isEmpty ? "The helper was not installed. Nothing was changed." : raw
            )
        }

        // launchd needs a moment to accept the first connection.
        for _ in 0..<40 {
            if let reply = Self.send(.init(command: .ping), timeout: 2), reply.ok {
                isAvailable = true
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw PrivilegedHelperError.installFailed(
            "The helper was installed but did not answer. Its log is at /var/log/housekeeper-helper.log."
        )
    }

    /// Removes the daemon. Used by the uninstall path and by the settings screen.
    func uninstall() throws {
        let script = """
        #!/bin/bash
        /bin/launchctl bootout system/\( Self.launchdLabel) >/dev/null 2>&1 || true
        /bin/rm -f "\(Self.daemonPlistPath)" "\(Self.ownerPath)" "\(Self.socketPath)" "\(Self.helperBinaryPath)" "\(Self.clientRequirementPath)"
        """
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("housekeeper-helper-remove-\(UUID().uuidString).sh")
        try script.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"/bin/bash \(temp.path)\" with administrator privileges"]
        try process.run()
        process.waitUntilExit()
        isAvailable = false
    }

    /// The synchronous transport, shared by the client and by nothing else.
    nonisolated static func send(_ request: HelperRequest, timeout: Double) -> HelperReply? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        guard let payload = try? JSONEncoder().encode(request) else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                connect(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        var line = payload
        line.append(0x0A)
        let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == line.count else { return nil }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 262_144 {
            let read = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard read > 0 else { break }
            buffer.append(contentsOf: chunk[0..<read])
            if buffer.contains(0x0A) { break }
        }
        guard !buffer.isEmpty else { return nil }
        return try? JSONDecoder().decode(HelperReply.self, from: buffer)
    }
}

// MARK: - Server

/// Runs as root under launchd. It is deliberately small: one socket, one
/// request at a time, a fixed vocabulary.
enum PrivilegedHelperServer {

    static func run() -> Never {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("housekeeper-helper: must run as root\n".utf8))
            exit(2)
        }
        signal(SIGPIPE, SIG_IGN)
        unlink(PrivilegedHelper.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { exit(3) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(PrivilegedHelper.socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { exit(4) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                bind(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { exit(5) }
        chmod(PrivilegedHelper.socketPath, 0o660)
        if let group = getgrnam("staff") {
            chown(PrivilegedHelper.socketPath, 0, group.pointee.gr_gid)
        }
        guard listen(fd, 16) == 0 else { exit(6) }

        log("helper started on \(PrivilegedHelper.socketPath)")

        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async {
                handle(client: client)
                close(client)
            }
        }
    }

    private static func handle(client: Int32) {
        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(client, &uid, &gid) == 0 else {
            reply(client, ok: false, "The helper could not identify the calling program.")
            return
        }
        guard uid == ownerUID() else {
            reply(client, ok: false, "Only the user who installed the helper can use it.")
            log("refused uid \(uid) (owner \(ownerUID()))")
            return
        }
        guard callerIsHousekeeper(client) else {
            reply(client, ok: false, "This helper only answers the Housekeeper app that installed it.")
            log("refused a caller that is not signed as Housekeeper")
            return
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 262_144 {
            let read = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            guard read > 0 else { break }
            buffer.append(contentsOf: chunk[0..<read])
            if buffer.contains(0x0A) { break }
        }
        guard let request = try? JSONDecoder().decode(HelperRequest.self, from: buffer) else {
            reply(client, ok: false, "The helper could not read that request.")
            return
        }
        let result = execute(request)
        reply(client, ok: result.ok, result.message)
    }

    private static func ownerUID() -> uid_t {
        guard let text = try? String(contentsOfFile: PrivilegedHelper.ownerPath, encoding: .utf8),
              let value = uid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 501
        }
        return value
    }

    /// Read once. The file is root-owned, so only root can widen who may call.
    private static let allowedClient: SecRequirement? = {
        guard let text = try? String(contentsOfFile: PrivilegedHelper.clientRequirementPath,
                                      encoding: .utf8) else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }()

    /// Confirms that the process on the other end is the signed Housekeeper app,
    /// not merely something running as the same user.
    private static func callerIsHousekeeper(_ client: Int32) -> Bool {
        guard let requirement = allowedClient else { return false }

        // Darwin exposes the peer's process id on a Unix socket.
        var pid = pid_t(0)
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let localPeerPID: Int32 = 0x002
        guard getsockopt(client, 0, localPeerPID, &pid, &length) == 0, pid > 0 else {
            return false
        }

        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    // MARK: Operations

    private static func execute(_ request: HelperRequest) -> HelperReply {
        switch request.command {
        case .ping:
            return .init(ok: true, message: "ready")

        case .stopVPN:
            guard let name = request.name, isSafeName(name) else {
                return .init(ok: false, message: "That VPN service name is not valid.")
            }
            let first = shell("/usr/sbin/scutil", ["--nc", "stop", name])
            let disabled = shell("/usr/sbin/scutil", ["--nc", "disablevpn", name])
            return .init(
                ok: first.status == 0 || disabled.status == 0,
                message: first.combined.isEmpty ? "Asked macOS to stop \(name)." : first.combined
            )

        case .killPID:
            guard let pid = request.pid, pid > 1, pid != getpid() else {
                return .init(ok: false, message: "That process id is not valid.")
            }
            let signal = request.signal == SIGKILL ? SIGKILL : SIGTERM
            let outcome = kill(pid, signal)
            if outcome == 0 {
                return .init(ok: true, message: "Sent signal \(signal) to PID \(pid).")
            }
            return .init(ok: false, message: "macOS would not signal PID \(pid) (errno \(errno)).")

        case .removeVPNService:
            guard let name = request.name, isSafeName(name) else {
                return .init(ok: false, message: "That VPN service name is not valid.")
            }
            return removeVPNService(named: name)

        case .resetNetwork:
            return resetNetwork()

        case .setDNS:
            guard let name = request.name, isSafeName(name) else {
                return .init(ok: false, message: "That network service name is not valid.")
            }
            let servers = request.servers ?? []
            guard servers.count <= 4,
                  servers.allSatisfy({ isIPLiteral($0) }) else {
                return .init(ok: false, message: "That is not a valid DNS server address.")
            }
            let arguments = ["-setdnsservers", name] + (servers.isEmpty ? ["empty"] : servers)
            let applied = shell("/usr/sbin/networksetup", arguments)
            _ = shell("/usr/bin/dscacheutil", ["-flushcache"])
            _ = shell("/usr/bin/killall", ["-HUP", "mDNSResponder"])
            if applied.status != 0 {
                return .init(ok: false, message: applied.combined.isEmpty
                    ? "macOS would not change the DNS servers for \(name)."
                    : applied.combined)
            }
            let readback = shell("/usr/sbin/networksetup", ["-getdnsservers", name]).combined
            if !servers.isEmpty, !readback.contains(servers[0]) {
                return .init(ok: false, message: "The change was accepted but did not stick. Currently: \(readback)")
            }
            return .init(ok: true, message: servers.isEmpty
                ? "DNS for \(name) is back to the router's own."
                : "DNS for \(name) is now \(servers.joined(separator: ", ")).")

        case .bootoutLabel:
            guard let label = request.label, isSafeName(label), label.hasPrefix("com.") || label.hasPrefix("org.") else {
                return .init(ok: false, message: "That label is not valid.")
            }
            let system = shell("/bin/launchctl", ["bootout", "system/\(label)"])
            let user = shell("/bin/launchctl", ["bootout", "gui/\(ownerUID())/\(label)"])
            return .init(
                ok: system.status == 0 || user.status == 0,
                message: system.status == 0 || user.status == 0
                    ? "Stopped \(label) until the next login."
                    : "\(label) was not running, or macOS would not stop it."
            )

        case .chownUser:
            guard let path = request.path, path.hasPrefix("/Users/"), !path.contains("..") else {
                return .init(ok: false, message: "Only a path inside a home folder can be given back to its owner.")
            }
            let owner = "\(ownerUID())"
            let gid = String(gidFor(uid: ownerUID()))
            let result = shell("/usr/sbin/chown", ["-R", "\(owner):\(gid)", path])
            return .init(ok: result.status == 0, message: result.status == 0
                ? "Gave \(path) back to its owner."
                : "macOS would not change the owner of \(path).")
        }
    }

    /// Removes a VPN service from the system's network configuration.
    ///
    /// `networksetup -removenetworkservice` refuses when the service is the only
    /// one on its port — which a VPN service always is, because the tunnel is its
    /// own port. That refusal is the "it is the only one left" message. The
    /// configuration itself lives in a plain plist, so the service is removed
    /// there, after checking that the entry really is a VPN and really has this
    /// name, with a dated backup beside the original.
    private static func removeVPNService(named name: String) -> HelperReply {
        let path = "/Library/Preferences/SystemConfiguration/preferences.plist"
        guard let data = FileManager.default.contents(atPath: path),
              var root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              var services = root["NetworkServices"] as? [String: Any] else {
            return .init(ok: false, message: "macOS network preferences could not be read.")
        }

        var target: (key: String, uuid: String)?
        for (key, value) in services {
            guard let entry = value as? [String: Any],
                  let iface = entry["Interface"] as? [String: Any],
                  (iface["Type"] as? String) == "VPN",
                  let userDefined = entry["UserDefinedName"] as? String,
                  userDefined == name else { continue }
            target = (key, key)
        }
        guard let target else {
            return .init(ok: false, message: "No VPN service named “\(name)” is installed. Nothing was changed.")
        }

        services.removeValue(forKey: target.key)
        root["NetworkServices"] = services
        if let order = root["NetworkServiceOrder"] as? [String] {
            root["NetworkServiceOrder"] = order.filter { $0 != target.key }
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = "\(path).housekeeper-backup-\(stamp)"
        try? FileManager.default.copyItem(atPath: path, toPath: backup)

        guard let written = try? PropertyListSerialization.data(
            fromPropertyList: root, format: .xml, options: 0) else {
            return .init(ok: false, message: "The new network preferences could not be built. Nothing was changed.")
        }
        do {
            try written.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return .init(ok: false, message: "The network preferences are locked: \(error.localizedDescription)")
        }
        chown(path, 0, 0)
        chmod(path, 0o644)

        // configd holds the old configuration in memory, and the menu bar reads
        // it from there. A hang-up makes it read the file again.
        _ = shell("/usr/bin/killall", ["-HUP", "configd"])
        Thread.sleep(forTimeInterval: 0.6)
        let listed = shell("/usr/sbin/networksetup", ["-listallnetworkservices"]).combined
        if listed.contains(name) {
            return .init(ok: false, message: "The service was removed from the file but is still cached. Restart the Mac once; the backup is at \(backup).")
        }
        return .init(ok: true, message: "Removed “\(name)” from macOS Network Settings. Backup: \(backup)")
    }

    /// Puts the machine back on a plain, physical connection: every VPN service
    /// stopped, DNS and routes cleared, and the physical service re-armed if the
    /// default route did not come back on its own.
    private static func resetNetwork() -> HelperReply {
        var notes: [String] = []

        let services = configuredVPNNames()
        for name in services {
            _ = shell("/usr/sbin/scutil", ["--nc", "stop", name])
            _ = shell("/usr/sbin/scutil", ["--nc", "disablevpn", name])
        }
        if !services.isEmpty {
            notes.append("stopped \(services.count) VPN service\(services.count == 1 ? "" : "s")")
        }

        _ = shell("/usr/bin/dscacheutil", ["-flushcache"])
        _ = shell("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        _ = shell("/usr/bin/killall", ["-HUP", "configd"])
        _ = shell("/sbin/route", ["-n", "flush"])
        Thread.sleep(forTimeInterval: 0.8)

        // `route flush` takes the default route with it. macOS rebuilds it from
        // the interface, but a tunnel that was holding it can leave nothing
        // behind, which looks like "the internet is gone". Bouncing the physical
        // service asks for a fresh DHCP lease and a fresh default route.
        if !hasDefaultRoute() {
            for name in physicalServiceNames() {
                _ = shell("/usr/sbin/networksetup", ["-setnetworkserviceenabled", name, "off"])
                _ = shell("/usr/sbin/networksetup", ["-setnetworkserviceenabled", name, "on"])
                Thread.sleep(forTimeInterval: 1.2)
                if hasDefaultRoute() {
                    notes.append("re-armed \(name)")
                    break
                }
            }
        }

        if hasDefaultRoute() {
            notes.append("default route restored")
            return .init(ok: true, message: notes.joined(separator: ", ").capitalizedFirst)
        }
        return .init(
            ok: false,
            message: "VPNs are stopped, but this Mac still has no default route. Turn Wi-Fi off and on once; if that does not do it, restart."
        )
    }

    private static func configuredVPNNames() -> [String] {
        let path = "/Library/Preferences/SystemConfiguration/preferences.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let services = root["NetworkServices"] as? [String: Any] else { return [] }
        return services.values.compactMap { value in
            guard let entry = value as? [String: Any],
                  let iface = entry["Interface"] as? [String: Any],
                  (iface["Type"] as? String) == "VPN" else { return nil }
            return entry["UserDefinedName"] as? String
        }
    }

    private static func physicalServiceNames() -> [String] {
        let path = "/Library/Preferences/SystemConfiguration/preferences.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let services = root["NetworkServices"] as? [String: Any] else { return [] }
        // Wi-Fi first: on a laptop it is the service that usually carries traffic.
        return services.values.compactMap { value -> String? in
            guard let entry = value as? [String: Any],
                  let iface = entry["Interface"] as? [String: Any],
                  (iface["Type"] as? String) != "VPN" else { return nil }
            return entry["UserDefinedName"] as? String
        }.sorted { lhs, rhs in
            (lhs.contains("Wi-Fi") ? 0 : 1) < (rhs.contains("Wi-Fi") ? 0 : 1)
        }
    }

    private static func hasDefaultRoute() -> Bool {
        let output = shell("/usr/sbin/netstat", ["-rn", "-f", "inet"]).combined
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 4, parts[0] == "default" else { continue }
            let iface = String(parts[parts.count - 1])
            if !iface.hasPrefix("utun") && !iface.hasPrefix("tun") && !iface.hasPrefix("ipsec") {
                return true
            }
        }
        return false
    }

    // MARK: Small helpers

    /// IPv4 or IPv6 literal only. A hostname here would be a way to point this
    /// Mac's resolver at something that is not a resolver at all.
    private static func isIPLiteral(_ value: String) -> Bool {
        guard value.count <= 45, !value.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        var address = in6_addr()
        if inet_pton(AF_INET, value, &address) == 1 { return true }
        if inet_pton(AF_INET6, value, &address) == 1 { return true }
        return false
    }

    private static func isSafeName(_ value: String) -> Bool {
        !value.isEmpty && value.count < 200
            && !value.contains("\n") && !value.contains("\r") && !value.contains("\0")
            && !value.contains("/")
    }

    private static func gidFor(uid: uid_t) -> gid_t {
        guard let entry = getpwuid(uid) else { return 20 }
        return entry.pointee.pw_gid
    }

    private struct ShellResult {
        var status: Int32
        var combined: String
    }

    private static func shell(_ path: String, _ arguments: [String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, combined: error.localizedDescription)
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ShellResult(status: process.terminationStatus, combined: text)
    }

    private static func reply(_ client: Int32, ok: Bool, _ message: String) {
        guard let data = try? JSONEncoder().encode(HelperReply(ok: ok, message: message)) else { return }
        var line = data
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    private static func log(_ message: String) {
        let line = "\(Date()): \(message)\n"
        let path = "/var/log/housekeeper-helper.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
