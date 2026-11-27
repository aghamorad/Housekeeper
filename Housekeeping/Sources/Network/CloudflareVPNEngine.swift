// Housekeeping — Cloudflare Clean VPN & AmneziaWG WARP Engine
//
// Two real, self-contained VPN config paths for Iranian networks:
// 1. AmneziaWG WARP: generates a local Curve25519 keypair via CryptoKit,
//    registers with Cloudflare WARP (no account/token needed, zero Worker abuse
//    flag risk), and builds an AmneziaWG 1.5 / 3.1 .conf with junk packets.
// 2. Cloudflare Token & Clean IPs: verifies a Cloudflare API token (stored in
//    macOS Keychain), deploys or deletes a private VLESS-over-WS Worker using
//    a neutral name, scans real Cloudflare IPv4 edge ranges for clean/fast IPs
//    on your current ISP, and builds vless:// + TLS Fragment JSON configs.

import AppKit
import CoreImage
import CryptoKit
import Foundation
import Network
import Security

@MainActor
final class CloudflareVPNEngine: ObservableObject {
    // MARK: - Shared UI State
    @Published var selectedTab: CloudflareVPNTab = .warp
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var qrPayload: String?
    @Published var qrTitle: String = ""

    // MARK: - Mode 1: AmneziaWG WARP State
    @Published var selectedWarpEndpoint: String = WarpEndpointCandidate.curated[0].endpointString
    @Published var customWarpEndpoint: String = ""
    @Published var useCustomWarpEndpoint: Bool = false
    @Published var warpJunkPreset: WarpJunkPreset = .light
    @Published var warpJc: Int = 3
    @Published var warpJmin: Int = 1
    @Published var warpJmax: Int = 3
    @Published var warpMTU: Int = 1280
    @Published var warpKeepalive: Int = 25
    @Published var warpUse15: Bool = true
    /// Full QUIC Initial disguise packet (makes the opening UDP handshake look like HTTP/3 QUIC to DPI).
    static let defaultQuicI1 = "<b 0xc70000000108ce1bf31eec7d93360000449e227e4596ed7f75c4d35ce31880b4133107c822c6355b51f0d7c1bba96d5c210a48aca01885fed0871cfc37d59137d73b506dc013bb4a13c060ca5b04b7ae215af71e37d6e8ff1db235f9fe0c25cb8b492471054a7c8d0d6077d430d07f6e87a8699287f6e69f54263c7334a8e144a29851429bf2e350e519445172d36953e96085110ce1fb641e5efad42c0feb4711ece959b72cc4d6f3c1e83251adb572b921534f6ac4b10927167f41fe50040a75acef62f45bded67c0b45b9d655ce374589cad6f568b8475b2e8921ff98628f86ff2eb5bcce6f3ddb7dc89e37c5b5e78ddc8d93a58896e530b5f9f1448ab3b7a1d1f24a63bf981634f6183a21af310ffa52e9ddf5521561760288669de01a5f2f1a4f922e68d0592026bbe4329b654d4f5d6ace4f6a23b8560b720a5350691c0037b10acfac9726add44e7d3e880ee6f3b0d6429ff33655c297fee786bb5ac032e48d2062cd45e305e6d8d8b82bfbf0fdbc5ec09943d1ad02b0b5868ac4b24bb10255196be883562c35a713002014016b8cc5224768b3d330016cf8ed9300fe6bf39b4b19b3667cddc6e7c7ebe4437a58862606a2a66bd4184b09ab9d2cd3d3faed4d2ab71dd821422a9540c4c5fa2a9b2e6693d411a22854a8e541ed930796521f03a54254074bc4c5bca152a1723260e7d70a24d49720acc544b41359cfc252385bda7de7d05878ac0ea0343c77715e145160e6562161dfe2024846dfda3ce99068817a2418e66e4f37dea40a21251c8a034f83145071d93baadf050ca0f95dc9ce2338fb082d64fbc8faba905cec66e65c0e1f9b003c32c943381282d4ab09bef9b6813ff3ff5118623d2617867e25f0601df583c3ac51bc6303f79e68d8f8de4b8363ec9c7728b3ec5fcd5274edfca2a42f2727aa223c557afb33f5bea4f64aeb252c0150ed734d4d8eccb257824e8e090f65029a3a042a51e5cc8767408ae07d55da8507e4d009ae72c47ddb138df3cab6cc023df2532f88fb5a4c4bd917fafde0f3134be09231c389c70bc55cb95a779615e8e0a76a2b4d943aabfde0e394c985c0cb0376930f92c5b6998ef49ff4a13652b787503f55c4e3d8eebd6e1bc6db3a6d405d8405bd7a8db7cefc64d16e0d105a468f3d33d29e5744a24c4ac43ce0eb1bf6b559aed520b91108cda2de6e2c4f14bc4f4dc58712580e07d217c8cca1aaf7ac04bab3e7b1008b966f1ed4fba3fd93a0a9d3a27127e7aa587fbcc60d548300146bdc126982a58ff5342fc41a43f83a3d2722a26645bc961894e339b953e78ab395ff2fb854247ad06d446cc2944a1aefb90573115dc198f5c1efbc22bc6d7a74e41e666a643d5f85f57fde81b87ceff95353d22ae8bab11684180dd142642894d8dc34e402f802c2fd4a73508ca99124e428d67437c871dd96e506ffc39c0fc401f666b437adca41fd563cbcfd0fa22fbbf8112979c4e677fb533d981745cceed0fe96da6cc0593c430bbb71bcbf924f70b4547b0bb4d41c94a09a9ef1147935a5c75bb2f721fbd24ea6a9f5c9331187490ffa6d4e34e6bb30c2c54a0344724f01088fb2751a486f425362741664efb287bce66c4a544c96fa8b124d3c6b9eaca170c0b530799a6e878a57f402eb0016cf2689d55c76b2a91285e2273763f3afc5bc9398273f5338a06d>"
    @Published var warpI1: String = CloudflareVPNEngine.defaultQuicI1
    @Published var warpUse3x: Bool = true
    @Published var warpS3: Int = 0
    @Published var warpS4: Int = 0
    @Published var warpRegisterOnline: Bool = true
    @Published var isGeneratingWarp: Bool = false
    @Published var generatedWarpConfig: String = ""
    @Published var warpRegisteredSuccessfully: Bool = false

