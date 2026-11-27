// Housekeeping — Cloudflare Clean VPN & AmneziaWG WARP Studio View
//
// Calm, tactile macOS Operate-mode studio: gliding matchedGeometryEffect tab bar,
// signature .housekeepingCard surfaces, event-driven scan radar (0.0% idle CPU),
// proportional latency bars, trackpad haptics, and progressive disclosure.

import AppKit
import SwiftUI

struct CloudflareVPNView: View {
    @ObservedObject var engine: CloudflareVPNEngine
    @Environment(\.uiStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var tabNamespace
    @State private var showWarpAdvanced = false
    @State private var showTokenGuide = false
    @State private var copiedKey: String?
    @State private var hoveredIP: String?
    @State private var radarAngle: Double = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerSection
                toastBanners

                Group {
                    switch engine.selectedTab {
                    case .warp:
                        warpStudio
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    case .tokenCleanIP:
                        tokenAndCleanIPStudio
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .animation(HousekeepingMotion.settle, value: engine.selectedTab)
            }
            .padding(22)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .sheet(isPresented: Binding(
            get: { engine.qrPayload != nil },
            set: { if !$0 { engine.qrPayload = nil } }
        )) {
            qrSheet
        }
    }

    // MARK: - Header & Gliding Pill Switcher

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(HousekeepingInk.red.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(HousekeepingInk.redLifted.opacity(0.35), lineWidth: 1)
                        )
                    Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(HousekeepingInk.redLifted)
                        .scaleEffect((engine.isGeneratingWarp || engine.isScanningIPs) && !reduceMotion ? 1.08 : 1.0)
                        .animation(HousekeepingMotion.settle, value: engine.isGeneratingWarp || engine.isScanningIPs)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Cloudflare Clean VPN")
                        .font(.system(size: 20, weight: .bold))
                    Text("One-click AmneziaWG WARP configs (no account needed) or live Clean Cloudflare IP scanning for VLESS & Fragment.")
                        .font(.callout)
                        .foregroundStyle(style.secondaryText)
                }

                Spacer()

