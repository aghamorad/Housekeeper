import SwiftUI
import AppKit

/// The flagship Command Deck for Housekeeper.
/// Combines live storage health, instant 1-click hero launch tiles, live tool search,
/// and a balanced 2-column kitchen-sink grid — 100% event-driven (0.0% idle CPU).
struct OverviewView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.uiStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var vitals = SystemVitals.shared
    @ObservedObject private var helper = PrivilegedHelper.shared
    @State private var mascotHovered = false
    @State private var filterText = ""
    @State private var mergingBackgroundItem = false
    @State private var backgroundMergeMessage: String?

    private struct ToolEntry: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let keywords: String
        let action: () -> Void
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBar

                if helper.needsAssociationRepair {
                    duplicateBackgroundItemBanner
                } else if let merged = backgroundMergeMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(style.positive)
                        Text(merged)
                            .font(.system(size: 12.5))
                            .foregroundStyle(style.text)
                        Spacer()
                        Button {
                            backgroundMergeMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .housekeepingCard(cornerRadius: 12)
                }

                if let zombie = vitals.snapshot.zombieCandidates.first {
                    zombieAlertBanner(zombie)
                }

                if let inhibitor = vitals.snapshot.sleepInhibitor {
                    sleepInhibitorBanner(inhibitor)
                }

                OverviewStorageCard(scan: { appState.startScan() }, browse: { appState.showDiskBrowser = true })

                OverviewActivity(model: appState.cleaner) { appState.showClean = true }

                if let results = appState.scanResults {
                    Button {
                        appState.showOverview = false
                        appState.flowStep = .review
                    } label: {
                        HStack {
                            Label("Return to scan results", systemImage: "list.bullet.rectangle")
                            Spacer()
                            Text("\(results.foundItems.count) items · \(results.summary.totalSize.sizeDescription)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 13))
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HousekeepingPressableStyle(pressedScale: 0.99))
                    .housekeepingCard(cornerRadius: 12)
                }

                // 4 tactile everyday launch tiles
                if filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    heroQuickDeck
                }

                // Instant filter bar across every tool in the kitchen sink
                searchBar

                let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if query.isEmpty {
                    twoColumnKitchenSink
                } else {
                    filteredToolList(query: query)
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background { HousekeepingBackdrop(style: style) }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 14) {
            AnimatedCleaningMascotStage(
                mode: appState.cleaner.phase == .scanning ? .scanningFolders : .maintenance,
                isActive: mascotHovered || appState.cleaner.phase == .scanning,
                size: 56,
                showFolderTrack: false,
                accent: style.accent
            )
            .scaleEffect(mascotHovered && !reduceMotion ? 1.09 : 1.0)
            .onHover { mascotHovered = $0 }
            .onTapGesture {
                HousekeepingFeedback.press()
                appState.showHousekeeper = true
            }
            .contextMenu {
                Button("Talk to Housekeeper…") {
                    appState.showHousekeeper = true
                }
                Button("Scan My Mac") {
                    appState.startScan()
                }
                Button("Open Cloudflare Clean VPN") {
                    appState.showCloudflareVPN = true
                }
                Divider()
                Button("Make Text Bigger (⌘+)") {
                    let cur = UserDefaults.standard.integer(forKey: "housekeeping.textZoomStep")
                    UserDefaults.standard.set(min(4, cur + 1), forKey: "housekeeping.textZoomStep")
                }
                Button("Make Text Smaller (⌘-)") {
                    let cur = UserDefaults.standard.integer(forKey: "housekeeping.textZoomStep")
                    UserDefaults.standard.set(max(-2, cur - 1), forKey: "housekeeping.textZoomStep")
                }
                Button("Reset Text Size") {
                    UserDefaults.standard.set(0, forKey: "housekeeping.textZoomStep")
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.65), value: mascotHovered)
            .help("Click or right-click the Housekeeper to talk, scan, or zoom text.")

            VStack(alignment: .leading, spacing: 3) {
                Text("Housekeeper")
                    .font(style.isRetro ? style.titleFont : .system(size: 25, weight: .semibold, design: .rounded))
                Text("Reads storage, vitals, and network health. Moves nothing until you approve.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Label(Host.current().localizedName ?? "This Mac", systemImage: "desktopcomputer")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(HardwareProfile.kind)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(style.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.75))
        }
    }

    private var duplicateBackgroundItemBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.on.square.badge.person.crop")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(style.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text("Two Housekeeper background items detected")
                    .font(.system(size: 13, weight: .semibold))
                Text("Update the helper plist once so macOS Login Items & Extensions groups everything under a single Housekeeper entry.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            ThemeButton(
                title: mergingBackgroundItem ? "Merging…" : "Merge Into One",
                systemImage: "arrow.triangle.merge",
                isPrimary: true,
                isEnabled: !mergingBackgroundItem
            ) {
                mergingBackgroundItem = true
                Task {
                    do {
                        try await helper.install()
                        backgroundMergeMessage = "Merged! macOS now groups Housekeeper's helper under the single Housekeeper entry."
                    } catch {
                        backgroundMergeMessage = error.localizedDescription
                    }
                    mergingBackgroundItem = false
                    helper.refresh()
                }
            }
        }
        .padding(14)
        .housekeepingCard(cornerRadius: 14, highlighted: true)
    }

    // MARK: - Hero Quick Launchpad (4 Everyday Actions)

    private var heroQuickDeck: some View {
        LiquidGlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                OverviewHeroTile(
                    title: "Clean Up",
                    subtitle: "Safe junk & caches",
                    icon: "sparkles"
                ) { appState.showClean = true }

                OverviewHeroTile(
                    title: "Clean VPN",
                    subtitle: "WARP & Clean IPs",
                    icon: "checkmark.shield.fill"
                ) { appState.showCloudflareVPN = true }

                OverviewHeroTile(
                    title: "Speed Test",
                    subtitle: "Ping & throughput",
                    icon: "speedometer"
                ) { appState.showSpeedTest = true }

                OverviewHeroTile(
                    title: "Space Lens",
                    subtitle: "Folders & large files",
                    icon: "internaldrive"
                ) { appState.showDiskBrowser = true }
            }
        }
    }

    // MARK: - Live Filter Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Filter tools… (VPN, DNS, fans, YouTube, audiobook, trash)", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !filterText.isEmpty {
                Button {
                    HousekeepingFeedback.press()
                    withAnimation(HousekeepingMotion.hover) { filterText = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text("⌘/")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .liquidGlassChrome(in: Capsule(), interactive: true)
    }

    // MARK: - 2-Column Kitchen Sink

    private var allToolSections: [(title: String, items: [ToolEntry])] {
        [
            ("System Care", [
                ToolEntry(id: "clean", title: "Clean Up", detail: "Caches, installers, and removable app data.", icon: "sparkles", keywords: "junk cache trash logs") {
                    appState.showClean = true
                },
                ToolEntry(id: "updates", title: "Update Apps", detail: "Mac apps, Homebrew packages, and App Store.", icon: "arrow.triangle.2.circlepath", keywords: "brew cask upgrade") {
                    appState.showUpdateList = true
                },
                ToolEntry(id: "uninstall", title: "Uninstall Apps", detail: "Remove apps along with leftover support files.", icon: "xmark.app", keywords: "delete remove leftovers") {
                    appState.showUninstaller = true
                },
                ToolEntry(id: "downloaded", title: "Open a Downloaded App", detail: "Clear a download flag safely without touching signatures.", icon: "checkmark.shield", keywords: "gatekeeper quarantine xattr") {
                    appState.showAppRepair = true
                }
            ]),
            ("Network & VPN", [
                ToolEntry(id: "cfvpn", title: "Cloudflare Clean VPN", detail: "AmneziaWG WARP configs & Clean Cloudflare IP VLESS scanner.", icon: "checkmark.shield.fill", keywords: "cloudflare warp amnezia bpb vless clean ip fragment") {
                    appState.showCloudflareVPN = true
                },
                ToolEntry(id: "routes", title: "Route Sweep", detail: "Test VPN locations and protocols for reachability.", icon: "network", keywords: "windscribe surfshark expressvpn") {
                    appState.showRoutes = true
                },
                ToolEntry(id: "speed", title: "Speed Test", detail: "Measure download, upload, ping, and jitter.", icon: "speedometer", keywords: "mbps internet ping") {
                    appState.showSpeedTest = true
                },
                ToolEntry(id: "dns", title: "DNS Switcher", detail: "1-click Iranian & privacy DNS presets or reset.", icon: "globe", keywords: "shecan begzar electro 403") {
                    appState.showDNSSwitcher = true
                },
                ToolEntry(id: "tunnels", title: "VPN Tunnels", detail: "Inspect active utun interfaces and VPN services.", icon: "lock.shield", keywords: "utun fix internet") {
                    appState.showVPNTunnels = true
                }
            ]),
            ("Hardware & Vitals", [
                ToolEntry(id: "fans", title: "Cooling & Fans", detail: "Live thermal sensors and fan speed control.", icon: "fan.fill", keywords: "temperature smc heat") {
                    appState.showFanControl = true
                },
                ToolEntry(id: "battery", title: "Battery Health", detail: "Cycle count, battery wear, and sleep drain checks.", icon: "battery.100.bolt", keywords: "power charger cycles") {
                    appState.showBatteryHealth = true
                },
                ToolEntry(id: "space", title: "Space Lens", detail: "Browse folders and search subfolders by real size.", icon: "internaldrive", keywords: "disk storage files") {
                    appState.showDiskBrowser = true
                },
                ToolEntry(id: "activity", title: "Background Activity", detail: "Inspect running processes and login items.", icon: "list.bullet.rectangle", keywords: "cpu ram memory processes") {
                    appState.showBackgroundActivity = true
                }
            ]),
            ("Studios & AI", [
                ToolEntry(id: "mediadock", title: "Media Studio (MediaDock)", detail: "Download YouTube, Spotify & Apple Music (Intel + Silicon).", icon: "play.rectangle.fill", keywords: "youtube spotify apple music yt-dlp ffmpeg") {
                    appState.showMediaDock = true
                },
                ToolEntry(id: "bookbind", title: "Bookbind Studio", detail: "Merge audio tracks into chaptered M4B audiobooks.", icon: "book.closed.fill", keywords: "audiobook m4b mp3 chapters") {
                    appState.showBookbind = true
                },
                ToolEntry(id: "models", title: "Local AI Models", detail: "Manage local MLX, Ollama & GGUF models and RAM.", icon: "cpu", keywords: "llm ollama mlx hermes") {
                    appState.showLocalModels = true
                },
                ToolEntry(id: "spoof", title: "Spoof Location", detail: "USB GPS location helper for iPhone.", icon: "location.slash", keywords: "iphone gps developer mode") {
                    appState.showPhone = true
                }
            ])
        ]
    }

    private var twoColumnKitchenSink: some View {
        let sections = allToolSections
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(sections, id: \.title) { section in
                groupedSection(title: section.title) {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 {
                            Divider().padding(.leading, 48)
                        }
                        OverviewToolRow(title: item.title, detail: item.detail, icon: item.icon, action: item.action)
                    }
                }
            }
        }
    }

    private func filteredToolList(query: String) -> some View {
        let matches = allToolSections.flatMap(\.items).filter {
            $0.title.lowercased().contains(query)
                || $0.detail.lowercased().contains(query)
                || $0.keywords.lowercased().contains(query)
        }
        return groupedSection(title: "Matching Tools (\(matches.count))") {
            if matches.isEmpty {
                Text("No tools match '\(filterText)'.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(matches.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 { Divider().padding(.leading, 48) }
                    OverviewToolRow(title: item.title, detail: item.detail, icon: item.icon, action: item.action)
                }
            }
        }
    }

    private func groupedSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .housekeepingCard(cornerRadius: 12)
        }
    }

    private func zombieAlertBanner(_ process: ProcessLoad) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(style.negative)
            VStack(alignment: .leading, spacing: 2) {
                Text("Runaway Task: \(process.name)")
                    .font(.system(size: 13, weight: .semibold))
                Text("Using \(Int(process.cpu * 100))% CPU continuously.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ThemeButton(title: "Stop Task", isPrimary: false) {
                SystemVitals.terminate(pid: process.id, force: true)
            }
        }
        .padding(14)
        .background(style.negative.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(style.negative.opacity(0.25), lineWidth: 0.75))
    }

    private func sleepInhibitorBanner(_ process: ProcessLoad) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 16))
                .foregroundStyle(style.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Sleep Prevented")
                    .font(.system(size: 13, weight: .semibold))
                Text("'\(process.name)' is currently preventing automatic sleep.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ThemeButton(title: "Allow Sleep", isPrimary: false) {
                SystemVitals.terminate(pid: process.id, force: false)
            }
        }
        .padding(14)
        .background(style.caution.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(style.caution.opacity(0.25), lineWidth: 0.75))
    }
}