    // MARK: - Mode 2: Cloudflare Token & Clean IP State
    @Published var tokenInput: String = ""
    @Published var hasSavedToken: Bool = false
    @Published var isVerifyingToken: Bool = false
    @Published var account: CloudflareAccountSummary?
    @Published var existingWorkers: [CloudflareWorkerScript] = []
    @Published var workerNameInput: String = ""
    @Published var workerHost: String = ""
    @Published var workerUUID: String = UUID().uuidString.lowercased()
    @Published var tlsPort: Int = 443
    @Published var scanDepth: CleanIPScanDepth = .standard
    @Published var fragmentPreset: FragmentPreset = .mciLight
    @Published var isDeployingWorker: Bool = false
    @Published var isScanningIPs: Bool = false
    @Published var scanProgress: Double = 0
    @Published var scanStatusText: String = ""
    @Published var cleanIPResults: [CleanIPResult] = []

    private var scanTask: Task<Void, Never>?

    private static let keychainService = "com.housekeeping.cloudflare-api-token"
    private static let keychainAccount = "default"
    private static let warpPeerPublicKey = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    private static let warpRegURL = URL(string: "https://api.cloudflareclient.com/v0a4005/reg")!

    private enum DefaultsKeys {
        static let workerHost = "housekeeper.cfvpn.workerHost"
        static let workerUUID = "housekeeper.cfvpn.workerUUID"
    }

    init() {
        workerNameInput = Self.generateNeutralWorkerName()
        workerHost = UserDefaults.standard.string(forKey: DefaultsKeys.workerHost) ?? ""
        if let savedUUID = UserDefaults.standard.string(forKey: DefaultsKeys.workerUUID), !savedUUID.isEmpty {
            workerUUID = savedUUID
        }
        if let stored = Self.loadTokenFromKeychain(), !stored.isEmpty {
            hasSavedToken = true
            tokenInput = stored
        }
    }

    func persistWorkerSettings() {
        UserDefaults.standard.set(workerHost.trimmingCharacters(in: .whitespacesAndNewlines), forKey: DefaultsKeys.workerHost)
        UserDefaults.standard.set(workerUUID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: DefaultsKeys.workerUUID)
    }

    // MARK: - Neutral Name Generator (avoids Cloudflare abuse-keyword triggers)

