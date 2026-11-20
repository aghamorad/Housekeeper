// Housekeeping — Native macOS Speed Test Engine
//
// Measures download speed, upload speed, latency, jitter, and responsiveness
// using either Apple's built-in `/usr/bin/networkQuality` tool or a direct
// Cloudflare Edge streaming test. Changes no network settings and idles at 0% CPU.

import Foundation
import SwiftUI

enum SpeedTestProvider: String, CaseIterable, Identifiable, Codable {
    case cloudflare = "cloudflare"
    case apple = "apple"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloudflare: return "Cloudflare Edge"
        case .apple: return "Apple Network Quality"
        }
    }

    var subtitle: String {
        switch self {
        case .cloudflare: return "Live Mbps ticks, ping, and jitter over HTTPS"
        case .apple: return "macOS built-in test with loaded responsiveness (RPM)"
        }
    }
}

enum SpeedTestPhase: Equatable {
    case idle
    case measuringPing
    case measuringDownload
    case measuringUpload
    case runningAppleQuality
    case finished
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .measuringPing, .measuringDownload, .measuringUpload, .runningAppleQuality:
            return true
        default:
            return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Ready to test"
        case .measuringPing: return "Measuring ping and jitter…"
        case .measuringDownload: return "Testing download speed…"
        case .measuringUpload: return "Testing upload speed…"
        case .runningAppleQuality: return "Running Apple Network Quality…"
        case .finished: return "Test complete"
        case .failed(let message): return message
        }
    }
}

