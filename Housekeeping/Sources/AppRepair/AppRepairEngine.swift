import Foundation
import AppKit
import Darwin

@MainActor
public final class AppRepairEngine: ObservableObject {
    public static let shared = AppRepairEngine()

    @Published public private(set) var candidates: [AppRepairCandidate] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var isRepairing = false
    @Published public private(set) var activeRepairApp: String?
    @Published public private(set) var latestOutcome: AppRepairOutcome?
    @Published public private(set) var lastScannedDate: Date?

    private init() {}

    // MARK: - Single App Diagnosis

    /// Reads one app's Gatekeeper state. Read-only: nothing is changed here.
    ///
    /// Only the quarantine flag is a real blocker. `com.apple.provenance` is
    /// attached to almost every downloaded app and is not a problem — treating it
    /// as one is what put dozens of healthy apps on this screen.
    public func diagnoseApp(at url: URL) -> AppRepairCandidate {
        let path = url.path
        let name = url.deletingPathExtension().lastPathComponent
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary
        let bundleID = bundle?.bundleIdentifier ?? "unknown.bundle"
        let version = (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)
            ?? "1.0"

        let hasQuarantine = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
        let hasProvenance = getxattr(path, "com.apple.provenance", nil, 0, 0, 0) >= 0
        let signatureValid = Self.signatureIsValid(url)

        let statusText: String
        if hasQuarantine {
            statusText = "Downloaded with a quarantine flag — macOS will ask before opening it."
        } else if !signatureValid {
            statusText = "No download flag, but the app's own developer signature does not verify. Reinstalling it from its developer is the only fix."
        } else {
            statusText = "Ready. Nothing is blocking this app."
        }

        return AppRepairCandidate(
            url: url,
            name: name,
            bundleID: bundleID,
            version: version,
            hasQuarantine: hasQuarantine,
            hasProvenance: hasProvenance,
            signatureValid: signatureValid,
            statusText: statusText
        )
    }

    /// True when macOS accepts the app's existing signature. This never signs
    /// anything; it only asks `codesign` to check what the developer shipped.
    static func signatureIsValid(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Batch Scan

    /// Lists only apps that actually carry a quarantine flag. Provenance is not
    /// included: it is normal metadata on downloaded apps, not a blocker, and
    /// listing it made a healthy Mac look broken.
    public func scanInstalledApps() async {
        isScanning = true
        defer {
            isScanning = false
            lastScannedDate = Date()
        }

        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        var found: [AppRepairCandidate] = []

        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for dir in directories {
                guard let enumerator = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for url in enumerator where url.pathExtension == "app" {
                    let path = url.path
                    let hasQuarantine = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
                    guard hasQuarantine else { continue }

                    let name = url.deletingPathExtension().lastPathComponent
                    let bundle = Bundle(url: url)
                    let info = bundle?.infoDictionary
                    let bundleID = bundle?.bundleIdentifier ?? "unknown"
                    let version = (info?["CFBundleShortVersionString"] as? String)
                        ?? (info?["CFBundleVersion"] as? String)
                        ?? "1.0"

                    found.append(AppRepairCandidate(
                        url: url,
                        name: name,
                        bundleID: bundleID,
                        version: version,
                        hasQuarantine: true,
                        hasProvenance: getxattr(path, "com.apple.provenance", nil, 0, 0, 0) >= 0,
                        signatureValid: true,
                        statusText: "Downloaded with a quarantine flag — macOS will ask before opening it."
                    ))
                }
            }
        }.value

        self.candidates = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Repair Operation

    public func repair(url: URL) async -> AppRepairOutcome {
        let candidate = diagnoseApp(at: url)
        return await repairApp(candidate: candidate)
    }

    /// Clears the download flag — and nothing else.
    ///
    /// It does not re-sign the app, does not clear other extended attributes and
    /// does not change permissions. Replacing a developer's signature with an
    /// ad-hoc one is what broke Chrome: Chrome's own integrity check compares the
    /// signature it shipped with, and a re-signed bundle fails it. An app whose
    /// signature is already invalid is not fixed by this button; it is reinstalled.
    public func repairApp(candidate: AppRepairCandidate) async -> AppRepairOutcome {
        isRepairing = true
        activeRepairApp = candidate.name
        defer {
            isRepairing = false
            activeRepairApp = nil
        }

        let appPath = candidate.url.path
        var steps: [String] = []

        let xattrRes = await runCommand("/usr/bin/xattr", args: ["-r", "-d", "com.apple.quarantine", appPath])
        steps.append(xattrRes.succeeded
            ? "Cleared the download (quarantine) flag from the app bundle."
            : "The download flag was already clear.")

        let stillQuarantined = getxattr(appPath, "com.apple.quarantine", nil, 0, 0, 0) >= 0
        let signatureValid = Self.signatureIsValid(candidate.url)
        steps.append(signatureValid
            ? "The app's own developer signature still verifies. Signatures were not changed."
            : "The app's own signature does not verify — it shipped that way. Housekeeper did not replace it.")

        let success = !stillQuarantined && signatureValid
        let message: String
        if !stillQuarantined && signatureValid {
            message = "\(candidate.name) has no download flag and its signature is intact. It will open normally."
        } else if !stillQuarantined {
            message = "The download flag is cleared, but \(candidate.name)'s developer signature is invalid. Reinstall it from its developer; no button can restore a signature that was never there."
        } else {
            message = "The download flag could not be cleared. macOS may need administrator permission for an app in a system folder."
        }

        let outcome = AppRepairOutcome(
            appName: candidate.name,
            url: candidate.url,
            succeeded: success,
            stepsTaken: steps,
            message: message
        )

        self.latestOutcome = outcome

        if success, let idx = candidates.firstIndex(where: { $0.url == candidate.url }) {
            candidates.remove(at: idx)
        }

        return outcome
    }

    // MARK: - Subprocess Helper

    private func runCommand(_ executable: String, args: [String]) async -> (succeeded: Bool, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                return (process.terminationStatus == 0, text)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }
}