private struct OverviewHeroTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    @Environment(\.uiStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(style.accent.opacity(hovering ? 0.22 : 0.13))
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(style.accent)
                        .scaleEffect(hovering && !reduceMotion ? 1.09 : 1.0)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(style.text)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassChrome(
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                tint: hovering ? style.accent.opacity(0.14) : nil,
                interactive: true
            )
            .offset(y: hovering && !reduceMotion ? -1.5 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(HousekeepingPressableStyle(pressedScale: 0.97, haptic: true))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : HousekeepingMotion.hover, value: hovering)
    }
}

private struct OverviewToolRow: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void
    @Environment(\.uiStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(style.accent.opacity(hovering ? 0.18 : 0.09))
                    Image(systemName: icon)
                        .font(.system(size: 13.5, weight: hovering ? .semibold : .medium))
                        .foregroundStyle(style.accent)
                        .scaleEffect(hovering && !reduceMotion ? 1.08 : 1.0)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(style.text)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(hovering ? style.accent : Color.secondary.opacity(0.42))
                    .offset(x: hovering && !reduceMotion ? 3 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(hovering ? style.accent.opacity(0.065) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(HousekeepingPressableStyle(pressedScale: 0.99, haptic: true))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : HousekeepingMotion.hover, value: hovering)
        .accessibilityLabel(title)
    }
}

