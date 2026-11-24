import Foundation
import AppKit

/// Clears the quarantine flag on one app the user dropped in.
///
/// This is the whole job. It never reads or writes a code signature, never
/// changes Gatekeeper, and never touches anything else in the bundle. The flag
/// is the only thing macOS uses to decide whether to show the "downloaded from
/// the internet" prompt, so removing it is exactly what "let this open" means
/// for an app the user already trusts.
@MainActor
final class AppRepairEngine: ObservableObject {
    static let shared = AppRepairEngine()

    @Published private(set) var isWorking = false
    @Published private(set) var latestOutcome: AppRepairOutcome?

    private init() {}

    func clearDownloadFlag(url: URL) async {
        guard url.pathExtension.lowercased() == "app" else {
            latestOutcome = AppRepairOutcome(
                appName: url.lastPathComponent,
                url: url,
                succeeded: false,
                message: "That is not an app bundle. Drop something ending in .app."
            )
            return
        }

        isWorking = true
        defer { isWorking = false }

        let (status, output) = await Task.detached { Self.runXattr(on: url) }.value
        let stillFlagged = Self.hasQuarantine(url)
        let name = url.deletingPathExtension().lastPathComponent

        let succeeded = status == 0 && !stillFlagged
        let message: String
        if succeeded {
            message = "\(name) has no download flag now. macOS will open it without the downloaded-app prompt."
        } else if status != 0 {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            message = "macOS would not clear the flag on \(name). \(detail.isEmpty ? "The app may live in a folder this account cannot write to." : detail)"
        } else {
            message = "The flag is still on \(name). Nothing else was changed."
        }

        latestOutcome = AppRepairOutcome(
            appName: name,
            url: url,
            succeeded: succeeded,
            message: message
        )
    }

    nonisolated private static func runXattr(on url: URL) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-r", "-d", "com.apple.quarantine", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    nonisolated private static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}
