// Housekeeping — Speed Test View
//
// Native macOS layout: restrained typography, system surfaces, clear numbers,
// and a plain-English summary.

import AppKit
import SwiftUI

struct SpeedTestView: View {
    @ObservedObject private var engine = SpeedTestEngine.shared
    @Environment(\.uiStyle) private var style
    @State private var copiedID: UUID?

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                controlsCard
                metricsRow
                if let result = engine.latestResult, !engine.isRunning {
                    verdictCard(result)
                }
                if !engine.history.isEmpty {
                    historySection
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background { HousekeepingBackdrop(style: style) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speed Test")
                    .font(style.isRetro ? style.titleFont : .system(size: 25, weight: .semibold, design: .rounded))
                Text("Measures your current download, upload, and latency. Changes no network settings.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if engine.isRunning {
                ThemeButton(title: "Stop", systemImage: "stop.fill", isPrimary: false) {
                    engine.cancel()
                }
            } else {
                ThemeButton(title: "Run Speed Test", systemImage: "speedometer", isPrimary: true) {
                    engine.start()
                }
            }
        }
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Test Engine")
                        .font(.system(size: 13, weight: .semibold))
                    Text(engine.provider.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("Engine", selection: $engine.provider) {
                    ForEach(SpeedTestProvider.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                .disabled(engine.isRunning)
            }

            if engine.isRunning {
                Divider()
                ProgressBar(
                    fraction: engine.provider == .apple ? nil : engine.progress,
                    caption: engine.phase.label,
                    detail: engine.liveInterface.map { "Testing over \($0)" }
                )
            } else if case .failed(let message) = engine.phase {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(style.caution)
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(style.text)
                }
            }
        }
        .padding(16)
        .housekeepingCard(cornerRadius: 12)
    }

    private var metricsRow: some View {
        HStack(spacing: 12) {
            metricTile(
                title: "Download",
                symbol: "arrow.down.circle",
                value: formatSpeed(engine.liveDownloadMbps ?? engine.latestResult?.downloadMbps),
                unit: "Mbps",
                active: engine.phase == .measuringDownload
            )
            metricTile(
                title: "Upload",
                symbol: "arrow.up.circle",
                value: formatSpeed(engine.liveUploadMbps ?? engine.latestResult?.uploadMbps),
                unit: "Mbps",
                active: engine.phase == .measuringUpload
            )
            metricTile(
                title: "Ping",
                symbol: "timer",
                value: formatPing(engine.livePingMs ?? engine.latestResult?.pingMs),
                unit: "ms",
                active: engine.phase == .measuringPing
            )
        }
    }

    private func metricTile(title: String, symbol: String, value: String, unit: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? style.accent : .secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if active {
                    ProgressView().controlSize(.mini)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(style.text)
                Text(unit)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .housekeepingCard(cornerRadius: 12, highlighted: active)
    }

    private func verdictCard(_ result: SpeedTestResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.verdictTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(result.verdictDetail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                ThemeButton(
                    title: copiedID == result.id ? "Copied" : "Copy Result",
                    systemImage: copiedID == result.id ? "checkmark" : "doc.on.doc",
                    isPrimary: false
                ) {
                    copyResult(result)
                }
            }

            Divider()

            HStack(spacing: 18) {
                if let iface = result.interfaceName, !iface.isEmpty {
                    detailBadge(label: "Interface", value: iface)
                }
                if let jitter = result.jitterMs {
                    detailBadge(label: "Jitter", value: String(format: "%.1f ms", jitter))
                }
                if let rpm = result.responsivenessRPM {
                    detailBadge(label: "Responsiveness", value: "\(rpm) RPM")
                }
                if let server = result.serverSummary, !server.isEmpty {
                    detailBadge(label: "Server", value: server)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .housekeepingCard(cornerRadius: 12)
    }

    private func detailBadge(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Tests")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Clear History") {
                    engine.clearHistory()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(engine.history.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 14) {
                        Text(Self.dateFormatter.string(from: item.date))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 132, alignment: .leading)
                        Text(String(format: "↓ %.1f Mbps", item.downloadMbps))
                            .font(.system(size: 12.5, weight: .medium))
                            .monospacedDigit()
                            .frame(width: 105, alignment: .leading)
                        Text(String(format: "↑ %.1f Mbps", item.uploadMbps))
                            .font(.system(size: 12.5, weight: .medium))
                            .monospacedDigit()
                            .frame(width: 105, alignment: .leading)
                        Text(String(format: "%.0f ms", item.pingMs))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 58, alignment: .leading)
                        Text(item.provider.title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            copyResult(item)
                        } label: {
                            Image(systemName: copiedID == item.id ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy test result")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)

                    if index < engine.history.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .housekeepingCard(cornerRadius: 12)
        }
    }

    private func copyResult(_ result: SpeedTestResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.copyableSummary, forType: .string)
        copiedID = result.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if copiedID == result.id { copiedID = nil }
        }
    }

    private func formatSpeed(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func formatPing(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f", value)
    }
}