private struct OverviewStorageCard: View {
    let scan: () -> Void
    let browse: () -> Void
    @Environment(\.uiStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reading: VolumeReading?

    private struct VolumeReading: Sendable {
        let name: String
        let total: Int64
        let available: Int64
        var used: Int64 { max(0, total - available) }
        var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(reading?.name ?? "Mac Storage")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let reading {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(reading.available.humanReadable)
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("available of \(reading.total.humanReadable)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        Text("Reading storage…")
                            .font(.system(size: 20, weight: .semibold))
                    }
                }
                Spacer(minLength: 16)
                HStack(spacing: 8) {
                    ThemeButton(title: "Browse Disk", isPrimary: false, action: browse)
                    ThemeButton(title: "Scan My Mac", systemImage: "magnifyingglass", isPrimary: true, action: scan)
                }
            }

            VStack(spacing: 6) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(colors: [style.accentShaded, style.accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geometry.size.width * (reading?.fraction ?? 0)))
                            .overlay(alignment: .top) { Capsule().fill(.white.opacity(0.18)).frame(height: 1) }
                    }
                }
                .frame(height: 7)
                .animation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.85), value: reading?.fraction ?? 0)

                HStack {
                    if let reading {
                        Text("\(reading.used.humanReadable) used")
                        Spacer()
                        Text("\(Int((reading.fraction * 100).rounded()))% full")
                    } else {
                        Text("Scanning reads your files without moving anything.")
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(18)
        .housekeepingCard(cornerRadius: 14, prominent: true)
        .task {
            let result = await Task.detached(priority: .utility) {
                let home = FileManager.default.homeDirectoryForCurrentUser
                guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey]),
                      let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil as VolumeReading? }
                return VolumeReading(name: values.volumeName ?? "Mac Storage", total: Int64(total), available: Int64(available))
            }.value
            withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86)) {
                reading = result
            }
        }
    }
}