    static func generateNeutralWorkerName() -> String {
        let adjectives = ["amber", "cedar", "maple", "linen", "pebble", "harbor", "meadow", "willow", "quartz", "copper"]
        let nouns = ["notes", "journal", "studio", "garden", "lantern", "archive", "atelier", "gallery", "ledger", "canvas"]
        let adj = adjectives.randomElement() ?? "cedar"
        let noun = nouns.randomElement() ?? "notes"
        let num = Int.random(in: 10...99)
        return "\(adj)-\(noun)-\(num)"
    }

    // MARK: - Keychain Storage for Cloudflare Token

    static func sanitizeToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            .replacingOccurrences(of: "Bearer ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func saveTokenToKeychain(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func loadTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func forgetSavedToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        tokenInput = ""
        hasSavedToken = false
        account = nil
        existingWorkers = []
        statusMessage = "Cloudflare token removed from Keychain."
        errorMessage = nil
    }

    func pasteTokenFromClipboard() {
        if let raw = NSPasteboard.general.string(forType: .string) {
            tokenInput = Self.sanitizeToken(raw)
            statusMessage = "Pasted token from clipboard."
            errorMessage = nil
        } else {
            errorMessage = "Clipboard does not contain text."
        }
    }

    // MARK: - Mode 1: Generate AmneziaWG WARP Config

    func generateWarpConfig() {
        guard !isGeneratingWarp else { return }
        let endpoint = (useCustomWarpEndpoint ? customWarpEndpoint : selectedWarpEndpoint)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidEndpoint(endpoint) else {
            errorMessage = "Enter a valid WARP endpoint as IP:port or hostname:port (example: 162.159.193.1:2408)."
            return
        }

        isGeneratingWarp = true
        errorMessage = nil
        statusMessage = warpRegisterOnline ? "Generating Curve25519 keys and registering with Cloudflare WARP…" : "Generating local Curve25519 keys…"

        let junk = warpJunkPreset == .custom
            ? (jc: max(1, min(128, warpJc)), jmin: max(1, min(1279, warpJmin)), jmax: max(max(1, warpJmin), min(1280, warpJmax)))
            : warpJunkPreset.defaults
        let mtu = max(576, min(1500, warpMTU))
        let keepalive = max(0, min(120, warpKeepalive))
        let use15 = warpUse15
        let i1 = warpI1.trimmingCharacters(in: .whitespacesAndNewlines)
        let use3x = warpUse3x
        let s3 = max(0, min(64, warpS3))
        let s4 = max(0, min(64, warpS4))
        let registerOnline = warpRegisterOnline

        Task {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let privB64 = privateKey.rawRepresentation.base64EncodedString()
            let pubB64 = privateKey.publicKey.rawRepresentation.base64EncodedString()

            var v4Address = "172.16.0.2"
            var peerKey = Self.warpPeerPublicKey
            var registered = false
            var regWarning: String?

            if registerOnline {
                do {
                    let result = try await Self.registerWarpPublicKey(pubB64)
                    v4Address = result.v4
                    peerKey = result.peerKey
                    registered = true
                } catch {
                    regWarning = "Could not reach Cloudflare WARP registration right now (\(error.localizedDescription)). A local draft config was created, but WARP only accepts registered keys — retry once while online."
                }
            }

            let conf = Self.buildAmneziaWarpConf(
                privB64: privB64,
                v4Address: v4Address,
                peerKey: peerKey,
                endpoint: endpoint,
                mtu: mtu,
                keepalive: keepalive,
                jc: junk.jc,
                jmin: junk.jmin,
                jmax: junk.jmax,
                use15: use15,
                i1: i1,
                use3x: use3x,
                s3: s3,
                s4: s4
            )

            self.generatedWarpConfig = conf
            self.warpRegisteredSuccessfully = registered
            self.isGeneratingWarp = false
            if let regWarning {
                self.errorMessage = regWarning
                self.statusMessage = nil
            } else if registered {
                self.statusMessage = "WARP key registered and ready. Save .conf or copy into AmneziaVPN."
                self.errorMessage = nil
            } else {
                self.statusMessage = "Local AmneziaWG draft generated (unregistered)."
                self.errorMessage = nil
            }
        }
    }

    static func isValidEndpoint(_ endpoint: String) -> Bool {
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2,
              !parts[0].isEmpty,
              let port = Int(parts[1]),
              (1...65535).contains(port) else {
            return false
        }
        return true
    }

