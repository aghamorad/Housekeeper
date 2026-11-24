import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppRepairView: View {
    @Environment(\.uiStyle) private var style
    @EnvironmentObject private var appState: AppState
    @StateObject private var engine = AppRepairEngine.shared

    @State private var droppedAppURL: URL?
    @State private var selectedCandidate: AppRepairCandidate?
    @State private var isTargetedForDrop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                dropZone
                if let outcome = engine.latestOutcome {
                    repairOutcomeCard(outcome)
                }
                if let selected = selectedCandidate {
                    selectedAppCard(selected)
                }
                quarantinedAppsShelf
                educationalCard
            }
            .padding(32)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { HousekeepingBackdrop(style: style) }
        .onAppear {
            Task {
                await engine.scanInstalledApps()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            if let maintenanceMascot = HousekeeperMascot.loadMaintenance() {
                Image(nsImage: maintenanceMascot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "bandage.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(style.accent)
                    Text("Open a Downloaded App")
                        .font(style.isRetro ? style.titleFont : .system(size: 26, weight: .bold))
                }
                Text("Drag a downloaded app here to clear its download flag so macOS stops asking. Housekeeper only touches that flag — it never re-signs an app or changes the developer's signature.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ThemeButton(
                title: "Scan Apps",
                systemImage: "arrow.clockwise",
                isEnabled: !engine.isScanning
            ) {
                Task {
                    await engine.scanInstalledApps()
                }
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isTargetedForDrop ? style.accent : style.border,
                        style: StrokeStyle(lineWidth: isTargetedForDrop ? 2.5 : 1.5, dash: [8])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isTargetedForDrop ? style.accent.opacity(0.08) : style.rowBackground)
                    )

                VStack(spacing: 10) {
                    Image(systemName: isTargetedForDrop ? "arrow.down.app.fill" : "square.and.arrow.down")
                        .font(.system(size: 36))
                        .foregroundStyle(isTargetedForDrop ? style.accent : .secondary)

                    Text(isTargetedForDrop ? "Release to clear its download flag" : "Drag and drop a downloaded .app here")
                        .font(.system(size: 15, weight: .semibold))

                    Text("Or select an app manually from your disk")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    ThemeButton(
                        title: "Choose App from Disk…",
                        systemImage: "folder.badge.gearshape",
                        isPrimary: true
                    ) {
                        chooseApp()
                    }
                    .padding(.top, 4)
                }
                .padding(32)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension == "app" else { return }
                    DispatchQueue.main.async {
                        self.droppedAppURL = url
                        self.selectedCandidate = engine.diagnoseApp(at: url)
                    }
                }
                return true
            }
        }
    }

    // MARK: - Selected App Card

    private func selectedAppCard(_ candidate: AppRepairCandidate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path))
                    .resizable()
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(candidate.name)
                            .font(.system(size: 16, weight: .bold))
                        Text("v\(candidate.version)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(candidate.url.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if engine.isRepairing && engine.activeRepairApp == candidate.name {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Repairing…")
                            .font(.system(size: 12, weight: .medium))
                    }
                } else {
                    ThemeButton(
                        title: "Clear Download Flag",
                        systemImage: "checkmark.shield",
                        isPrimary: true
                    ) {
                        Task {
                            _ = await engine.repairApp(candidate: candidate)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 16) {
                statusChip(
                    title: "Quarantine Flag",
                    present: candidate.hasQuarantine,
                    okText: "Clean (No Quarantine)",
                    badText: "Quarantine Attached"
                )
                statusChip(
                    title: "Developer Signature",
                    present: !candidate.signatureValid,
                    okText: "Verifies",
                    badText: "Invalid — reinstall from its developer"
                )
            }
        }
        .padding(18)
        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.border, lineWidth: 1))
    }

    private func statusChip(title: String, present: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(present ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(present ? badText : okText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(present ? .primary : .secondary)
            }
        }
    }

    // MARK: - Repair Outcome Card

    private func repairOutcomeCard(_ outcome: AppRepairOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: outcome.succeeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(outcome.succeeded ? .green : .orange)
                Text(outcome.message)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                if outcome.succeeded {
                    ThemeButton(
                        title: "Launch App",
                        systemImage: "arrow.up.forward.app.fill",
                        isPrimary: true
                    ) {
                        NSWorkspace.shared.open(outcome.url)
                    }
                    ThemeButton(
                        title: "Reveal",
                        systemImage: "folder",
                        isPrimary: false
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([outcome.url])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(outcome.stepsTaken, id: \.self) { step in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                        Text(step)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(outcome.succeeded ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(outcome.succeeded ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Quarantined Apps Shelf

    private var quarantinedAppsShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apps with a Download Flag")
                        .font(.system(size: 16, weight: .bold))
                    Text("Only apps macOS will actually ask about. Clearing the flag does not change the app itself.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !engine.candidates.isEmpty {
                    ThemeButton(
                        title: "Clear All (\(engine.candidates.count))",
                        systemImage: "checkmark.shield",
                        isPrimary: true,
                        isEnabled: !engine.isRepairing
                    ) {
                        repairAll()
                    }
                }
            }

            if engine.isScanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Scanning /Applications for quarantine flags…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
            } else if engine.candidates.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)
                    Text("No app in /Applications is carrying a download flag. Nothing to do.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 8) {
                    ForEach(engine.candidates) { candidate in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path))
                                .resizable()
                                .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(candidate.name)
                                        .font(.system(size: 13, weight: .bold))
                                    Text("v\(candidate.version)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Text(candidate.statusText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            }

                            Spacer()

                            ThemeButton(
                                title: "Clear",
                                systemImage: "checkmark.shield",
                                isPrimary: true,
                                isEnabled: !engine.isRepairing
                            ) {
                                Task {
                                    _ = await engine.repairApp(candidate: candidate)
                                }
                            }
                        }
                        .padding(12)
                        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(style.border, lineWidth: 1))
                    }
                }
            }
        }
    }

    // MARK: - Educational Guide

    private var educationalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(style.accent)
                Text("Why does macOS say an app is damaged?")
                    .font(.system(size: 12, weight: .bold))
            }

            Text("When you download an app, macOS attaches a small marker called a quarantine flag (its system name is com.apple.quarantine). It does not mean the app is broken; it means “this arrived from the internet, ask first”. Clearing it is what lets the app open without a second trip to System Settings.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            Text("A signature is different. It is the developer's seal, embedded in the app, and it is what proves the app is really theirs. Housekeeper never replaces it: re-signing an app with a local signature destroys that proof and can stop the app launching — which is exactly what happened to Chrome once. If an app's own signature does not verify, reinstall it from its developer; there is no shortcut.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            Text("If macOS still refuses the app after the flag is cleared, open System Settings → Privacy & Security and press “Open Anyway” beside the app's name. That is macOS's own approval, and it is safer than rewriting the app.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(style.rowBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(style.border, lineWidth: 1))
    }

    // MARK: - Actions

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            self.droppedAppURL = url
            self.selectedCandidate = engine.diagnoseApp(at: url)
        }
    }

    private func repairAll() {
        Task {
            let list = engine.candidates
            for item in list {
                _ = await engine.repairApp(candidate: item)
            }
        }
    }

}
