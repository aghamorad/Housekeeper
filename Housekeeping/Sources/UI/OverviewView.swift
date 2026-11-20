import SwiftUI
import AppKit

/// The starting point keeps measurements separate from actions. Every number
/// comes from the filesystem or a completed scan, and every row opens a tool.
struct OverviewView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.uiStyle) private var style
    @ObservedObject private var vitals = SystemVitals.shared

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
                    .buttonStyle(.plain)
                    .housekeepingCard(cornerRadius: 12)
                }

                groupedSection(title: "System Care") {
                    toolRow(title: "Clean Up", detail: "Review caches, installers, and removable app data.", icon: "sparkles") {
                        appState.showClean = true
                    }
                    Divider().padding(.leading, 44)
                    toolRow(title: "Update Apps", detail: "Check Mac apps, Homebrew packages, and standalone tools.", icon: "arrow.triangle.2.circlepath") {
                        appState.showUpdateList = true
                    }
                    Divider().padding(.leading, 44)
                    toolRow(title: "Uninstall Apps", detail: "Remove applications along with their leftover support files.", icon: "xmark.app") {
                        appState.showUninstaller = true
                    }
                    Divider().padding(.leading, 44)
                    toolRow(title: "Fix Permissions", detail: "Audit root-owned dotfiles, dead proxies, and broken launch agents.", icon: "cross.case") {
                        appState.showPermissionsDoctor = true
                    }
                }

                groupedSection(title: "Network & Speed") {
                    toolRow(title: "Speed Test", detail: "Measure download, upload, ping, and responsiveness.", icon: "speedometer") {
                        appState.showSpeedTest = true
                    }
                    Divider().padding(.leading, 44)
                    toolRow(title: "Route Sweep", detail: "Test VPN locations and protocols for reachability.", icon: "network") {
                        appState.showRoutes = true
                    }
                    Divider().padding(.leading, 44)
                    toolRow(title: "DNS Switcher", detail: "Switch DNS presets or restore automatic router DNS.", icon: "globe") {
                        appState.showDNSSwitcher = true
                    }
                    Divider().padding(.leading, 44)
                    toolRow(title: "VPN Tunnels", detail: "Inspect active tunnel interfaces and VPN services.", icon: "lock.shield") {
                        appState.showVPNTunnels = true
                    }
                }

                groupedSection(title: "Hardware & Studios") {
                    toolRow(title: "Cooling & Fans", detail: "Read thermal sensors and adjust fan speed.", icon: "fan") {
                        appState.showFanControl = true
                    }
                    Divider().padding(.leading, 44)
                    toolRow(title: "Battery Health", detail: "Cycle count, battery wear, and sleep drain checks.", icon: "battery.100") {
                        appState.showBatteryHealth = true
                    }
                    Divider().padding(.leading, 44)
                    toolRow(title: "Space Lens", detail: "Browse folders by real disk usage.", icon: "internaldrive") {
                        appState.showDiskBrowser = true
                    }
                    Divider().padding(.leading, 44)
                    toolRow(title: "Local AI Models", detail: "See installed MLX and Ollama models and manage memory.", icon: "cpu") {
                        appState.showLocalModels = true
                    }
                    Divider().padding(.leading, 44)
                    toolRow(title: "MediaDock 9 & Bookbind", detail: "Open Media Studio or Bookbind audiobook builder from the sidebar.", icon: "play.rectangle") {
                        appState.showMediaDock = true
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background { HousekeepingBackdrop(style: style) }
    }

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                content()
            }
            .housekeepingCard(cornerRadius: 12)
        }
    }

    private func toolRow(title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(style.accent)
                    .frame(width: 24, alignment: .center)
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
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 0, hovered: Color.primary.opacity(0.035))
        .accessibilityLabel(title)
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

private struct OverviewStorageCard: View {
    let scan: () -> Void
    let browse: () -> Void
    @Environment(\.uiStyle) private var style
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
                        Capsule().fill(style.accent)
                            .frame(width: max(0, geometry.size.width * (reading?.fraction ?? 0)))
                    }
                }
                .frame(height: 6)

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
        .housekeepingCard(cornerRadius: 12, prominent: true)
        .task {
            reading = await Task.detached(priority: .utility) {
                let home = FileManager.default.homeDirectoryForCurrentUser
                guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey]),
                      let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil as VolumeReading? }
                return VolumeReading(name: values.volumeName ?? "Mac Storage", total: Int64(total), available: Int64(available))
            }.value
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
            .buttonStyle(.plain)
            .housekeepingCard(cornerRadius: 12)
        }
    }
}

struct SidebarNavigationRow: View {
    @Environment(\.uiStyle) private var style
    let title: String
    let icon: String
    let selected: Bool
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor : (hovering ? Color.primary.opacity(0.06) : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
