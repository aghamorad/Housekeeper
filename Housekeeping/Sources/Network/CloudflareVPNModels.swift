// Housekeeping — Cloudflare Clean VPN & AmneziaWG WARP Models

import Foundation

enum CloudflareVPNTab: String, CaseIterable, Identifiable {
    case warp = "AmneziaWG WARP (Free)"
    case tokenCleanIP = "Cloudflare Token & Clean IPs"

    var id: String { rawValue }
}

enum WarpJunkPreset: String, CaseIterable, Identifiable {
    case light = "Light (Start here)"
    case heavy = "Heavy (Stricter networks)"
    case custom = "Custom"

    var id: String { rawValue }

    var defaults: (jc: Int, jmin: Int, jmax: Int) {
        switch self {
        case .light: return (3, 1, 3)
        case .heavy: return (5, 10, 40)
        case .custom: return (3, 1, 3)
        }
    }
}

enum CleanIPScanDepth: String, CaseIterable, Identifiable {
    case quick = "Quick (16 IPs)"
    case standard = "Standard (32 IPs)"
    case thorough = "Thorough (64 IPs)"

    var id: String { rawValue }

    var count: Int {
        switch self {
        case .quick: return 16
        case .standard: return 32
        case .thorough: return 64
        }
    }
}

enum FragmentPreset: String, CaseIterable, Identifiable {
    case off = "Off (Direct TLS)"
    case mciLight = "MCI / Light (10-20, 10-20ms)"
    case irancellHeavy = "Irancell / Heavy (10-30, 10-30ms)"

    var id: String { rawValue }

    var lengthRange: String {
        switch self {
        case .off: return ""
        case .mciLight: return "10-20"
        case .irancellHeavy: return "10-30"
        }
    }

    var intervalRange: String {
        switch self {
        case .off: return ""
        case .mciLight: return "10-20"
        case .irancellHeavy: return "10-30"
        }
    }
}

struct CloudflareAccountSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let subdomain: String?
}

struct CloudflareWorkerScript: Identifiable, Equatable {
    let id: String
    let modifiedOn: String?
}

struct CleanIPResult: Identifiable, Equatable {
    let id = UUID()
    let ip: String
    let port: Int
    let latencyMs: Int
    let reachable: Bool
    let note: String

    var qualityLabel: String {
        guard reachable else { return "Blocked / Timed out" }
        if latencyMs <= 120 { return "Fast & Clean" }
        if latencyMs <= 260 { return "Clean" }
        return "Slow but Reachable"
    }
}

struct WarpEndpointCandidate: Identifiable, Hashable {
    let id: String
    let host: String
    let port: Int
    let label: String

    var endpointString: String { "\(host):\(port)" }

    static let curated: [WarpEndpointCandidate] = [
        // 8.6.112.0/24 + non-standard UDP ports (most reliable on Iranian ISPs)
        WarpEndpointCandidate(id: "8-6-224-5279", host: "8.6.112.224", port: 5279, label: "8.6.112.224:5279 (Recommended · Iran)"),
        WarpEndpointCandidate(id: "8-6-46-903", host: "8.6.112.46", port: 903, label: "8.6.112.46:903 (Iran)"),
        WarpEndpointCandidate(id: "8-6-206-3854", host: "8.6.112.206", port: 3854, label: "8.6.112.206:3854 (Iran)"),
        WarpEndpointCandidate(id: "8-6-31-859", host: "8.6.112.31", port: 859, label: "8.6.112.31:859 (Iran)"),
        WarpEndpointCandidate(id: "8-6-113-864", host: "8.6.112.113", port: 864, label: "8.6.112.113:864 (Iran)"),
        WarpEndpointCandidate(id: "8-6-121-500", host: "8.6.112.121", port: 500, label: "8.6.112.121:500 (Iran)"),
        WarpEndpointCandidate(id: "8-6-208-2408", host: "8.6.112.208", port: 2408, label: "8.6.112.208:2408 (Iran)"),
        WarpEndpointCandidate(id: "8-6-10-1701", host: "8.6.112.10", port: 1701, label: "8.6.112.10:1701 (Iran)"),
        WarpEndpointCandidate(id: "8-6-132-8854", host: "8.6.112.132", port: 8854, label: "8.6.112.132:8854 (Iran)"),
        WarpEndpointCandidate(id: "8-6-146-942", host: "8.6.112.146", port: 942, label: "8.6.112.146:942 (Iran)"),
        // 188.114.96-99.0/24 fallbacks
        WarpEndpointCandidate(id: "188-96-1-2408", host: "188.114.96.1", port: 2408, label: "188.114.96.1:2408"),
        WarpEndpointCandidate(id: "188-97-1-2408", host: "188.114.97.1", port: 2408, label: "188.114.97.1:2408"),
        WarpEndpointCandidate(id: "188-98-1-2408", host: "188.114.98.1", port: 2408, label: "188.114.98.1:2408"),
        WarpEndpointCandidate(id: "188-99-1-2408", host: "188.114.99.1", port: 2408, label: "188.114.99.1:2408"),
        WarpEndpointCandidate(id: "188-96-1-500", host: "188.114.96.1", port: 500, label: "188.114.96.1:500"),
        WarpEndpointCandidate(id: "188-96-1-4500", host: "188.114.96.1", port: 4500, label: "188.114.96.1:4500"),
        // Main Cloudflare fallback
        WarpEndpointCandidate(id: "engage-2408", host: "engage.cloudflareclient.com", port: 2408, label: "engage.cloudflareclient.com:2408 (Global)")
    ]
}

struct IranianCarrierPreset: Identifiable {
    let id: String
    let name: String
    let hostname: String

    static let all: [IranianCarrierPreset] = [
        IranianCarrierPreset(id: "mci", name: "MCI (Hamrah-e Aval)", hostname: "mci.ircf.space"),
        IranianCarrierPreset(id: "mtn", name: "Irancell (MTN)", hostname: "mtn.ircf.space"),
        IranianCarrierPreset(id: "rtl", name: "Rightel", hostname: "rtl.ircf.space")
    ]
}
