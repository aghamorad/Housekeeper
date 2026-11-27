// Housekeeping — Cloudflare Clean VPN & AmneziaWG WARP Studio View

import AppKit
import SwiftUI

struct CloudflareVPNView: View {
    @ObservedObject var engine: CloudflareVPNEngine
    @Environment(\.uiStyle) private var style

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerBar
                statusBanners

                switch engine.selectedTab {
                case .warp:
                    warpSection
                case .tokenCleanIP:
                    tokenAndCleanIPSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: Binding(
            get: { engine.qrPayload != nil },
            set: { if !$0 { engine.qrPayload = nil } }
        )) {
            qrSheet
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(HousekeepingInk.redLifted)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(HousekeepingInk.red.opacity(0.16))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloudflare Clean VPN")
                        .font(.system(size: 18, weight: .bold))
                    Text("Build fresh AmneziaWG WARP configs (no account needed) or scan Clean Cloudflare IPs for your Worker/Pages proxy.")
                        .font(.callout)
                        .foregroundStyle(style.secondaryText)
                }

                Spacer()
            }

            Picker("Mode", selection: $engine.selectedTab) {
                ForEach(CloudflareVPNTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if let msg = engine.statusMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(msg)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") { engine.statusMessage = nil }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.secondaryText)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.35), lineWidth: 1))
        }

        if let err = engine.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") { engine.errorMessage = nil }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.secondaryText)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: - Mode 1: AmneziaWG WARP

    private var warpSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(title: "1. AmneziaWG WARP — Recommended First (No Cloudflare Account Needed)") {
                Text("Generates fresh encryption keys on your Mac, registers them with Cloudflare WARP, and wraps them with AmneziaWG cover packets so Iranian DPI cannot easily spot WireGuard. Because this uses WARP instead of a Cloudflare Worker, it never triggers Worker abuse flags.")
                    .font(.callout)
                    .foregroundStyle(style.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("WARP Endpoint")
                            .font(.callout.weight(.medium))
                            .frame(width: 140, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Use custom IP:port", isOn: $engine.useCustomWarpEndpoint)
                                .toggleStyle(.checkbox)
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
                        }
                    }

                    GridRow {
                        Text("Cover Packets (Junk)")
                            .font(.callout.weight(.medium))
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Junk Preset", selection: $engine.warpJunkPreset) {
                                ForEach(WarpJunkPreset.allCases) { preset in
                                    Text(preset.rawValue).tag(preset)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            if engine.warpJunkPreset == .custom {
                                HStack(spacing: 12) {
                                    labeledStepper("Jc", value: $engine.warpJc, range: 1...128)
                                    labeledStepper("Jmin", value: $engine.warpJmin, range: 1...1279)
                                    labeledStepper("Jmax", value: $engine.warpJmax, range: 1...1280)
                                }
                            }
                        }
                    }

                    GridRow {
                        Text("MTU & Keepalive")
                            .font(.callout.weight(.medium))
                        HStack(spacing: 16) {
                            labeledStepper("MTU", value: $engine.warpMTU, range: 576...1500)
                            labeledStepper("Keepalive (s)", value: $engine.warpKeepalive, range: 0...120)
                        }
                    }

                    GridRow {
                        Text("Obfuscation")
                            .font(.callout.weight(.medium))
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Amnezia 1.5 cover header (I1)", isOn: $engine.warpUse15)
                                .toggleStyle(.checkbox)
                            if engine.warpUse15 {
                                TextField("<b 0xf6ab3267fa>", text: $engine.warpI1)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            Toggle("Include Amnezia 3.0 / 3.1 lines (S3, S4)", isOn: $engine.warpUse3x)
                                .toggleStyle(.checkbox)
                            Toggle("Register key with Cloudflare WARP online (required once)", isOn: $engine.warpRegisterOnline)
                                .toggleStyle(.checkbox)
                        }
                    }
                }

                HStack(spacing: 10) {
                    ThemeButton(
                        title: engine.isGeneratingWarp ? "Generating…" : "Generate Fresh WARP Config",
                        isPrimary: true
                    ) {
                        engine.generateWarpConfig()
                    }
                    .disabled(engine.isGeneratingWarp)

                    Spacer()
                }
                .padding(.top, 4)
            }

            if !engine.generatedWarpConfig.isEmpty {
                sectionCard(title: "2. Your Ready-to-Import AmneziaWG Config") {
                    Text(engine.generatedWarpConfig)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))

                    HStack(spacing: 10) {
                        ThemeButton(title: "Copy Config", isPrimary: true) {
                            engine.copyText(engine.generatedWarpConfig, confirmation: "AmneziaWG WARP config copied. Paste or import it in AmneziaVPN.")
                        }
                        ThemeButton(title: "Save .conf File…") {
                            engine.saveTextToFile(engine.generatedWarpConfig, defaultName: "housekeeper-amnezia-warp.conf")
                        }
                        ThemeButton(title: "Show QR Code") {
                            engine.presentQR(title: "AmneziaWG WARP Config", payload: engine.generatedWarpConfig)
                        }
                        Spacer()
                    }

                    Text("Import in AmneziaVPN (macOS, iOS, or Android): tap + → File with connection settings → pick the saved .conf (or paste from clipboard). If it times out, pick the next WARP endpoint above and generate again.")
                        .font(.caption)
                        .foregroundStyle(style.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Mode 2: Cloudflare Token + Clean IP Scanner + VLESS/Fragment

    private var tokenAndCleanIPSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(title: "1. Connect Your Cloudflare API Token (Optional if You Already Have a Worker/Pages Host)") {
                VStack(alignment: .leading, spacing: 6) {
                    stepRow(1, "Click Open Cloudflare Token Page below and sign in to your free Cloudflare account.")
                    stepRow(2, "Click Create Token → choose the 'Edit Cloudflare Workers' template → Continue to summary → Create Token.")
                    stepRow(3, "Copy the token, click Paste Token here, and press Verify & Connect. Your token is stored only in your Mac's Keychain.")
                }

                HStack(spacing: 8) {
                    SecureField("Paste Cloudflare API token (cfat_…)", text: $engine.tokenInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))

                    ThemeButton(title: "Paste Token") {
                        engine.pasteTokenFromClipboard()
                    }
                    ThemeButton(title: engine.isVerifyingToken ? "Checking…" : "Verify & Connect", isPrimary: true) {
                        engine.verifyAndConnectToken()
                    }
                    .disabled(engine.isVerifyingToken)
                }

                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "https://dash.cloudflare.com/profile/api-tokens") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Open Cloudflare Token Page", systemImage: "arrow.up.right.square")
                            .font(.callout)
                    }
                    .buttonStyle(.link)

                    Spacer()

                    if engine.hasSavedToken {
                        ThemeButton(title: "Forget Saved Token", isDestructive: true) {
                            engine.forgetSavedToken()
                        }
                    }
                }

                if let account = engine.account {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Connected: \(account.name)")
                            .font(.callout.weight(.semibold))
                        if let sub = account.subdomain {
                            Text("· \(sub).workers.dev")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(style.secondaryText)
                        }
                        Spacer()
                    }

                    // Honest abuse-flag note based on real November 2026 Cloudflare behavior
                    Text("Safety tip: Cloudflare's automated scanner can flag proxy Workers (Error 1101). Always use a neutral name (never 'vpn', 'proxy', 'edge', or 'bpb'), keep it private for personal use only, and delete any flagged Worker immediately below.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        TextField("Neutral worker name", text: $engine.workerNameInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: 240)
                        ThemeButton(title: "New Neutral Name") {
                            engine.workerNameInput = CloudflareVPNEngine.generateNeutralWorkerName()
                        }
                        ThemeButton(title: engine.isDeployingWorker ? "Deploying…" : "Deploy Private Worker", isPrimary: true) {
                            engine.deployPrivateWorker()
                        }
                        .disabled(engine.isDeployingWorker)
                        Spacer()
                    }

                    if !engine.existingWorkers.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your Workers on this account")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(style.secondaryText)
                            ForEach(engine.existingWorkers) { worker in
                                HStack {
                                    Text(worker.id)
                                        .font(.system(.callout, design: .monospaced))
                                    Spacer()
                                    if let sub = account.subdomain {
                                        ThemeButton(title: "Use Host") {
                                            engine.workerHost = "\(worker.id).\(sub).workers.dev"
                                            engine.persistWorkerSettings()
                                            engine.statusMessage = "Selected \(engine.workerHost)"
                                        }
                                    }
                                    ThemeButton(title: "Delete", isDestructive: true) {
                                        engine.deleteWorker(named: worker.id)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }

            sectionCard(title: "2. Worker / Pages Host & VLESS Settings") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Worker / Pages Host")
                            .font(.callout.weight(.medium))
                            .frame(width: 150, alignment: .leading)
                        TextField("my-notes-42.example.workers.dev or my-site.pages.dev", text: $engine.workerHost)
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
                                engine.workerUUID = UUID().uuidString.lowercased()
                                engine.persistWorkerSettings()
                            }
                        }
                    }
                    GridRow {
                        Text("TLS Port & Fragment")
                            .font(.callout.weight(.medium))
                        HStack(spacing: 12) {
                            Picker("Port", selection: $engine.tlsPort) {
                                ForEach([443, 2053, 2083, 2087, 2096, 8443], id: \.self) { port in
                                    Text("\(port)").tag(port)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 90)

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

            sectionCard(title: "3. Scan Clean Cloudflare IPs (Turn VPN Off While Scanning)") {
                Text("A 'clean IP' is a normal Cloudflare edge IP that is not blocked or throttled on your current ISP (MCI, Irancell, Rightel, or home Wi-Fi). Housekeeper tests real TLS handshakes directly from this Mac and ranks the fastest ones.")
                    .font(.callout)
                    .foregroundStyle(style.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

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
                            engine.stopCleanIPScan()
                        }
                    } else {
                        ThemeButton(title: "Scan Clean IPs Now", isPrimary: true) {
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
                        }
                        Text(engine.scanStatusText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(style.secondaryText)
                    }
                }

                if !engine.cleanIPResults.isEmpty {
                    Divider()
                    let hasHost = !engine.workerHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                    HStack {
                        Text("Clean IPs Found (\(engine.cleanIPResults.count))")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        if hasHost {
                            ThemeButton(title: "Copy Top 5 VLESS Links") {
                                let top = engine.cleanIPResults.prefix(5).enumerated().map { idx, item in
                                    engine.buildVLESSLink(address: item.ip, label: "HK-Clean-\(idx + 1)-\(item.latencyMs)ms")
                                }.joined(separator: "\n")
                                engine.copyText(top, confirmation: "Copied top \(min(5, engine.cleanIPResults.count)) VLESS links. Import from clipboard in v2rayNG, Hiddify, or Streisand.")
                            }
                        }
                    }

                    ForEach(engine.cleanIPResults.prefix(15)) { item in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(item.latencyMs <= 120 ? Color.green : (item.latencyMs <= 260 ? Color.orange : Color.yellow))
                                .frame(width: 8, height: 8)

                            Text(item.ip)
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .frame(width: 136, alignment: .leading)

                            Text("\(item.latencyMs) ms")
                                .font(.system(.caption, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(style.secondaryText)
                                .frame(width: 64, alignment: .trailing)

                            Text(item.qualityLabel)
                                .font(.caption)
                                .foregroundStyle(style.secondaryText)

                            Spacer()

                            ThemeButton(title: "Copy IP") {
                                engine.copyText(item.ip, confirmation: "Copied clean IP \(item.ip).")
                            }

                            if hasHost {
                                ThemeButton(title: "VLESS", isPrimary: true) {
                                    let link = engine.buildVLESSLink(address: item.ip, label: "HK-\(item.ip)-\(item.latencyMs)ms")
                                    engine.copyText(link, confirmation: "Copied VLESS link for \(item.ip). Import from clipboard in Hiddify / Streisand / v2rayNG.")
                                }
                                ThemeButton(title: "Fragment JSON") {
                                    let json = engine.buildFragmentXrayJSON(address: item.ip)
                                    engine.copyText(json, confirmation: "Copied TLS-Fragment Xray JSON for \(item.ip).")
                                }
                                ThemeButton(title: "QR") {
                                    let link = engine.buildVLESSLink(address: item.ip, label: "HK-\(item.ip)-\(item.latencyMs)ms")
                                    engine.presentQR(title: "Clean IP \(item.ip) (\(item.latencyMs) ms)", payload: link)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Divider()
                Text("Quick Iranian Carrier Hostname Stopgaps (if you cannot scan on mobile data):")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.secondaryText)
                HStack(spacing: 8) {
                    let hasHost = !engine.workerHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ForEach(IranianCarrierPreset.all) { carrier in
                        ThemeButton(title: hasHost ? "Copy \(carrier.name) VLESS" : "Copy \(carrier.hostname)") {
                            if hasHost {
                                let link = engine.buildVLESSLink(address: carrier.hostname, label: "HK-\(carrier.id.uppercased())")
                                engine.copyText(link, confirmation: "Copied \(carrier.name) VLESS config.")
                            } else {
                                engine.copyText(carrier.hostname, confirmation: "Copied \(carrier.hostname).")
                            }
                        }
                    }
                    Spacer()
                }
            }
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
                    .padding(12)
                    .background(Color.white)
                    .cornerRadius(10)
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
                    ThemeButton(title: "Copy Text") {
                        engine.copyText(payload, confirmation: "Copied config text.")
                    }
                }
                ThemeButton(title: "Done", isPrimary: true) {
                    engine.qrPayload = nil
                }
            }
        }
        .padding(24)
        .frame(minWidth: 340)
    }

    // MARK: - Helpers

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
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
