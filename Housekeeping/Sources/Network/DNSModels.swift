import Foundation
import SwiftUI

// MARK: - DNS Category

public enum DNSCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case all = "All"
    case fast = "Fast & Privacy"
    case adblock = "Ad & Threat Blocking"
    case sanctionBypass = "Sanction Bypass"
    case gaming = "Gaming"
    case custom = "Custom"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .all: return "globe"
        case .fast: return "bolt.shield.fill"
        case .adblock: return "hand.raised.shield.fill"
        case .sanctionBypass: return "network.badge.shield.half.filled"
        case .gaming: return "gamecontroller.fill"
        case .custom: return "slider.horizontal.3"
        }
    }
}

// MARK: - DNS Preset Model

public struct DNSPreset: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let category: DNSCategory
    public let primaryIP: String
    public let secondaryIP: String
    public let tag: String
    public let description: String
    public let isDHCP: Bool

    public init(
        id: String,
        name: String,
        category: DNSCategory,
        primaryIP: String,
        secondaryIP: String = "",
        tag: String,
        description: String,
        isDHCP: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.primaryIP = primaryIP
        self.secondaryIP = secondaryIP
        self.tag = tag
        self.description = description
        self.isDHCP = isDHCP
    }

    /// Whether this preset represents automatic DHCP / router default.
    public static let automatic = DNSPreset(
        id: "dhcp-auto",
        name: "Automatic (DHCP)",
        category: .fast,
        primaryIP: "Router Default",
        secondaryIP: "DHCP",
        tag: "DEFAULT",
        description: "Restores default DNS assigned by your local Wi-Fi router or ISP DHCP.",
        isDHCP: true
    )

    /// Canonical list of built-in DNS providers including global Anycast and Iranian sanction bypass.
    public static let builtInPresets: [DNSPreset] = [
        automatic,

        // Global Fast & Privacy
        DNSPreset(
            id: "cloudflare-main",
            name: "Cloudflare (1.1.1.1)",
            category: .fast,
            primaryIP: "1.1.1.1",
            secondaryIP: "1.0.0.1",
            tag: "FASTEST",
            description: "Ultra-fast global Anycast network with strict zero-logging privacy."
        ),
        DNSPreset(
            id: "google-dns",
            name: "Google Public DNS",
            category: .fast,
            primaryIP: "8.8.8.8",
            secondaryIP: "8.8.4.4",
            tag: "RELIABLE",
            description: "Google's worldwide Anycast DNS infrastructure with high availability."
        ),
        DNSPreset(
            id: "quad9-privacy",
            name: "Quad9 DNS",
            category: .fast,
            primaryIP: "9.9.9.9",
            secondaryIP: "149.112.112.112",
            tag: "SWISS PRIVACY",
            description: "Swiss non-profit foundation. Blocks malicious domains with no telemetry."
        ),
        DNSPreset(
            id: "opendns-home",
            name: "OpenDNS Home",
            category: .fast,
            primaryIP: "208.67.222.222",
            secondaryIP: "208.67.220.220",
            tag: "CISCO",
            description: "Cisco Anycast network with built-in phishing and botnet defense."
        ),

        DNSPreset(
            id: "cloudflare-family",
            name: "Cloudflare Family",
            category: .adblock,
            primaryIP: "1.1.1.3",
            secondaryIP: "1.0.0.3",
            tag: "FAMILY",
            description: "Cloudflare's family resolver: blocks malware and adult content, keeps the same global network."
        ),
        DNSPreset(
            id: "mullvad-dns",
            name: "Mullvad DNS",
            category: .fast,
            primaryIP: "194.242.2.2",
            secondaryIP: "194.242.2.3",
            tag: "NO LOGS",
            description: "Mullvad's public resolver, run from the same no-logging network as its VPN. Answered when tested on 23 Nov 2026."
        ),
        DNSPreset(
            id: "nextdns-public",
            name: "NextDNS (Anycast)",
            category: .fast,
            primaryIP: "45.90.28.0",
            secondaryIP: "45.90.30.0",
            tag: "CONFIGURABLE",
            description: "NextDNS's anycast entry point. Filters are configured per account on nextdns.io; without a profile it behaves as a plain resolver."
        ),
        DNSPreset(
            id: "controld-public",
            name: "Control D (Free)",
            category: .fast,
            primaryIP: "76.76.2.0",
            secondaryIP: "76.76.10.0",
            tag: "FILTERS",
            description: "Control D's free anycast resolver. Account-based filters are optional; the bare address resolves normally."
        ),
        DNSPreset(
            id: "dns0-eu",
            name: "DNS0.eu",
            category: .fast,
            primaryIP: "193.110.81.0",
            secondaryIP: "185.253.5.0",
            tag: "EU NON-PROFIT",
            description: "European non-profit resolver that blocks malware by default, with no logging and no filtering of legal content."
        ),
        DNSPreset(
            id: "yandex-dns",
            name: "Yandex DNS",
            category: .fast,
            primaryIP: "77.88.8.8",
            secondaryIP: "77.88.8.1",
            tag: "REACHABLE IN IRAN",
            description: "Yandex's public resolver. It is reachable from Iranian networks and often answers when western resolvers are throttled; it is not a sanction bypass."
        ),

        // Ad & Threat Blocking
        DNSPreset(
            id: "adguard-main",
            name: "AdGuard DNS",
            category: .adblock,
            primaryIP: "94.140.14.14",
            secondaryIP: "94.140.15.15",
            tag: "AD BLOCKING",
            description: "Blocks web banner ads, tracking scripts, coin miners, and malicious redirects."
        ),
        DNSPreset(
            id: "cloudflare-security",
            name: "Cloudflare Security",
            category: .adblock,
            primaryIP: "1.1.1.2",
            secondaryIP: "1.0.0.2",
            tag: "MALWARE BLOCK",
            description: "Automated threat protection that blocks known malware and phishing."
        ),

        // Sanction bypass (Iran)
        //
        // Every address here was queried from this Mac on 23 November 2026:
        // `dig @<address> example.com A`. "Reachable" means it answered. The
        // 10.x and 172.16/12 entries are served inside specific Iranian ISPs and
        // did not answer from this connection; they are kept, and labelled, so
        // they are not mistaken for dead entries when they are simply carrier-only.
        DNSPreset(
            id: "shecan",
            name: "Shecan (شکن)",
            category: .sanctionBypass,
            primaryIP: "178.22.122.100",
            secondaryIP: "185.51.200.2",
            tag: "403 BYPASS",
            description: "Iran's longest-running anti-sanction resolver, aimed at Docker, Gradle, Android SDK, Maven, Adobe and npm. Answered in about 25 ms when tested on 23 Nov 2026. Encrypted DoH is at https://free.shecan.ir/dns-query."
        ),
        DNSPreset(
            id: "begzar",
            name: "Begzar (بگذر)",
            category: .sanctionBypass,
            primaryIP: "185.55.226.26",
            secondaryIP: "185.55.225.25",
            tag: "SANCTION BYPASS",
            description: "Free anti-sanction resolver for Iranian developers and web services. Answered in about 23 ms when tested on 23 Nov 2026. Encrypted DoH is at https://dns.begzar.ir/dns-query."
        ),
        DNSPreset(
            id: "shelter",
            name: "Shelter (شلتر)",
            category: .sanctionBypass,
            primaryIP: "94.103.125.158",
            secondaryIP: "94.103.125.157",
            tag: "SANCTION BYPASS",
            description: "Independent anti-sanction resolver widely recommended for game stores, consoles and developer tools. Answered in about 26 ms when tested on 23 Nov 2026."
        ),
        DNSPreset(
            id: "beshkan",
            name: "Beshkan (بشکن)",
            category: .sanctionBypass,
            primaryIP: "181.41.194.177",
            secondaryIP: "181.41.194.186",
            tag: "SANCTION BYPASS",
            description: "Anti-sanction resolver used for play-store and developer access. Answered in about 23 ms when tested on 23 Nov 2026. A second address pair (181.41.197.12 / .13) also answered."
        ),
        DNSPreset(
            id: "electro-public",
            name: "Electro Public (الکترو)",
            category: .sanctionBypass,
            primaryIP: "194.5.193.5",
            secondaryIP: "194.5.193.6",
            tag: "SANCTION + GAMING",
            description: "The public Electro address pair, usable outside the ISPs that carry 78.157.42.x. Aimed at Steam, EA, Ubisoft, Discord and developer downloads. Answered when tested on 23 Nov 2026."
        ),
        DNSPreset(
            id: "online403",
            name: "403.online (۴۰۳)",
            category: .sanctionBypass,
            primaryIP: "10.202.10.202",
            secondaryIP: "10.202.10.102",
            tag: "DEV BYPASS",
            description: "Developer-focused sanction bypass for GitHub, npm, PyPI, OpenAI and AWS. Carrier-provided: these addresses answered only inside some Iranian ISPs, and did not answer from this connection on 23 Nov 2026. Encrypted DoH is at https://dns.403.online/dns-query."
        ),
        DNSPreset(
            id: "radar-sanction",
            name: "Radar (رادار)",
            category: .sanctionBypass,
            primaryIP: "10.202.10.10",
            secondaryIP: "10.202.10.11",
            tag: "SANCTION BYPASS",
            description: "Radar's anti-sanction and low-ping resolver. Carrier-provided: it answers inside some Iranian ISPs and did not answer from this connection on 23 Nov 2026. Encrypted DoH is at https://dns.radar.game/dns-query."
        ),
        DNSPreset(
            id: "hostiran",
            name: "HostIran (هاست ایران)",
            category: .sanctionBypass,
            primaryIP: "172.29.0.100",
            secondaryIP: "172.29.2.100",
            tag: "SANCTION BYPASS",
            description: "HostIran's own anti-sanction resolver. Carrier-provided private addresses: usable only on ISPs that route them, and did not answer from this connection on 23 Nov 2026."
        ),
        DNSPreset(
            id: "vanilla-dns",
            name: "Vanilla (وانیلا)",
            category: .sanctionBypass,
            primaryIP: "10.139.177.21",
            secondaryIP: "10.139.177.22",
            tag: "SANCTION BYPASS",
            description: "Vanilla's bypass resolver, provided on Iranian carrier infrastructure. Carrier-provided private addresses: usable only where the carrier routes them; did not answer from this connection on 23 Nov 2026."
        ),

        // Gaming
        DNSPreset(
            id: "electro",
            name: "Electro (الکترو)",
            category: .gaming,
            primaryIP: "78.157.42.100",
            secondaryIP: "78.157.42.101",
            tag: "GAMING & STEAM",
            description: "Optimised for gaming traffic, Steam downloads, EA, Ubisoft and Discord connectivity. Answered in about 24 ms when tested on 23 Nov 2026."
        ),
        DNSPreset(
            id: "radar-game",
            name: "Radar Game (رادار بازی)",
            category: .gaming,
            primaryIP: "10.202.10.10",
            secondaryIP: "10.202.10.11",
            tag: "LOW PING",
            description: "Radar's low-latency gaming resolver. Carrier-provided: answers inside some Iranian ISPs; did not answer from this connection on 23 Nov 2026."
        )
    ]
}

// MARK: - Network Hardware Interface

public struct NetworkHardwareInterface: Identifiable, Hashable, Sendable {
    public let id: String
    public let userDefinedName: String
    public let hardwarePort: String
    public let device: String
    public let isPrimary: Bool
    public let configuredDNS: [String]

    public init(
        id: String,
        userDefinedName: String,
        hardwarePort: String,
        device: String,
        isPrimary: Bool,
        configuredDNS: [String]
    ) {
        self.id = id
        self.userDefinedName = userDefinedName
        self.hardwarePort = hardwarePort
        self.device = device
        self.isPrimary = isPrimary
        self.configuredDNS = configuredDNS
    }

    /// Display string e.g. "Wi-Fi (en0) · Primary"
    public var displayTitle: String {
        if isPrimary {
            return "\(userDefinedName) · Active Default"
        } else {
            return userDefinedName
        }
    }
}