    private static func registerWarpPublicKey(_ pubB64: String) async throws -> (v4: String, peerKey: String) {
        var req = URLRequest(url: warpRegURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("okhttp/3.12.1", forHTTPHeaderField: "User-Agent")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: Any] = [
            "key": pubB64,
            "install_id": "",
            "fcm_token": "",
            "tos": iso.string(from: Date()),
            "model": "PC",
            "serial_number": "",
            "locale": "en_US"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "CloudflareWARP", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = json["config"] as? [String: Any] else {
            throw NSError(domain: "CloudflareWARP", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing config in WARP response"])
        }
        let iface = config["interface"] as? [String: Any]
        let addresses = iface?["addresses"] as? [String: Any]
        let v4 = (addresses?["v4"] as? String) ?? "172.16.0.2"
        let peers = config["peers"] as? [[String: Any]]
        let peerKey = (peers?.first?["public_key"] as? String) ?? warpPeerPublicKey
        return (v4, peerKey)
    }

    static func buildAmneziaWarpConf(
        privB64: String,
        v4Address: String,
        peerKey: String,
        endpoint: String,
        mtu: Int,
        keepalive: Int,
        jc: Int,
        jmin: Int,
        jmax: Int,
        use15: Bool,
        i1: String,
        use3x: Bool,
        s3: Int,
        s4: Int
    ) -> String {
        var lines: [String] = [
            "[Interface]",
            "PrivateKey = \(privB64)",
            "Address = \(v4Address)/32",
            "DNS = 1.1.1.1",
            "MTU = \(mtu)",
            "Jc = \(jc)",
            "Jmin = \(jmin)",
            "Jmax = \(jmax)",
            "S1 = 0",
            "S2 = 0"
        ]
        lines += [
            "H1 = 1",
            "H2 = 2",
            "H3 = 3",
            "H4 = 4"
        ]
        if use15 && !i1.isEmpty {
            lines.append("I1 = \(i1)")
        }
        if use3x {
            // AmneziaWG 3.0 & 3.1 anti-DPI timing and padding parameters
            lines += [
                "ContentPaddingAddition = 27-97",
                "MaxHandshakeAttempts = 18-26",
                "KeepaliveTimeout = 9-16",
                "RejectAfterTime = 171-196",
                "RekeyAfterTime = 116-131",
                "RekeyTimeout = 6-9",
                "RandomTrailers = on",
                "DisableCookies = on"
            ]
        }
        lines += [
            "",
            "[Peer]",
            "PublicKey = \(peerKey)",
            "AllowedIPs = 0.0.0.0/0",
            "Endpoint = \(endpoint)"
        ]
        if keepalive > 0 {
            lines.append("PersistentKeepalive = \(keepalive)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Mode 2: Cloudflare API Token Verification & Worker Management

    func verifyAndConnectToken() {
        let token = Self.sanitizeToken(tokenInput)
        guard !token.isEmpty else {
            errorMessage = "Paste your Cloudflare API token first."
            return
        }
        tokenInput = token
        isVerifyingToken = true
        errorMessage = nil
        statusMessage = "Verifying token with Cloudflare…"

        Task {
            do {
                let verifyJSON = try await Self.cfRequest(path: "/user/tokens/verify", token: token)
                guard (verifyJSON["success"] as? Bool) == true else {
                    throw NSError(domain: "CloudflareAPI", code: 401, userInfo: [NSLocalizedDescriptionKey: "Cloudflare rejected this token. Check that it was copied completely and has not expired."])
                }

                let accountsJSON = try await Self.cfRequest(path: "/accounts?per_page=10", token: token)
                guard let results = accountsJSON["result"] as? [[String: Any]],
                      let first = results.first,
                      let accountID = first["id"] as? String else {
                    throw NSError(domain: "CloudflareAPI", code: 404, userInfo: [NSLocalizedDescriptionKey: "No Cloudflare account found for this token. Make sure the token uses the 'Edit Cloudflare Workers' template."])
                }
                let accountName = (first["name"] as? String) ?? "Cloudflare Account"

                // Fetch workers.dev subdomain if configured
                var subdomain: String?
                if let subJSON = try? await Self.cfRequest(path: "/accounts/\(accountID)/workers/subdomain", token: token),
                   let res = subJSON["result"] as? [String: Any] {
                    subdomain = res["subdomain"] as? String
                }

                // Fetch existing workers
                var workers: [CloudflareWorkerScript] = []
                if let scriptsJSON = try? await Self.cfRequest(path: "/accounts/\(accountID)/workers/scripts", token: token),
                   let list = scriptsJSON["result"] as? [[String: Any]] {
                    workers = list.compactMap { item in
                        guard let id = item["id"] as? String else { return nil }
                        return CloudflareWorkerScript(id: id, modifiedOn: item["modified_on"] as? String)
                    }
                }

                Self.saveTokenToKeychain(token)
                self.hasSavedToken = true
                self.account = CloudflareAccountSummary(id: accountID, name: accountName, subdomain: subdomain)
                self.existingWorkers = workers
                if self.workerHost.isEmpty, let firstWorker = workers.first, let sub = subdomain {
                    self.workerHost = "\(firstWorker.id).\(sub).workers.dev"
                    self.persistWorkerSettings()
                }
                self.isVerifyingToken = false
                self.statusMessage = "Connected to \(accountName)" + (subdomain.map { " (\($0).workers.dev)" } ?? "")
            } catch {
                self.isVerifyingToken = false
                self.errorMessage = error.localizedDescription
                self.statusMessage = nil
            }
        }
    }

    func deployPrivateWorker() {
        let token = Self.sanitizeToken(tokenInput)
        guard let account, !token.isEmpty else {
            errorMessage = "Verify your Cloudflare token first."
            return
        }
        let cleanedName = workerNameInput
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        guard cleanedName.range(of: #"^[a-z0-9][a-z0-9-]{1,48}$"#, options: .regularExpression) != nil else {
            errorMessage = "Use a short lowercase name with letters, numbers, and hyphens (avoid words like vpn, proxy, or bpb)."
            return
        }
        let uuid = workerUUID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: uuid) != nil else {
            errorMessage = "Worker UUID must be a valid UUID. Click New UUID to generate one."
            return
        }

        isDeployingWorker = true
        errorMessage = nil
        statusMessage = "Deploying private Worker '\(cleanedName)'…"

        Task {
            do {
                let scriptBody = Self.makeVLESSWorkerModule(uuid: uuid)
                let boundary = "----HousekeeperCFBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                let metadataJSON = #"{"main_module":"worker.js","compatibility_date":"2025-01-01"}"#

                var body = Data()
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"metadata\"; filename=\"metadata.json\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
                body.append(metadataJSON.data(using: .utf8)!)
                body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: application/javascript+module\r\n\r\n".data(using: .utf8)!)
                body.append(scriptBody.data(using: .utf8)!)
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

                var putReq = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account.id)/workers/scripts/\(cleanedName)")!)
                putReq.httpMethod = "PUT"
                putReq.timeoutInterval = 25
                putReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                putReq.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                putReq.httpBody = body

                let (putData, putResp) = try await URLSession.shared.data(for: putReq)
                let putJSON = (try? JSONSerialization.jsonObject(with: putData) as? [String: Any]) ?? [:]
                guard let http = putResp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      (putJSON["success"] as? Bool) == true else {
                    let msg = Self.extractCloudflareError(putJSON) ?? "HTTP \((putResp as? HTTPURLResponse)?.statusCode ?? -1)"
                    throw NSError(domain: "CloudflareAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Deploy failed: \(msg)"])
                }

                // Enable workers.dev subdomain route
                var subReq = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account.id)/workers/scripts/\(cleanedName)/subdomain")!)
                subReq.httpMethod = "POST"
                subReq.timeoutInterval = 15
                subReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                subReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                subReq.httpBody = Data(#"{"enabled":true}"#.utf8)
                _ = try? await URLSession.shared.data(for: subReq)

                let host: String
                if let sub = account.subdomain, !sub.isEmpty {
                    host = "\(cleanedName).\(sub).workers.dev"
                } else {
                    host = "\(cleanedName).workers.dev"
                }
                self.workerHost = host
                self.persistWorkerSettings()
                if !self.existingWorkers.contains(where: { $0.id == cleanedName }) {
                    self.existingWorkers.insert(CloudflareWorkerScript(id: cleanedName, modifiedOn: "Just now"), at: 0)
                }
                self.isDeployingWorker = false
                self.statusMessage = "Deployed '\(host)'. Now turn VPN off and scan for Clean IPs below."
            } catch {
                self.isDeployingWorker = false
                self.errorMessage = error.localizedDescription
                self.statusMessage = nil
            }
        }
    }

    func deleteWorker(named name: String) {
        let token = Self.sanitizeToken(tokenInput)
        guard let account, !token.isEmpty else { return }
        statusMessage = "Deleting Worker '\(name)'…"
        errorMessage = nil

        Task {
            do {
                var req = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account.id)/workers/scripts/\(name)")!)
                req.httpMethod = "DELETE"
                req.timeoutInterval = 15
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, resp) = try await URLSession.shared.data(for: req)
                let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      (json["success"] as? Bool) == true else {
                    let msg = Self.extractCloudflareError(json) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
                    throw NSError(domain: "CloudflareAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not delete Worker: \(msg)"])
                }
                self.existingWorkers.removeAll { $0.id == name }
                self.statusMessage = "Deleted Worker '\(name)' from Cloudflare."
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusMessage = nil
            }
        }
    }

    private static func cfRequest(path: String, token: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4\(path)")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func extractCloudflareError(_ json: [String: Any]) -> String? {
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first,
           let message = first["message"] as? String {
            return message
        }
        return nil
    }

    // MARK: - Clean Cloudflare IPv4 Scanner (Real TCP+TLS Probe)

    /// Official Cloudflare Anycast IPv4 prefixes (IPv4 only — Iran has no IPv6).
    static let cloudflarePrefixes: [String] = [
        "104.16.132", "104.16.248", "104.17.64", "104.17.148",
        "104.18.2", "104.18.26", "104.19.37", "104.19.196",
        "104.21.16", "104.21.48", "104.22.4", "104.22.58",
        "104.24.10", "104.26.8", "104.27.128", "162.159.135",
        "162.159.136", "162.159.138", "162.159.192", "162.159.193",
        "172.64.32", "172.64.80", "172.67.128", "172.67.180",
        "188.114.96", "188.114.97", "188.114.98", "188.114.99"
    ]

    static func sampleCandidateIPs(count: Int) -> [String] {
        var ips: [String] = []
        var used = Set<String>()
        let prefixes = cloudflarePrefixes.shuffled()
        var idx = 0
        while ips.count < count {
            let prefix = prefixes[idx % prefixes.count]
            let lastOctet = Int.random(in: 2...250)
            let ip = "\(prefix).\(lastOctet)"
            if used.insert(ip).inserted {
                ips.append(ip)
            }
            idx += 1
        }
        return ips
    }

    func startCleanIPScan() {
        guard !isScanningIPs else { return }
        isScanningIPs = true
        cleanIPResults = []
        scanProgress = 0
        errorMessage = nil
        let targetCount = scanDepth.count
        let port = tlsPort
        scanStatusText = "Scanning \(targetCount) Cloudflare IPv4 addresses on port \(port)…"

        let candidates = Self.sampleCandidateIPs(count: targetCount)
        scanTask = Task {
            var completed = 0
            var found: [CleanIPResult] = []

            // Run in batches of 8 concurrent TCP+TLS probes so we don't flood the router.
            for batchStart in stride(from: 0, to: candidates.count, by: 8) {
                if Task.isCancelled { break }
                let batchEnd = min(batchStart + 8, candidates.count)
                let slice = Array(candidates[batchStart..<batchEnd])

                let batchResults = await withTaskGroup(of: CleanIPResult.self) { group in
                    for ip in slice {
                        group.addTask {
                            await Self.probeCloudflareIP(ip: ip, port: port)
                        }
                    }
                    var items: [CleanIPResult] = []
                    for await result in group {
                        items.append(result)
                    }
                    return items
                }

                completed += batchResults.count
                found.append(contentsOf: batchResults.filter(\.reachable))
                found.sort { $0.latencyMs < $1.latencyMs }

                self.cleanIPResults = found
                self.scanProgress = Double(completed) / Double(candidates.count)
                self.scanStatusText = "Tested \(completed)/\(candidates.count) IPs · \(found.count) clean found"
            }

            self.isScanningIPs = false
            if Task.isCancelled {
                self.scanStatusText = "Scan stopped (\(found.count) clean IPs found)."
            } else if found.isEmpty {
                self.scanStatusText = "No clean IPs responded on port \(port). Turn VPN off, try another port (2053/2083/8443), or try AmneziaWG WARP."
            } else {
                self.scanStatusText = "Found \(found.count) clean IPs. Fastest: \(found[0].ip) (\(found[0].latencyMs) ms)."
            }
        }
    }

    func stopCleanIPScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanningIPs = false
    }

    private final class ProbeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let start = Date()
        private let ip: String
        private let port: Int
        private let conn: NWConnection
        private let continuation: CheckedContinuation<CleanIPResult, Never>

        init(ip: String, port: Int, conn: NWConnection, continuation: CheckedContinuation<CleanIPResult, Never>) {
            self.ip = ip
            self.port = port
            self.conn = conn
            self.continuation = continuation
        }

        func finish(_ reachable: Bool, _ note: String) {
            lock.lock()
            let already = finished
            finished = true
            lock.unlock()
            guard !already else { return }
            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
            conn.stateUpdateHandler = nil
            conn.cancel()
            continuation.resume(returning: CleanIPResult(ip: ip, port: port, latencyMs: ms, reachable: reachable, note: note))
        }

        var elapsed: TimeInterval { Date().timeIntervalSince(start) }
    }

    private static func probeCloudflareIP(ip: String, port: Int) async -> CleanIPResult {
        await withCheckedContinuation { continuation in
            let host = NWEndpoint.Host(ip)
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                continuation.resume(returning: CleanIPResult(ip: ip, port: port, latencyMs: 9999, reachable: false, note: "Invalid port"))
                return
            }
            let params = NWParameters.tls
            let conn = NWConnection(host: host, port: nwPort, using: params)
            let queue = DispatchQueue(label: "housekeeper.cfprobe.\(ip)")
            let guardBox = ProbeGuard(ip: ip, port: port, conn: conn, continuation: continuation)

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guardBox.finish(true, "TLS handshake OK")
                case .failed(let err):
                    guardBox.finish(false, err.localizedDescription)
                case .waiting(let err):
                    if guardBox.elapsed > 2.2 {
                        guardBox.finish(false, err.localizedDescription)
                    }
                default:
                    break
                }
            }

            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2.5) {
                guardBox.finish(false, "Timed out")
            }
        }
    }

    // MARK: - Config Builders (VLESS URI + Fragment Xray JSON + QR Code)

    func buildVLESSLink(address: String, label: String) -> String {
        let host = workerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let uuid = workerUUID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let encodedLabel = label.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? label
        return "vless://\(uuid)@\(address):\(tlsPort)?encryption=none&security=tls&sni=\(host)&fp=chrome&type=ws&host=\(host)&path=%2F%3Fed%3D2048#\(encodedLabel)"
    }

    func buildFragmentXrayJSON(address: String) -> String {
        let host = workerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let uuid = workerUUID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fragBlock: String
        if fragmentPreset != .off {
            fragBlock = """
                ,
                {
                  "tag": "fragment",
                  "protocol": "freedom",
                  "settings": {
                    "domainStrategy": "AsIs",
                    "fragment": {
                      "packets": "tlshello",
                      "length": "\(fragmentPreset.lengthRange)",
                      "interval": "\(fragmentPreset.intervalRange)"
                    }
                  }
                }
            """
        } else {
            fragBlock = ""
        }
        let sockoptBlock = fragmentPreset != .off
            ? ",\n        \"sockopt\": { \"dialerProxy\": \"fragment\", \"tcpNoDelay\": true }"
            : ""

        return """
        {
          "remarks": "Housekeeper-CF-\(address)",
          "inbounds": [
            { "tag": "socks", "port": 10808, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": true } }
          ],
          "outbounds": [
            {
              "tag": "proxy",
              "protocol": "vless",
              "settings": {
                "vnext": [
                  {
                    "address": "\(address)",
                    "port": \(tlsPort),
                    "users": [{ "id": "\(uuid)", "encryption": "none" }]
                  }
                ]
              },
              "streamSettings": {
                "network": "ws",
                "security": "tls",
                "tlsSettings": {
                  "serverName": "\(host)",
                  "fingerprint": "chrome",
                  "alpn": ["http/1.1"]
                },
                "wsSettings": {
                  "path": "/?ed=2048",
                  "headers": { "Host": "\(host)" }
                }\(sockoptBlock)
              }
            }\(fragBlock),
            { "tag": "direct", "protocol": "freedom" }
          ]
        }
        """
    }

    // MARK: - Clipboard, File Export & QR Code

    func copyText(_ text: String, confirmation: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = confirmation
        errorMessage = nil
    }

    func saveTextToFile(_ text: String, defaultName: String) {
        let panel = NSSavePanel()
        panel.title = "Save VPN Config"
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Saved to \(url.lastPathComponent)."
            errorMessage = nil
        } catch {
            errorMessage = "Could not save file: \(error.localizedDescription)"
        }
    }

    func presentQR(title: String, payload: String) {
        qrTitle = title
        qrPayload = payload
    }

    static func makeQRCodeImage(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Minimal Standard VLESS-over-WS Cloudflare Worker Script

    private static func makeVLESSWorkerModule(uuid: String) -> String {
        return """
        import { connect } from 'cloudflare:sockets';

        const USER_ID = '\(uuid)';

        export default {
          async fetch(request) {
            if (request.headers.get('Upgrade') !== 'websocket') {
              return new Response('OK', { status: 200, headers: { 'content-type': 'text/plain' } });
            }
            const [client, server] = Object.values(new WebSocketPair());
            server.accept();
            handleSession(server, request.headers.get('sec-websocket-protocol') || '');
            return new Response(null, { status: 101, webSocket: client });
          }
        };

        async function handleSession(ws, earlyHeader) {
          let remoteSocket = null;
          let writer = null;
          let closed = false;

          const sendSafe = (chunk) => {
            if (!closed && ws.readyState === 1) {
              try { ws.send(chunk); } catch {}
            }
          };

          const processFirstChunk = async (buf) => {
            const view = new DataView(buf);
            if (buf.byteLength < 24) return;
            const version = view.getUint8(0);
            const idBytes = new Uint8Array(buf, 1, 16);
            const hex = Array.from(idBytes).map(b => b.toString(16).padStart(2, '0')).join('');
            const formatted = `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
            if (formatted !== USER_ID.toLowerCase()) { ws.close(1008); return; }

            const optLen = view.getUint8(17);
            const cmd = view.getUint8(18 + optLen);
            if (cmd !== 1) { ws.close(1003); return; }
            const port = view.getUint16(19 + optLen);
            let idx = 21 + optLen;
            const addrType = view.getUint8(idx++);
            let host = '';
            if (addrType === 1) {
              host = Array.from(new Uint8Array(buf, idx, 4)).join('.');
              idx += 4;
            } else if (addrType === 2) {
              const len = view.getUint8(idx++);
              host = new TextDecoder().decode(new Uint8Array(buf, idx, len));
              idx += len;
            } else if (addrType === 3) {
              const parts = [];
              for (let i = 0; i < 8; i++) parts.push(view.getUint16(idx + i * 2).toString(16));
              host = `[${parts.join(':')}]`;
              idx += 16;
            }
            const payload = new Uint8Array(buf, idx);
            remoteSocket = connect({ hostname: host, port });
            writer = remoteSocket.writable.getWriter();
            if (payload.byteLength > 0) await writer.write(payload);

            let sentHeader = false;
            const reader = remoteSocket.readable.getReader();
            (async () => {
              try {
                while (true) {
                  const { value, done } = await reader.read();
                  if (done) break;
                  if (!sentHeader) {
                    sentHeader = true;
                    const out = new Uint8Array(2 + value.byteLength);
                    out[0] = version;
                    out[1] = 0;
                    out.set(value, 2);
                    sendSafe(out);
                  } else {
                    sendSafe(value);
                  }
                }
              } catch {} finally {
                closed = true;
                try { ws.close(); } catch {}
              }
            })();
          };

          if (earlyHeader) {
            try {
              const norm = earlyHeader.replace(/-/g, '+').replace(/_/g, '/');
              const bin = atob(norm);
              const bytes = new Uint8Array(bin.length);
              for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
              await processFirstChunk(bytes.buffer);
            } catch {}
          }

          ws.addEventListener('message', async (ev) => {
            const data = ev.data instanceof ArrayBuffer ? ev.data : await ev.data.arrayBuffer();
            if (!writer) {
              await processFirstChunk(data);
            } else {
              try { await writer.write(new Uint8Array(data)); } catch {}
            }
          });
          ws.addEventListener('close', () => {
            closed = true;
            try { remoteSocket?.close(); } catch {}
          });
        }
        """
    }
}