private struct OverviewActivity: View {
    @Environment(\.uiStyle) private var style
    @ObservedObject var model: CleanerModel
    let open: () -> Void

    var body: some View {
        if model.phase != .idle {
            Button(action: open) {
                HStack(spacing: 12) {
                    if model.phase == .scanning { ProgressView().controlSize(.small) }
                    else { Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.phase == .scanning ? "Clean Up is scanning" : "Your Clean Up results")
                            .font(.system(size: 13, weight: .semibold))
                        Text(model.phase == .scanning ? model.progressLine : "\(model.candidates.count) items · \(model.cleanerTotal.sizeDescription)\(model.wasStopped ? " · Partial scan" : "")")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(HousekeepingPressableStyle(pressedScale: 0.99))
            .housekeepingCard(cornerRadius: 12)
        }
    }
}

struct SidebarNavigationRow: View {
    @Environment(\.uiStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let icon: String
    let selected: Bool
    var enabled = true
    var selectionNamespace: Namespace.ID? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(selected ? style.accent : (hovering ? style.text : .secondary))
                    .scaleEffect(hovering && !selected && !reduceMotion ? 1.07 : 1.0)
                    .frame(width: 18, height: 18, alignment: .center)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? style.text : (hovering ? style.text : style.secondaryText))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    activePill
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(style.groupingBackground.opacity(0.65))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HousekeepingPressableStyle(pressedScale: 0.975, haptic: true))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : HousekeepingMotion.hover, value: hovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var activePill: some View {
        let pill = Capsule(style: .continuous)
            .fill(Color.clear)
            .liquidGlassChrome(in: Capsule(style: .continuous), tint: style.accent.opacity(0.28), interactive: true)
        if let selectionNamespace, !reduceMotion {
            pill.matchedGeometryEffect(id: "sidebarActivePill", in: selectionNamespace)
        } else {
            pill
        }
    }
}