struct SpeedTestResult: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let provider: SpeedTestProvider
    let downloadMbps: Double
    let uploadMbps: Double
    let pingMs: Double
    let jitterMs: Double?
    let responsivenessRPM: Int?
    let interfaceName: String?
    let serverSummary: String?

    var verdictTitle: String {
        if downloadMbps >= 100 { return "Very fast connection" }
        if downloadMbps >= 25 { return "Good everyday connection" }
        if downloadMbps >= 10 { return "Moderate connection" }
        return "Slow connection"
    }

    var verdictDetail: String {
        if downloadMbps >= 100 {
            return "Ready for 4K streaming, video calls, and large downloads."
        }
        if downloadMbps >= 25 {
            return "Smooth for HD video, calls, and everyday browsing."
        }
        if downloadMbps >= 10 {
            return "Fine for browsing and standard video; large downloads will take longer."
        }
        return "Video calls or large downloads may stutter. Checking your VPN route or DNS may help."
    }

    var copyableSummary: String {
        var parts = [
            "Download: \(String(format: "%.1f", downloadMbps)) Mbps",
            "Upload: \(String(format: "%.1f", uploadMbps)) Mbps",
            "Ping: \(String(format: "%.0f", pingMs)) ms"
        ]
        if let jitterMs {
            parts.append("Jitter: \(String(format: "%.1f", jitterMs)) ms")
        }
        if let responsivenessRPM {
            parts.append("Responsiveness: \(responsivenessRPM) RPM")
        }
        if let interfaceName, !interfaceName.isEmpty {
            parts.append("Interface: \(interfaceName)")
        }
        parts.append("Engine: \(provider.title)")
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class SpeedTestEngine: ObservableObject {
    static let shared = SpeedTestEngine()

    @Published var provider: SpeedTestProvider = .cloudflare
    @Published private(set) var phase: SpeedTestPhase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var liveDownloadMbps: Double?
    @Published private(set) var liveUploadMbps: Double?
    @Published private(set) var livePingMs: Double?
    @Published private(set) var liveJitterMs: Double?
    @Published private(set) var liveResponsivenessRPM: Int?
    @Published private(set) var liveInterface: String?
    @Published private(set) var liveServer: String?
    @Published private(set) var latestResult: SpeedTestResult?
    @Published private(set) var history: [SpeedTestResult] = []

    private var activeTask: Task<Void, Never>?
    private var activeProcess: Process?
    private let historyKey = "housekeeping.speedTestHistory.v1"

    private init() {
        loadHistory()
        latestResult = history.first
    }

    var isRunning: Bool { phase.isRunning }

    func start() {
        cancel()

        liveDownloadMbps = nil
        liveUploadMbps = nil
        livePingMs = nil
        liveJitterMs = nil
        liveResponsivenessRPM = nil
        liveInterface = nil
        liveServer = nil
        progress = 0.04

        let selectedProvider = provider
        activeTask = Task { [weak self] in
            guard let self else { return }
            switch selectedProvider {
            case .cloudflare:
                await self.runCloudflareTest()
            case .apple:
                await self.runAppleNetworkQualityTest()
            }
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        if let process = activeProcess, process.isRunning {
            process.terminate()
        }
        activeProcess = nil
        if phase.isRunning {
            phase = .idle
            progress = 0
        }
    }

    func clearHistory() {
        history = []
        latestResult = nil
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    // MARK: - Cloudflare Edge Streaming Test

    private func runCloudflareTest() async {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 16
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            // 1. Metadata & active interface (best-effort)
            liveInterface = await Task.detached(priority: .utility) { Self.detectPrimaryInterface() }.value
            if let meta = await fetchCloudflareMeta(session: session) {
                liveServer = meta
            }
            try Task.checkCancellation()

            // 2. Ping & jitter (5 lightweight requests)
            phase = .measuringPing
            progress = 0.10
            var rtts: [Double] = []
            guard let pingURL = URL(string: "https://speed.cloudflare.com/__down?bytes=0") else {
                throw SpeedTestError.invalidEndpoint
            }
            for idx in 0..<5 {
                try Task.checkCancellation()
                var req = URLRequest(url: pingURL)
                req.httpMethod = "GET"
                let t0 = CFAbsoluteTimeGetCurrent()
                let (_, response) = try await session.data(for: req)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                    rtts.append(elapsedMs)
                    livePingMs = Self.median(rtts)
                    liveJitterMs = Self.jitter(rtts)
                }
                progress = 0.10 + (Double(idx + 1) / 5.0) * 0.15
            }
            guard !rtts.isEmpty else {
                throw SpeedTestError.unreachable("Could not reach the speed test server. Check your internet or VPN.")
            }
            let finalPing = Self.median(rtts)
            let finalJitter = Self.jitter(rtts)
            livePingMs = finalPing
            liveJitterMs = finalJitter

            // 3. Download (25 MB streaming, capped at 10 seconds)
            phase = .measuringDownload
            progress = 0.28
            guard let downURL = URL(string: "https://speed.cloudflare.com/__down?bytes=26214400") else {
                throw SpeedTestError.invalidEndpoint
            }
            let (bytesStream, downResponse) = try await session.bytes(from: downURL)
            if let http = downResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw SpeedTestError.unreachable("Download server returned HTTP \(http.statusCode).")
            }

            let downStart = CFAbsoluteTimeGetCurrent()
            var lastUIUpdate = downStart
            var totalBytes: Int64 = 0
            let targetBytes: Double = 26_214_400
            let maxDownSeconds: Double = 10.0

            var chunkCount = 0
            for try await _ in bytesStream {
                totalBytes += 1
                chunkCount += 1
                if chunkCount & 0x3FFF == 0 { // Check every 16 KB
                    try Task.checkCancellation()
                    let now = CFAbsoluteTimeGetCurrent()
                    let elapsed = now - downStart
                    if now - lastUIUpdate >= 0.18, elapsed > 0.05 {
                        lastUIUpdate = now
                        let mbps = (Double(totalBytes) * 8.0) / (elapsed * 1_000_000.0)
                        liveDownloadMbps = mbps
                        let byteFrac = min(1.0, Double(totalBytes) / targetBytes)
                        let timeFrac = min(1.0, elapsed / maxDownSeconds)
                        progress = 0.28 + max(byteFrac, timeFrac) * 0.37
                    }
                    if elapsed >= maxDownSeconds {
                        break
                    }
                }
            }
            let downElapsed = max(0.05, CFAbsoluteTimeGetCurrent() - downStart)
            let finalDownload = (Double(totalBytes) * 8.0) / (downElapsed * 1_000_000.0)
            liveDownloadMbps = finalDownload
            progress = 0.68

            // 4. Upload (6 MB payload, timed)
            try Task.checkCancellation()
            phase = .measuringUpload
            guard let upURL = URL(string: "https://speed.cloudflare.com/__up") else {
                throw SpeedTestError.invalidEndpoint
            }
            let uploadSize = 6 * 1024 * 1024
            let payload = Data(repeating: 0x5A, count: uploadSize)
            var upReq = URLRequest(url: upURL)
            upReq.httpMethod = "POST"
            upReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

            let upStart = CFAbsoluteTimeGetCurrent()
            let (_, upResponse) = try await session.upload(for: upReq, from: payload)
            let upElapsed = max(0.05, CFAbsoluteTimeGetCurrent() - upStart)
            if let http = upResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw SpeedTestError.unreachable("Upload server returned HTTP \(http.statusCode).")
            }
            let finalUpload = (Double(uploadSize) * 8.0) / (upElapsed * 1_000_000.0)
            liveUploadMbps = finalUpload
            progress = 1.0

            let result = SpeedTestResult(
                id: UUID(),
                date: Date(),
                provider: .cloudflare,
                downloadMbps: finalDownload,
                uploadMbps: finalUpload,
                pingMs: finalPing,
                jitterMs: finalJitter,
                responsivenessRPM: nil,
                interfaceName: liveInterface,
                serverSummary: liveServer ?? "Cloudflare Edge"
            )
            record(result)
            phase = .finished
        } catch is CancellationError {
            phase = .idle
            progress = 0
        } catch {
            phase = .failed(Self.friendlyError(error))
            progress = 0
        }
    }

    // MARK: - Apple Built-in networkQuality Test

    private func runAppleNetworkQualityTest() async {
        phase = .runningAppleQuality
        progress = 0.25
        liveInterface = await Task.detached(priority: .utility) { Self.detectPrimaryInterface() }.value

        let toolPath = "/usr/bin/networkQuality"
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            phase = .failed("Apple networkQuality is not available on this macOS version. Switch to Cloudflare Edge.")
            progress = 0
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = ["-c", "-M", "15"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        activeProcess = process

        do {
            try process.run()
        } catch {
            activeProcess = nil
            phase = .failed("Could not start Apple Network Quality: \(error.localizedDescription)")
            progress = 0
            return
        }

        let outputData: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                var timedOut = false
                timer.schedule(deadline: .now() + 20)
                timer.setEventHandler {
                    timedOut = true
                    if process.isRunning { process.terminate() }
                }
                timer.resume()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: timedOut ? nil : data)
            }
        }

        let exitStatus = process.terminationStatus
        activeProcess = nil

        if Task.isCancelled {
            phase = .idle
            progress = 0
            return
        }

        guard let outputData, exitStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
            phase = .failed("Apple Network Quality timed out or could not reach its server. Use Cloudflare Edge instead.")
            progress = 0
            return
        }

        let dlBits = (json["dl_throughput"] as? Double) ?? 0
        let ulBits = (json["ul_throughput"] as? Double) ?? 0
        let baseRTT = (json["base_rtt"] as? Double) ?? 0
        let rpmValue: Int? = {
            if let r = json["responsiveness"] as? Double, r > 0 { return Int(r.rounded()) }
            if let dlR = json["dl_responsiveness"] as? Double, dlR > 0 { return Int(dlR.rounded()) }
            return nil
        }()
        let iface = (json["interface_name"] as? String) ?? liveInterface

        let dlMbps = dlBits / 1_000_000.0
        let ulMbps = ulBits / 1_000_000.0

        liveDownloadMbps = dlMbps
        liveUploadMbps = ulMbps
        livePingMs = baseRTT
        liveResponsivenessRPM = rpmValue
        liveInterface = iface
        liveServer = "Apple CDN"
        progress = 1.0

        let result = SpeedTestResult(
            id: UUID(),
            date: Date(),
            provider: .apple,
            downloadMbps: dlMbps,
            uploadMbps: ulMbps,
            pingMs: baseRTT,
            jitterMs: nil,
            responsivenessRPM: rpmValue,
            interfaceName: iface,
            serverSummary: "Apple CDN"
        )
        record(result)
        phase = .finished
    }

    // MARK: - Helpers

    private func fetchCloudflareMeta(session: URLSession) async -> String? {
        guard let url = URL(string: "https://speed.cloudflare.com/meta") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let city = json["city"] as? String
        let country = json["country"] as? String
        let colo = json["colo"] as? String
        let parts = [city, country].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            if let colo, !colo.isEmpty { return "\(parts.joined(separator: ", ")) (\(colo))" }
            return parts.joined(separator: ", ")
        }
        return colo
    }

    nonisolated private static func detectPrimaryInterface() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("interface:") {
                    let iface = trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
                    if iface.hasPrefix("utun") { return "\(iface) (VPN)" }
                    if iface == "en0" { return "en0 (Wi-Fi)" }
                    return iface
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func record(_ result: SpeedTestResult) {
        latestResult = result
        history.insert(result, at: 0)
        if history.count > 12 {
            history = Array(history.prefix(12))
        }
        saveHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([SpeedTestResult].self, from: data) else {
            return
        }
        history = decoded
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }

    private static func jitter(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        var totalDiff = 0.0
        for i in 1..<values.count {
            totalDiff += abs(values[i] - values[i - 1])
        }
        return totalDiff / Double(values.count - 1)
    }

    private static func friendlyError(_ error: Error) -> String {
        if let err = error as? SpeedTestError {
            return err.localizedDescription
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection detected."
            case NSURLErrorTimedOut:
                return "The speed test timed out. Your connection or VPN may be blocking the test server."
            default:
                return "Could not complete the test (\(ns.localizedDescription))."
            }
        }
        return error.localizedDescription
    }
}

private enum SpeedTestError: LocalizedError {
    case invalidEndpoint
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid speed test endpoint."
        case .unreachable(let msg): return msg
        }
    }
}
