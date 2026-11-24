import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One drop zone and one job: clear the download flag on an app you trust.
struct AppRepairView: View {
    @Environment(\.uiStyle) private var style
    @StateObject private var engine = AppRepairEngine.shared

    @State private var isTargetedForDrop = false
    @State private var lastURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                dropZone
                if let outcome = engine.latestOutcome {
                    outcomeCard(outcome)
                }
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { HousekeepingBackdrop(style: style) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 24))
                    .foregroundStyle(style.accent)
                Text("Open a Downloaded App")
                    .font(style.isRetro ? style.titleFont : .system(size: 26, weight: .bold))
            }
            Text("Drop an app here to remove the download flag macOS puts on files that arrive from the internet. That flag is the only reason it asks. Nothing else about the app is touched: its signature, permissions and contents stay exactly as the developer shipped them.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
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

                Text(isTargetedForDrop ? "Release to clear its download flag" : "Drag an app here")
                    .font(.system(size: 15, weight: .semibold))

                Text(engine.isWorking ? "Clearing the flag…" : "or choose one from disk")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                ThemeButton(
                    title: "Choose App…",
                    systemImage: "folder",
                    isPrimary: true,
                    isEnabled: !engine.isWorking
                ) {
                    chooseApp()
                }
                .padding(.top, 4)
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "app" else { return }
                Task { @MainActor in
                    lastURL = url
                    await engine.clearDownloadFlag(url: url)
                }
            }
            return true
        }
    }

    // MARK: - Outcome

    private func outcomeCard(_ outcome: AppRepairOutcome) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(outcome.succeeded ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 5) {
                Text(outcome.succeeded ? "\(outcome.appName) is ready to open" : "\(outcome.appName) needs a look")
                    .font(.system(size: 14, weight: .semibold))
                Text(outcome.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let url = Optional(outcome.url) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Show the app in Finder")
                .disabled(!FileManager.default.fileExists(atPath: url.path))
            }
        }
        .padding(16)
        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(style.border, lineWidth: 1)
        )
    }

    // MARK: - Picker

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose a downloaded app"
        panel.prompt = "Clear Download Flag"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        lastURL = url
        Task { await engine.clearDownloadFlag(url: url) }
    }
}