                statusPill
            }

            glidingTabSwitcher
        }
    }

    private var statusPill: some View {
        let isBusy = engine.isGeneratingWarp || engine.isScanningIPs || engine.isVerifyingToken || engine.isDeployingWorker
        let label: String
        let tint: Color
        if engine.isScanningIPs {
            label = "Scanning IPs…"
            tint = .orange
        } else if engine.isGeneratingWarp {
            label = "Registering WARP…"
            tint = HousekeepingInk.redLifted
        } else if engine.account != nil {
            label = "Cloudflare Connected"
            tint = .green
        } else if engine.warpRegisteredSuccessfully {
            label = "WARP Ready"
            tint = .green
        } else {
            label = "Ready"
            tint = style.secondaryText
        }

        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .scaleEffect(isBusy && !reduceMotion ? 1.25 : 1.0)
                .animation(isBusy ? HousekeepingMotion.breathe : .default, value: isBusy)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isBusy ? tint : style.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().stroke(tint.opacity(0.28), lineWidth: 1))
    }

    private var glidingTabSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(CloudflareVPNTab.allCases) { tab in
                let selected = engine.selectedTab == tab
                Button {
                    HousekeepingFeedback.press()
                    withAnimation(HousekeepingMotion.travel) {
                        engine.selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab == .warp ? "bolt.shield.fill" : "network.badge.shield.half.filled")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? Color.white : style.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(HousekeepingInk.red)
                                .matchedGeometryEffect(id: "cfvpn.tab.pill", in: tabNamespace)
                                .shadow(color: HousekeepingInk.red.opacity(0.28), radius: 6, y: 2)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }

    // MARK: - Animated Toast Banners

    @ViewBuilder
    private var toastBanners: some View {
        if let msg = engine.statusMessage {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.green)
                Text(msg)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") {
                    withAnimation(HousekeepingMotion.hover) { engine.statusMessage = nil }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(style.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.green.opacity(0.32), lineWidth: 1))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        if let err = engine.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") {
                    withAnimation(HousekeepingMotion.hover) { engine.errorMessage = nil }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(style.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.32), lineWidth: 1))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Mode 1: AmneziaWG WARP Studio

    private var warpStudio: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AmneziaWG WARP Generator")
                            .font(.system(size: 16, weight: .bold))
                        Text("Recommended first. Builds fresh Curve25519 keys on your Mac, registers with Cloudflare WARP, and adds AmneziaWG cover packets. Needs no Cloudflare account and never triggers Worker abuse flags.")
                            .font(.callout)
                            .foregroundStyle(style.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                Divider()

                // Simple 2-row everyday controls
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Text("WARP Address")
                            .font(.callout.weight(.medium))
                            .frame(width: 130, alignment: .leading)
                        HStack(spacing: 8) {
                            if engine.useCustomWarpEndpoint {
                                TextField("162.159.193.1:2408", text: $engine.customWarpEndpoint)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.callout, design: .monospaced))
                            } else {
                                Picker("Endpoint", selection: $engine.selectedWarpEndpoint) {
                                    ForEach(WarpEndpointCandidate.curated) { item in
                                        Text(item.label).tag(item.endpointString)
                                    }
                                }
                                .labelsHidden()
                            }
                            Toggle("Custom", isOn: $engine.useCustomWarpEndpoint)
                                .toggleStyle(.checkbox)
                        }
                    }

                    GridRow {
                        Text("Cover Packets")
                            .font(.callout.weight(.medium))
                        Picker("Junk Preset", selection: $engine.warpJunkPreset) {
                            ForEach(WarpJunkPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                // Collapsible Advanced Settings (75-Year-Old Rule: hidden until wanted)
                DisclosureGroup(isExpanded: $showWarpAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        if engine.warpJunkPreset == .custom {
                            HStack(spacing: 14) {
                                labeledStepper("Jc", value: $engine.warpJc, range: 1...128)
                                labeledStepper("Jmin", value: $engine.warpJmin, range: 1...1279)
                                labeledStepper("Jmax", value: $engine.warpJmax, range: 1...1280)
                            }
                        }
                        HStack(spacing: 16) {
                            labeledStepper("MTU", value: $engine.warpMTU, range: 576...1500)
                            labeledStepper("Keepalive (s)", value: $engine.warpKeepalive, range: 0...120)
                        }
                        Toggle("Amnezia 1.5 cover header (I1)", isOn: $engine.warpUse15)
                            .toggleStyle(.checkbox)
                        if engine.warpUse15 {
                            TextField("<b 0xf6ab3267fa>", text: $engine.warpI1)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: 320)
                        }
                        Toggle("Include Amnezia 3.0 / 3.1 anti-DPI timing & RandomTrailers", isOn: $engine.warpUse3x)
                            .toggleStyle(.checkbox)
                        Toggle("Register key with Cloudflare WARP online (required once)", isOn: $engine.warpRegisterOnline)
                            .toggleStyle(.checkbox)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Advanced Obfuscation, MTU & Version Options")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(style.secondaryText)
                }

                HStack(spacing: 12) {
                    ThemeButton(
                        title: engine.isGeneratingWarp ? "Generating & Registering…" : "Generate Fresh WARP Config",
                        isPrimary: true
                    ) {
                        HousekeepingFeedback.press()
                        engine.generateWarpConfig()
                    }
                    .disabled(engine.isGeneratingWarp)

                    if engine.isGeneratingWarp {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(18)
            .housekeepingCard(cornerRadius: 14, prominent: true)

            if !engine.generatedWarpConfig.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(
                            engine.warpRegisteredSuccessfully ? "Ready to Import in AmneziaVPN" : "Local Draft Config",
                            systemImage: engine.warpRegisteredSuccessfully ? "checkmark.seal.fill" : "doc.text"
                        )
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(engine.warpRegisteredSuccessfully ? Color.green : style.text)
                        Spacer()
                    }

                    Text(engine.generatedWarpConfig)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))

                    HStack(spacing: 10) {
                        ThemeButton(
                            title: copiedKey == "warp" ? "Copied" : "Copy Config",
                            isPrimary: true
                        ) {
                            triggerCopy(key: "warp", text: engine.generatedWarpConfig, note: "AmneziaWG WARP config copied. Paste or import in AmneziaVPN.")
                        }
                        ThemeButton(title: "Save .conf File…") {
                            HousekeepingFeedback.press()
                            engine.saveTextToFile(engine.generatedWarpConfig, defaultName: "housekeeper-amnezia-warp.conf")
                        }
                        ThemeButton(title: "Show QR Code") {
                            HousekeepingFeedback.press()
                            engine.presentQR(title: "AmneziaWG WARP Config", payload: engine.generatedWarpConfig)
                        }
                        Spacer()
                    }

                    Text("In AmneziaVPN (macOS, iOS, or Android): tap + → File with connection settings → pick the saved .conf (or paste from clipboard). If it times out on your carrier, pick the next WARP address above and generate again.")
                        .font(.caption)
                        .foregroundStyle(style.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .housekeepingCard(cornerRadius: 14, highlighted: true)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(HousekeepingMotion.settle, value: engine.generatedWarpConfig.isEmpty)
    }

    // MARK: - Mode 2: Cloudflare Token & Clean IP Scanner

    private var tokenAndCleanIPStudio: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Card 1: Token & Worker Management
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1. Cloudflare API Token")
                            .font(.system(size: 15, weight: .bold))
                        Text("Optional if you already have a BPB or Pages hostname below. Stored only in macOS Keychain.")
                            .font(.caption)
                            .foregroundStyle(style.secondaryText)
                    }
                    Spacer()
                    Button {
                        HousekeepingFeedback.press()
                        if let url = URL(string: "https://dash.cloudflare.com/profile/api-tokens") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Open Cloudflare Token Page", systemImage: "arrow.up.right.square")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.link)
                }

                DisclosureGroup(isExpanded: $showTokenGuide) {
                    VStack(alignment: .leading, spacing: 6) {
                        stepRow(1, "Click Open Cloudflare Token Page above and sign in to your free Cloudflare account.")
                        stepRow(2, "Click Create Token → choose 'Edit Cloudflare Workers' template → Continue to summary → Create Token.")
                        stepRow(3, "Copy the token, click Paste Token below, and press Verify & Connect.")
                    }
                    .padding(.top, 6)
                } label: {
                    Text("How to get a free Cloudflare token (3 steps)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(style.secondaryText)
                }

                HStack(spacing: 8) {
                    SecureField("Paste Cloudflare API token (cfat_…)", text: $engine.tokenInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))

                    ThemeButton(title: "Paste") {
                        HousekeepingFeedback.press()
                        engine.pasteTokenFromClipboard()
                    }
                    ThemeButton(
                        title: engine.isVerifyingToken ? "Checking…" : "Verify & Connect",
                        isPrimary: true
                    ) {
                        HousekeepingFeedback.press()
                        engine.verifyAndConnectToken()
                    }
                    .disabled(engine.isVerifyingToken)

                    if engine.hasSavedToken {
                        ThemeButton(title: "Forget", isDestructive: true) {
                            HousekeepingFeedback.press()
                            engine.forgetSavedToken()
                        }
                    }
                }

                if let account = engine.account {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(account.name)
                            .font(.callout.weight(.semibold))
                        if let sub = account.subdomain {
                            Text("\(sub).workers.dev")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(style.secondaryText)
                        }
                        Spacer()
                    }

                    Text("Safety tip: Cloudflare's automated scanner can flag proxy Workers (Error 1101). Always pick a neutral name, keep it private for personal use only, and click Delete below if a Worker is ever flagged.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        TextField("Neutral worker name", text: $engine.workerNameInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: 230)
                        ThemeButton(title: "Random Neutral Name") {
                            HousekeepingFeedback.press()
                            engine.workerNameInput = CloudflareVPNEngine.generateNeutralWorkerName()
                        }
                        ThemeButton(
                            title: engine.isDeployingWorker ? "Deploying…" : "Deploy Private Worker",
                            isPrimary: true
                        ) {
                            HousekeepingFeedback.press()
                            engine.deployPrivateWorker()
                        }
                        .disabled(engine.isDeployingWorker)
                        Spacer()
                    }

                    if !engine.existingWorkers.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Workers on this account")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(style.secondaryText)
                            ForEach(engine.existingWorkers) { worker in
                                HStack {
                                    Image(systemName: "bolt.horizontal.circle")
                                        .foregroundStyle(style.secondaryText)
                                    Text(worker.id)
                                        .font(.system(.callout, design: .monospaced))
                                    Spacer()
                                    if let sub = account.subdomain {
                                        ThemeButton(title: "Use Host") {
                                            HousekeepingFeedback.press()
                                            engine.workerHost = "\(worker.id).\(sub).workers.dev"
                                            engine.persistWorkerSettings()
                                            engine.statusMessage = "Selected \(engine.workerHost)"
                                        }
                                    }
                                    ThemeButton(title: "Delete", isDestructive: true) {
                                        HousekeepingFeedback.press()
                                        engine.deleteWorker(named: worker.id)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(18)
            .housekeepingCard(cornerRadius: 14)

            // Card 2: Host, UUID & Fragment
            VStack(alignment: .leading, spacing: 12) {
                Text("2. Worker / Pages Host & TLS Fragment")
                    .font(.system(size: 15, weight: .bold))

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Worker / Pages Host")
                            .font(.callout.weight(.medium))
                            .frame(width: 145, alignment: .leading)
                        TextField("amber-notes-42.example.workers.dev or my-site.pages.dev", text: $engine.workerHost)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .onChange(of: engine.workerHost) { _ in engine.persistWorkerSettings() }
                    }
                    GridRow {
                        Text("UUID")
                            .font(.callout.weight(.medium))
                        HStack(spacing: 8) {
                            TextField("UUID", text: $engine.workerUUID)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                                .onChange(of: engine.workerUUID) { _ in engine.persistWorkerSettings() }
                            ThemeButton(title: "New UUID") {
                                HousekeepingFeedback.press()
                                engine.workerUUID = UUID().uuidString.lowercased()
                                engine.persistWorkerSettings()
                            }
                        }
                    }
                    GridRow {
                        Text("Port & Fragment")
                            .font(.callout.weight(.medium))
                        HStack(spacing: 10) {
                            Picker("Port", selection: $engine.tlsPort) {
                                ForEach([443, 2053, 2083, 2087, 2096, 8443], id: \.self) { port in
                                    Text("\(port)").tag(port)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 88)

                            Picker("Fragment", selection: $engine.fragmentPreset) {
                                ForEach(FragmentPreset.allCases) { preset in
                                    Text(preset.rawValue).tag(preset)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
            }
            .padding(18)
            .housekeepingCard(cornerRadius: 14)

            // Card 3: Live Clean Cloudflare IP Scanner
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("3. Scan Clean Cloudflare IPs")
                            .font(.system(size: 15, weight: .bold))
                        Text("Turn your VPN OFF while scanning so Housekeeper tests real TLS handshakes directly on your ISP.")
                            .font(.callout)
                            .foregroundStyle(style.secondaryText)
                    }
                    Spacer()
                    if engine.isScanningIPs {
                        radarBadge
                    }
                }

                HStack(spacing: 10) {
                    Picker("Depth", selection: $engine.scanDepth) {
                        ForEach(CleanIPScanDepth.allCases) { depth in
                            Text(depth.rawValue).tag(depth)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)

                    if engine.isScanningIPs {
                        ThemeButton(title: "Stop Scan", isDestructive: true) {
                            HousekeepingFeedback.press()
                            engine.stopCleanIPScan()
                        }
                    } else {
                        ThemeButton(title: "Scan Clean IPs Now", isPrimary: true) {
                            HousekeepingFeedback.press()
                            engine.startCleanIPScan()
                        }
                    }
                    Spacer()
                }

                if engine.isScanningIPs || !engine.scanStatusText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if engine.isScanningIPs {
                            ProgressView(value: engine.scanProgress)
                                .progressViewStyle(.linear)
                                .animation(HousekeepingMotion.count, value: engine.scanProgress)
                        }
                        Text(engine.scanStatusText)
                            .font(.system(.caption, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(style.secondaryText)
                    }
                }

                if !engine.cleanIPResults.isEmpty {
                    Divider()
                    let hasHost = !engine.workerHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                    HStack {
                        Text("Clean IPs Ranked by Speed (\(engine.cleanIPResults.count))")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        if hasHost {
                            ThemeButton(
                                title: copiedKey == "top5" ? "Copied Top 5" : "Copy Top 5 VLESS Links",
                                isPrimary: true
                            ) {
                                let top = engine.cleanIPResults.prefix(5).enumerated().map { idx, item in
                                    engine.buildVLESSLink(address: item.ip, label: "HK-Clean-\(idx + 1)-\(item.latencyMs)ms")
                                }.joined(separator: "\n")
                                triggerCopy(key: "top5", text: top, note: "Copied top \(min(5, engine.cleanIPResults.count)) VLESS links. Import from clipboard in Hiddify, Streisand, or v2rayNG.")
                            }
                        }
                    }

                    VStack(spacing: 4) {
                        ForEach(engine.cleanIPResults.prefix(15)) { item in
                            cleanIPRow(item: item, hasHost: hasHost)
                        }
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Iranian Carrier Stopgaps (if you cannot scan on mobile data):")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(style.secondaryText)
                    HStack(spacing: 8) {
                        let hasHost = !engine.workerHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ForEach(IranianCarrierPreset.all) { carrier in
                            let key = "carrier-\(carrier.id)"
                            ThemeButton(title: copiedKey == key ? "Copied" : (hasHost ? "\(carrier.name) VLESS" : carrier.hostname)) {
                                if hasHost {
                                    let link = engine.buildVLESSLink(address: carrier.hostname, label: "HK-\(carrier.id.uppercased())")
                                    triggerCopy(key: key, text: link, note: "Copied \(carrier.name) VLESS config.")
                                } else {
                                    triggerCopy(key: key, text: carrier.hostname, note: "Copied \(carrier.hostname).")
                                }
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(18)
            .housekeepingCard(cornerRadius: 14, prominent: true)
        }
    }

    private func cleanIPRow(item: CleanIPResult, hasHost: Bool) -> some View {
        let isHovered = hoveredIP == item.ip
        let qualityColor: Color = item.latencyMs <= 120 ? .green : (item.latencyMs <= 260 ? .orange : .yellow)
        let barFraction = max(0.15, min(1.0, 1.0 - (Double(item.latencyMs) / 500.0)))

        return HStack(spacing: 10) {
            Circle()
                .fill(qualityColor)
                .frame(width: 8, height: 8)

            Text(item.ip)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .frame(width: 132, alignment: .leading)

            // Proportional speed bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(qualityColor.opacity(0.8))
                        .frame(width: geo.size.width * barFraction)
                }
            }
            .frame(width: 56, height: 5)

            Text("\(item.latencyMs) ms")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(qualityColor)
                .frame(width: 56, alignment: .trailing)

            Spacer()

            ThemeButton(title: copiedKey == "ip-\(item.ip)" ? "Copied" : "IP") {
                triggerCopy(key: "ip-\(item.ip)", text: item.ip, note: "Copied clean IP \(item.ip).")
            }

            if hasHost {
                ThemeButton(
                    title: copiedKey == "vless-\(item.ip)" ? "Copied" : "VLESS",
                    isPrimary: true
                ) {
                    let link = engine.buildVLESSLink(address: item.ip, label: "HK-\(item.ip)-\(item.latencyMs)ms")
                    triggerCopy(key: "vless-\(item.ip)", text: link, note: "Copied VLESS link for \(item.ip).")
                }
                ThemeButton(title: copiedKey == "frag-\(item.ip)" ? "Copied" : "Fragment JSON") {
                    let json = engine.buildFragmentXrayJSON(address: item.ip)
                    triggerCopy(key: "frag-\(item.ip)", text: json, note: "Copied TLS-Fragment Xray JSON for \(item.ip).")
                }
                ThemeButton(title: "QR") {
                    HousekeepingFeedback.press()
                    let link = engine.buildVLESSLink(address: item.ip, label: "HK-\(item.ip)-\(item.latencyMs)ms")
                    engine.presentQR(title: "Clean IP \(item.ip) (\(item.latencyMs) ms)", payload: link)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? HousekeepingInk.red.opacity(0.10) : Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isHovered ? HousekeepingInk.redLifted.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .onHover { hovered in
            withAnimation(HousekeepingMotion.hover) {
                hoveredIP = hovered ? item.ip : nil
            }
        }
    }

    private var radarBadge: some View {
        ZStack {
            Circle()
                .stroke(HousekeepingInk.red.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.35)
                .stroke(HousekeepingInk.redLifted, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(radarAngle))
        }
        .frame(width: 24, height: 24)
        .onAppear {
            guard !reduceMotion else { return }
            radarAngle = 0
            withAnimation(HousekeepingMotion.orbit) {
                radarAngle = 360
            }
        }
        .onDisappear {
            radarAngle = 0
        }
    }

    // MARK: - QR Sheet

    private var qrSheet: some View {
        VStack(spacing: 16) {
            Text(engine.qrTitle)
                .font(.headline)
            if let payload = engine.qrPayload, let img = CloudflareVPNEngine.makeQRCodeImage(from: payload) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, height: 260)
                    .padding(14)
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            } else {
                Text("Config is too large for a single QR code. Use Copy or Save File instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Scan with Streisand, Hiddify, FoXray, v2rayNG, or AmneziaVPN on your phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let payload = engine.qrPayload {
                    ThemeButton(title: copiedKey == "qr" ? "Copied" : "Copy Text") {
                        triggerCopy(key: "qr", text: payload, note: "Copied config text.")
                    }
                }
                ThemeButton(title: "Done", isPrimary: true) {
                    HousekeepingFeedback.press()
                    engine.qrPayload = nil
                }
            }
        }
        .padding(24)
        .frame(minWidth: 360)
    }

    // MARK: - Helpers

    private func triggerCopy(key: String, text: String, note: String) {
        HousekeepingFeedback.press()
        engine.copyText(text, confirmation: note)
        withAnimation(HousekeepingMotion.press) {
            copiedKey = key
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copiedKey == key {
                withAnimation(HousekeepingMotion.hover) {
                    copiedKey = nil
                }
            }
        }
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 20, height: 20)
                .background(Circle().fill(HousekeepingInk.red.opacity(0.18)))
                .foregroundStyle(HousekeepingInk.redLifted)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeledStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .font(.caption.weight(.medium))
                .foregroundStyle(style.secondaryText)
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .font(.system(.callout, design: .monospaced))
                    .monospacedDigit()
            }
        }
    }
}
