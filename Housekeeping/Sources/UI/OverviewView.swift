import SwiftUI
import AppKit

/// The starting point keeps measurements separate from actions. Every number
/// comes from the filesystem or a completed scan, and every row opens a tool.
struct OverviewView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.uiStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var vitals = SystemVitals.shared
    @State private var mascotHovered = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headerBar

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

                groupedSection(title: "System Care") {
                    OverviewToolRow(title: "Clean Up", detail: "Review caches, installers, and removable app data.", icon: "sparkles") {
                        appState.showClean = true
                    }
                    Divider().padding(.leading, 44)
                    OverviewToolRow(title: "Update Apps", detail: "Check Mac apps, Homebrew packages, and standalone tools.", icon: "arrow.triangle.2.circlepath") {
                        appState.showUpdateList = true
                    }
                    Divider().padding(.leading, 44)
                    OverviewToolRow(title: "Uninstall Apps", detail: "Remove applications along with their leftover support files.", icon: "xmark.app") {
                        appState.showUninstaller = true
                    }
                    Divider().padding(.leading, 44)
                    OverviewToolRow(title: "Fix Permissions", detail: "Audit root-owned dotfiles, dead proxies, and broken launch agents.", icon: "cross.case") {
                        appState.showPermissionsDoctor = true
                    }
                }

                groupedSection(title: "Network & Speed") {
                    OverviewToolRow(title: "Speed Test", detail: "Measure download, upload, ping, and responsiveness.", icon: "speedometer") {
                        appState.showSpeedTest = true
                    }
                    Divider().padding(.leading, 44)
                    OverviewToolRow(title: "Route Sweep", detail: "Test VPN locations and protocols for reachability.", icon: "network") {
                        appState.showRoutes = true
                    }
                    Divider().padding(.leading, 44)
                    OverviewToolRow(title: "DNS Switcher", detail: "Switch DNS presets or restore automatic router DNS.", icon: "globe") {
                        appState.showDNSSwitcher = true
                    }
                    Divider().padding(.leading, 44)
                    OverviewToolRow(title: "VPN Tunnels", detail: "Inspect active tunnel interfaces and VPN services.", icon: "lock.shield") {
                        appState.showVPNTunnels = true
                    }
                }

                groupedSection(title: "Hardware & Studios") {
                    OverviewToolRow(title: "Cooling & Fans", detail: "Read thermal sensors and adjust fan speed.", icon: "fan") {
                        appState.showFanControl = true
                    }
                    Divider().padding(.leading, 44)
                    OverviewToolRow(title: "Battery Health", detail: "Cycle count, battery wear, and sleep drain checks.", icon: "battery.100") {
                        appState.showBatteryHealth = true
                    }
                    Divider().padding(.leading, 44)
                    OverviewToolRow(title: "Space Lens", detail: "Browse folders by real disk usage.", icon: "internaldrive") {
                        appState.showDiskBrowser = true
                    }
                    Divider().padding(.leading, 44)
                    OverviewToolRow(title: "Local AI Models", detail: "See installed MLX and Ollama models and manage memory.", icon: "cpu") {
                        appState.showLocalModels = true
                    }
                    Divider().padding(.leading, 44)
                    OverviewToolRow(title: "MediaDock 9 & Bookbind", detail: "Open Media Studio or Bookbind audiobook builder from the sidebar.", icon: "play.rectangle") {
                        appState.showMediaDock = true
                    }
                }
            }
            .frame(maxWidth: 940, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background { HousekeepingBackdrop(style: style) }
    }

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
                appState.showHousekeeper = true
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.65), value: mascotHovered)
            .help("Hover to wake the Housekeeper, or click to chat.")

            VStack(alignment: .leading, spacing: 3) {
                Text("Housekeeper")
                    .font(style.isRetro ? style.titleFont : .system(size: 25, weight: .semibold, design: .rounded))
                Text("Reads storage, vitals, and network health. Moves nothing until you approve.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Label(Host.current().localizedName ?? "This Mac", systemImage: "desktopcomputer")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func groupedSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
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
                Image(systemName: icon)
                    .font(.system(size: 15, weight: hovering ? .semibold : .regular))
                    .foregroundStyle(style.accent)
                    .frame(width: 24, alignment: .center)
                    .scaleEffect(hovering && !reduceMotion ? 1.08 : 1.0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(style.text)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? style.accent : Color.secondary.opacity(0.45))
                    .offset(x: hovering && !reduceMotion ? 2.5 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(hovering ? style.accent.opacity(0.065) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(HousekeepingPressableStyle(pressedScale: 0.992, haptic: false))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.8), value: hovering)
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
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? style.accent : (hovering ? style.text : .secondary))
                    .frame(width: 18)
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
                        .fill(style.groupingBackground.opacity(0.60))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HousekeepingPressableStyle(pressedScale: 0.975, haptic: false))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var activePill: some View {
        let pill = ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(style.rowSelection)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(style.accent.opacity(0.24), lineWidth: 0.75)
                )
        }
        if let selectionNamespace, !reduceMotion {
            pill.matchedGeometryEffect(id: "sidebarActivePill", in: selectionNamespace)
        } else {
            pill
        }
    }
}
