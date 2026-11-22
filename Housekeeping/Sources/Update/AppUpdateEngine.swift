import Foundation
import AppKit

// Housekeeping — Update engine
//
// The half of the feature that asks questions and, when told to, acts. Kept apart
// from the inventory because it is the part that can be wrong in the direction
// that matters: a check that mistakes "I could not find out" for "you are up to
// date" leaves someone on an old copy, and an install that half-finishes leaves
// them with no copy at all. Both are guarded here rather than in the view.
//
// Nothing in this file runs an install on its own. Every action is entered from
// the reader pressing a button, and every destructive step is the last thing in
// its function so that a cancellation arriving late stops work that has not yet
// touched the machine.

/// A newer version one of the remote sources reported, or the reason it could not
/// be read. Kept as its own small type so the three sources — GitHub, a Sparkle
/// feed, Homebrew — agree on what a "found" answer is before any of them is
/// compared to the installed version.
private enum RemoteVersion {
    case found(version: String, download: UpdateDownload?)
    case failed(reason: String)
}

/// Why a question went unanswered, in the reader's words. A message rather than a
/// case per failure, because every one of these ends up on screen verbatim and the
/// caller does the same thing with all of them. It is a type and not a bare
/// `String` because `Result`'s failure has to be an `Error`; the string literal is
/// still what gets written at the call site, which is what makes it worth doing
/// this way rather than wrapping each one by hand.
struct UpdateEngineFailure: Error, ExpressibleByStringLiteral {
    let message: String
    init(stringLiteral value: String) { message = value }
}

final class AppUpdateEngine {
    /// The bundle identifiers Housekeeping keeps a release source for. This is a
    /// record, not an inference: an identifier absent from the table is treated as
    /// unidentified and is never attributed to the nearest-looking repository.
    /// The obvious tempting shortcut — searching GitHub for the app's name — is
    /// exactly the kind of guess that ends with the wrong application downloaded.
    static let knownGitHubRepos: [String: String] = [
        "org.godotengine.godot": "godotengine/godot",
        "org.blenderfoundation.blender": "blender/blender",
        "fr.handbrake.HandBrake": "HandBrake/HandBrake",
        "com.colliderli.iina": "iina/iina",
        "net.kovidgoyal.calibre": "kovidgoyal/calibre",
        "org.m0k.transmission": "transmission/transmission",
        "org.upscayl.Upscayl": "upscayl/upscayl",
        "com.sidequestvr.SideQuest": "SideQuestVR/SideQuest",
        "com.Lauriethefish.QuestPatcher": "Lauriethefish/QuestPatcher",
        "app.cyan.markedit": "MarkEdit-app/MarkEdit",
        "org.zotero.zotero": "zotero/zotero",
        "ai.elementlabs.lmstudio": "lmstudio-ai/lmstudio",
        "io.playcover.PlayCover": "PlayCover/PlayCover",
        "org.openemu.OpenEmu": "OpenEmu/OpenEmu",
    ]

    private let runner: ProcessRunner
    private let fileManager: FileManager
    let brewPath: String?
    let masPath: String?

    init(runner: ProcessRunner, fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
        self.brewPath = ProcessRunner.brewPath(fileManager: fileManager)
        self.masPath = AppUpdateEngine.findMas(fileManager: fileManager)
    }

    static func findMas(fileManager: FileManager = .default) -> String? {
        for candidate in ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"]
        where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in searchPath.split(separator: ":") {
            let candidate = "\(directory)/mas"
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - What Homebrew already knows

    /// The result of asking Homebrew once, shared by every row rather than asked
    /// per row — `brew outdated` is a single expensive call and running it per
    /// package would be hundreds.
    struct Prepared {
        let homebrewAvailable: Bool
        /// Keyed by `cask:<token>` and `formula:<name>`, matching `BrewPackage.id`.
        let outdated: [String: OutdatedEntry]
        let outdatedNote: String?
        let masAvailable: Bool
        /// The store's list, by lowered name, and which of its ids have an update.
        let masIDByName: [String: String]
        let masOutdatedIDs: [String: String]
        let masNote: String?
    }

    struct OutdatedEntry {
        let installedVersion: String
        let currentVersion: String
        let isPinned: Bool
    }

    func prepare() async -> Prepared {
        var outdated: [String: OutdatedEntry] = [:]
        var outdatedNote: String?

        if let brew = brewPath {
            switch await readOutdated(brew: brew) {
            case .success(let entries):
                outdated = entries
            case .failure(let failure):
                outdatedNote = failure.message
            }
        } else {
            outdatedNote = "Homebrew is not installed here."
        }

        var masIDByName: [String: String] = [:]
        var masOutdatedIDs: [String: String] = [:]
        var masNote: String?
        if let mas = masPath {
            let listed = await readMasList(mas: mas)
            masIDByName = listed.byName
            if let note = listed.note { masNote = note }
            let out = await readMasOutdated(mas: mas)
            masOutdatedIDs = out
        }

        return Prepared(
            homebrewAvailable: brewPath != nil,
            outdated: outdated,
            outdatedNote: outdatedNote,
            masAvailable: masPath != nil,
            masIDByName: masIDByName,
            masOutdatedIDs: masOutdatedIDs,
            masNote: masNote
        )
    }

    private func readOutdated(brew: String) async -> Swift.Result<[String: OutdatedEntry], UpdateEngineFailure> {
        let result: ProcessRunner.Result
        do {
            result = try await runner.run(
                executable: brew,
                arguments: ["outdated", "--json=v2", "--greedy"],
                timeout: 120
            )
        } catch {
            return .failure("Homebrew could not be asked about outdated packages.")
        }
        guard result.succeeded,
              let root = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            return .failure("Homebrew's answer about outdated packages could not be read.")
        }

        var map: [String: OutdatedEntry] = [:]
        for formula in (root["formulae"] as? [[String: Any]]) ?? [] {
            guard let name = formula["name"] as? String else { continue }
            let installed = (formula["installed_versions"] as? [String])?.last
                ?? (formula["installed_version"] as? String) ?? ""
            let current = (formula["current_version"] as? String) ?? installed
            let pinned = (formula["pinned"] as? Bool) ?? false
            map["formula:" + name] = OutdatedEntry(installedVersion: installed, currentVersion: current, isPinned: pinned)
        }
        for cask in (root["casks"] as? [[String: Any]]) ?? [] {
            guard let name = cask["name"] as? String else { continue }
            let installed = (cask["installed_versions"] as? [String])?.last
                ?? (cask["installed_version"] as? String) ?? ""
            let current = (cask["current_version"] as? String) ?? installed
            let pinned = (cask["pinned"] as? Bool) ?? false
            map["cask:" + name] = OutdatedEntry(installedVersion: installed, currentVersion: current, isPinned: pinned)
        }
        return .success(map)
    }

    private func readMasList(mas: String) async -> (byName: [String: String], note: String?) {
        guard let result = try? await runner.run(executable: mas, arguments: ["list"], timeout: 60),
              result.succeeded else {
            return ([:], "The App Store tool (mas) did not return its list of installed applications.")
        }
        var byName: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            // Each line is "<adamID> <name> (<version>)". The name may contain
            // spaces; the id is the first token and the version is in the last
            // parenthesis, so the name is everything between.
            let text = String(line)
            guard let firstSpace = text.firstIndex(of: " ") else { continue }
            let id = String(text[text.startIndex..<firstSpace])
            guard id.allSatisfy(\.isNumber) else { continue }
            var name = String(text[text.index(after: firstSpace)...])
            if let open = name.lastIndex(of: "("), name.hasSuffix(")") {
                name = String(name[name.startIndex..<open])
            }
            byName[name.trimmingCharacters(in: .whitespaces).lowercased()] = id
        }
        return (byName, nil)
    }

    private func readMasOutdated(mas: String) async -> [String: String] {
        guard let result = try? await runner.run(executable: mas, arguments: ["outdated"], timeout: 60),
              result.succeeded else { return [:] }
        var map: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            let text = String(line)
            guard let firstSpace = text.firstIndex(of: " ") else { continue }
            let id = String(text[text.startIndex..<firstSpace])
            guard id.allSatisfy(\.isNumber) else { continue }
            var version = ""
            if let open = text.lastIndex(of: "("), text.hasSuffix(")") {
                version = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            }
            map[id] = version
        }
        return map
    }

    // MARK: - Asking one thing

    func check(application: InstalledApplication, prepared: Prepared) async -> UpdateCheck {
        switch application.provenance {
        case .homebrewCask(let token):
            return brewCheck(id: "cask:" + token, prepared: prepared)

        case .appleSystem:
            return .refused(reason: "This is part of macOS and is updated by the system, not by anything here.")

        case .alteredCopy(let reasons):
            let reason = reasons.first ?? "the copy has been modified after signing"
            return .refused(reason: "This copy does not match its origin — \(reason) — so Housekeeping will not replace it.")

        case .macAppStore:
            return appStoreCheck(application, prepared: prepared)

        case .githubRelease(let repo):
            return await githubCheck(repo: repo, installed: application.version)

        case .sparkleFeed(let url):
            guard let url else {
                return .unknown(reason: "The bundle declares an update feed but names no address for it.")
            }
            return await sparkleCheck(feed: url, installed: application.version)

        case .signedByDeveloper, .unsignedOrSelfSigned:
            return .unknown(reason: "Housekeeping could not establish where this copy came from, so it will not replace it.")

        case .homebrewFormula:
            return .unknown(reason: "This is a command-line package, not an application.")
        }
    }

    func check(package: BrewPackage, prepared: Prepared) async -> UpdateCheck {
        guard prepared.homebrewAvailable else {
            return .unknown(reason: "Homebrew is not installed here.")
        }
        return brewCheck(id: package.id, prepared: prepared)
    }

    private func brewCheck(id: String, prepared: Prepared) -> UpdateCheck {
        if let entry = prepared.outdated[id] {
            if entry.isPinned {
                return .refused(reason: "\(id) is pinned in Homebrew, so it is held at this version on purpose. Housekeeping reports it and will not undo the pin.")
            }
            let version = entry.currentVersion.isEmpty ? entry.installedVersion : entry.currentVersion
            return .available(version: version, download: nil)
        }
        if let note = prepared.outdatedNote {
            return .unknown(reason: note)
        }
        return .current
    }

    private func appStoreCheck(_ application: InstalledApplication, prepared: Prepared) -> UpdateCheck {
        guard prepared.masAvailable else {
            return .unknown(reason: "The store's own tool (mas) is not installed, so Housekeeping cannot ask the store whether this has an update.")
        }
        guard let id = prepared.masIDByName[application.name.lowercased()] else {
            return .unknown(reason: "The store's list of installed applications does not name this one, so Housekeeping cannot ask about it.")
        }
        if let version = prepared.masOutdatedIDs[id] {
            return .available(version: version, download: nil)
        }
        if let note = prepared.masNote {
            return .unknown(reason: note)
        }
        return .current
    }

    private func githubCheck(repo: String, installed: String) async -> UpdateCheck {
        switch await remoteGitHubRelease(repo: repo) {
        case .found(let version, let download):
            return AppState.isNewer(version, than: installed)
                ? .available(version: version, download: download)
                : .current
        case .failed(let reason):
            return .unknown(reason: reason)
        }
    }

    private func sparkleCheck(feed: URL, installed: String) async -> UpdateCheck {
        switch await remoteAppcast(feed: feed) {
        case .found(let version, let download):
            return AppState.isNewer(version, than: installed)
                ? .available(version: version, download: download)
                : .current
        case .failed(let reason):
            return .unknown(reason: reason)
        }
    }

    // MARK: - The remote sources

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name"; case assets }
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey { case name; case browserDownloadURL = "browser_download_url" }
        }
    }

    private func remoteGitHubRelease(repo: String) async -> RemoteVersion {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failed(reason: "The release source for this application is not a valid address.")
        }
        var request = URLRequest(url: url)
        // GitHub answers 403 to a request carrying no User-Agent at all, which is
        // the shape of a false "no releases" if it is forgotten.
        request.setValue("Housekeeping", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(reason: "GitHub's answer was not readable.")
            }
            guard http.statusCode == 200 else {
                if http.statusCode == 404 {
                    return .failed(reason: "No releases were found for \(repo).")
                }
                return .failed(reason: "GitHub answered \(http.statusCode) when asked about \(repo).")
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let version = AppState.normalize(release.tagName)
            // An installer, not the source archive GitHub also offers. A `.dmg`
            // is preferred over a `.zip` when both are present, since it is the
            // form the vendor expects to be mounted.
            let installed = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
                ?? release.assets.first { $0.name.lowercased().hasSuffix(".zip") }
            let installerDownload = installed.flatMap { download(from: $0.browserDownloadURL, version: version) }
            return .found(version: version, download: installerDownload)
        } catch {
            return .failed(reason: "GitHub could not be reached: \(error.localizedDescription)")
        }
    }

    private func remoteAppcast(feed: URL) async -> RemoteVersion {
        var request = URLRequest(url: feed)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed(reason: "The update feed did not answer.")
            }
            let parser = AppcastParser()
            parser.parse(data)
            guard let item = parser.newest() else {
                return .failed(reason: "The update feed carried no releases Housekeeping could read.")
            }
            let version = item.shortVersion ?? item.version ?? ""
            guard !version.isEmpty else {
                return .failed(reason: "The update feed's newest release has no version Housekeeping could read.")
            }
            let download = item.enclosureURL.flatMap { self.download(from: $0, version: version) }
            return .found(version: version, download: download)
        } catch {
            return .failed(reason: "The update feed could not be reached: \(error.localizedDescription)")
        }
    }

    /// Turns a URL into a download Housekeeping is willing to make. Only the two
    /// container types the swap step knows how to open are accepted; anything else
    /// yields nil, which the row shows as a version without a way to install it —
    /// never as an invitation to download a file Housekeeping cannot verify.
    private func download(from urlString: String, version: String) -> UpdateDownload? {
        guard let url = URL(string: urlString) else { return nil }
        let ext = url.pathExtension.lowercased()
        let kind: UpdateDownload.DownloadKind
        switch ext {
        case "dmg": kind = .diskImage
        case "zip": kind = .zip
        default: return nil
        }
        return UpdateDownload(url: url, version: version, kind: kind)
    }

    // MARK: - Doing one thing

    func perform(_ action: UpdateAction, for application: InstalledApplication? = nil) async throws -> UpdateOutcome {
        switch action {
        case .brewPackage(let name, let isCask):
            return try await upgradeBrew(name: name, isCask: isCask)
        case .appStoreUpgrade(let adamID):
            return try await upgradeViaStore(adamID: adamID)
        case .openAppStoreUpdates:
            return openAppStoreUpdates()
        case .openWebsite(let url):
            NSWorkspace.shared.open(url)
            return UpdateOutcome(
                id: application?.id ?? url.absoluteString,
                name: application?.name ?? url.host ?? "Website",
                message: "Opened \(url.absoluteString) in browser.",
                succeeded: true
            )
        case .replaceBundle(let download):
            guard let application else {
                throw UpdateFailure.missingApplication
            }
            return try await replaceBundle(for: application, download: download)
        }
    }

    static var hasFullDiskAccess: Bool {
        let testPath = ("~/Library/Safari" as NSString).expandingTildeInPath
        return FileManager.default.isReadableFile(atPath: testPath)
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func upgradeBrew(name: String, isCask: Bool) async throws -> UpdateOutcome {
        guard let brew = brewPath else {
            throw UpdateFailure.homebrewMissing
        }
        let arguments = isCask ? ["upgrade", "--cask", name] : ["upgrade", name]
        // Ten minutes: a cask with a large dependency, or a slow link, is normal
        // and should not be cut off; a hung one still is.
        let result = try await runner.run(executable: brew, arguments: arguments, timeout: 600)
        try Task.checkCancellation()
        if result.succeeded {
            return UpdateOutcome(id: name, name: name, message: "Updated with Homebrew.", succeeded: true)
        }

        let combined = (result.stderr + "\n" + result.stdout).lowercased()

        // Homebrew refuses to run as root (`with administrator privileges`), so
        // when a cask installer (.pkg) or permission step needs sudo, run `brew`
        // as the normal user with SUDO_ASKPASS pointing at a native macOS dialog.
        if combined.contains("sudo") || combined.contains("password") || combined.contains("a password is required") {
            let askpassResult = try await runBrewWithAskpass(brew: brew, arguments: arguments, packageName: name)
            try Task.checkCancellation()
            if askpassResult.succeeded {
                return UpdateOutcome(id: name, name: name, message: "Updated with Homebrew (Administrator privileges granted).", succeeded: true)
            }
            let askCombined = (askpassResult.stderr + "\n" + askpassResult.stdout).lowercased()
            if askCombined.contains("user canceled") || askCombined.contains("cancelled") || askCombined.contains("no password") {
                return UpdateOutcome(id: name, name: name, message: "Administrator password prompt was cancelled.", succeeded: false)
            }
            let detail = meaningfulErrorSummary(stderr: askpassResult.stderr, stdout: askpassResult.stdout)
                ?? "Homebrew could not complete the privileged update."
            return UpdateOutcome(id: name, name: name, message: detail, succeeded: false)
        }

        // Formula upgraded in Cellar but `brew link` hit a stale symlink or file
        // conflict inside the Homebrew prefix (e.g. ca-certificates / python tools).
        if !isCask && (combined.contains("brew link") || combined.contains("could not symlink")) {
            if await repairBrewLink(brew: brew, formula: name) {
                return UpdateOutcome(id: name, name: name, message: "Updated and relinked with Homebrew.", succeeded: true)
            }
        }

        let detail = meaningfulErrorSummary(stderr: result.stderr, stdout: result.stdout) ?? "Homebrew reported an error."
        return UpdateOutcome(id: name, name: name, message: detail, succeeded: false)
    }

    private func runBrewWithAskpass(
        brew: String,
        arguments: [String],
        packageName: String
    ) async throws -> ProcessRunner.Result {
        let dir = fileManager.temporaryDirectory.appendingPathComponent("hk-askpass-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        defer { discardToTrash(dir) }

        let scriptURL = dir.appendingPathComponent("askpass.sh")
        let safePromptName = packageName.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
        let scriptBody = """
        #!/bin/sh
        /usr/bin/osascript -e 'Tell application "System Events" to display dialog "Housekeeper needs your Mac password to finish updating \(safePromptName)." with title "Housekeeper Update" with icon caution default answer "" with hidden answer' -e 'text returned of result' 2>/dev/null
        """
        try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        var env = ProcessInfo.processInfo.environment
        env["SUDO_ASKPASS"] = scriptURL.path
        env["HOME"] = fileManager.homeDirectoryForCurrentUser.path
        return try await runner.run(executable: brew, arguments: arguments, environment: env, timeout: 600)
    }

    private func repairBrewLink(brew: String, formula: String) async -> Bool {
        _ = try? await runner.run(executable: brew, arguments: ["unlink", formula], timeout: 60)
        if let relink = try? await runner.run(executable: brew, arguments: ["link", formula], timeout: 60),
           relink.succeeded {
            return true
        }
        guard let dryRun = try? await runner.run(
            executable: brew,
            arguments: ["link", "--overwrite", "--dry-run", formula],
            timeout: 60
        ) else {
            return false
        }
        let prefix = (brew as NSString).deletingLastPathComponent.replacingOccurrences(of: "/bin", with: "")
        let lines = (dryRun.stdout + "\n" + dryRun.stderr)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
        // Only auto-overwrite files already inside Homebrew's own prefix.
        guard lines.allSatisfy({ $0.hasPrefix(prefix + "/") }) else { return false }
        if let forced = try? await runner.run(executable: brew, arguments: ["link", "--overwrite", formula], timeout: 60) {
            return forced.succeeded
        }
        return false
    }

    private func meaningfulErrorSummary(stderr: String, stdout: String) -> String? {
        let lines = (stderr + "\n" + stdout)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let errorLines = lines.filter {
            let lower = $0.lowercased()
            return lower.hasPrefix("error:") || lower.contains("target ") || lower.contains("already exists") || lower.contains("sudo:")
        }
        if !errorLines.isEmpty {
            return errorLines.prefix(2).joined(separator: " ")
        }
        return lines.last
    }

    private func upgradeViaStore(adamID: String) async throws -> UpdateOutcome {
        guard let mas = masPath else {
            throw UpdateFailure.masMissing
        }
        let result = try await runner.run(executable: mas, arguments: ["upgrade", adamID], timeout: 1200)
        try Task.checkCancellation()
        if result.succeeded {
            return UpdateOutcome(id: adamID, name: adamID, message: "Updated through the App Store.", succeeded: true)
        }
        let detail = lastMeaningfulLine(result.stderr) ?? lastMeaningfulLine(result.stdout) ?? "The store reported an error."
        return UpdateOutcome(id: adamID, name: adamID, message: detail, succeeded: false)
    }

    private func openAppStoreUpdates() -> UpdateOutcome {
        // The store's Updates page. There is no URL that updates a named app
        // without `mas`; the honest thing is to open the page the reader would
        // reach by hand.
        if let url = URL(string: "macappstore://showUpdatesPage") {
            NSWorkspace.shared.open(url)
        }
        return UpdateOutcome(
            id: "store-updates", name: "App Store",
            message: "Opened the App Store's Updates page.", succeeded: true
        )
    }

    private func lastMeaningfulLine(_ text: String) -> String? {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    // MARK: - Replacing a bundle

    enum UpdateFailure: Error, LocalizedError {
        case missingApplication
        case homebrewMissing
        case masMissing
        case refused(String)
        case running(String)
        case download(String)
        case truncated(String)
        case extraction(String)
        case noApplicationInDownload
        case identityChanged(String)
        case signerChanged(from: String, to: String)
        case signerMissing(String)
        case swapFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingApplication: return "Housekeeping lost track of which application to replace."
            case .homebrewMissing: return "Homebrew is not installed here."
            case .masMissing: return "The store's tool (mas) is not installed here."
            case .refused(let reason): return reason
            case .running(let name): return "\(name) is running. Quit it and try again — Housekeeping will not replace an application while it is open."
            case .download(let reason): return reason
            case .truncated(let name): return "The download of \(name) stopped before it finished. This is common behind a throttled connection; try again."
            case .extraction(let reason): return reason
            case .noApplicationInDownload: return "The download did not contain an application Housekeeping could find."
            case .identityChanged(let id): return "The download is a different application (its identifier is \(id)), so nothing was replaced."
            case .signerChanged(let from, let to): return "The new copy is signed by \(to) but the installed one is signed by \(from). Housekeeping replaced nothing."
            case .signerMissing(let name): return "The installed \(name) is signed but the new copy is not. Housekeeping replaced nothing."
            case .swapFailed(let reason): return reason
            }
        }
    }

    /// Downloads, verifies, and only then swaps. The order is deliberate and is
    /// the opposite of the obvious one: all the slow, failure-prone work — the
    /// fetch, the mount, the copy out, the signature comparison — happens while
    /// the installed copy is still untouched, and the swap is the last step and
    /// the quickest. A design that moved the old copy aside first would spend
    /// minutes with the application missing, and any failure in the middle of
    /// those minutes would leave the reader with nothing.
    private func replaceBundle(for application: InstalledApplication, download: UpdateDownload) async throws -> UpdateOutcome {
        // The two things Housekeeping will not replace, whatever the check said.
        if case .alteredCopy = application.provenance {
            throw UpdateFailure.refused("This copy has been modified after signing, so Housekeeping will not replace it.")
        }
        if case .appleSystem = application.provenance {
            throw UpdateFailure.refused("This is part of macOS and is not Housekeeping's to replace.")
        }

        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == application.bundleIdentifier
        }
        if running {
            throw UpdateFailure.running(application.name)
        }

        let oldTeam = application.team
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let workspaceRoot = downloads.appendingPathComponent("Housekeeping Updates", isDirectory: true)
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        // Sweep any leftover loose files from interrupted earlier runs so mounts never collide.
        for staleName in ["download.dmg", "download.zip", "mounted", "extracted"] {
            let staleURL = workspaceRoot.appendingPathComponent(staleName)
            if fileManager.fileExists(atPath: staleURL.path) {
                discardToTrash(staleURL)
            }
        }

        let runWorkspace = workspaceRoot.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: runWorkspace, withIntermediateDirectories: true)

        var mountedVolume: URL?
        defer {
            if let mountedVolume {
                // Best-effort detach before moving the run workspace to Trash.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = ["detach", mountedVolume.path, "-force"]
                try? process.run()
                process.waitUntilExit()
            }
            discardToTrash(runWorkspace)
        }

        // 1. Fetch into the isolated run workspace.
        let downloaded = try await fetch(download, into: runWorkspace)
        try Task.checkCancellation()

        // 2. Open the container and locate the application bundle.
        let incoming: URL
        switch download.kind {
        case .diskImage:
            let mounted = try await mount(downloaded, into: runWorkspace)
            mountedVolume = mounted
            guard let found = locateApplication(in: mounted, matching: application) else {
                throw UpdateFailure.noApplicationInDownload
            }
            incoming = found
        case .zip:
            let extracted = try await unzip(downloaded, into: runWorkspace)
            guard let found = locateApplication(in: extracted, matching: application) else {
                throw UpdateFailure.noApplicationInDownload
            }
            incoming = found
        case .other:
            throw UpdateFailure.extraction("Housekeeping does not know how to open this kind of download.")
        }
        try Task.checkCancellation()

        // 3. Stage the incoming bundle on local APFS using `ditto` BEFORE touching
        //    the installed app. Never call `FileManager.moveItem` directly from a
        //    read-only mounted `.dmg`: Foundation copies the bundle to `/Applications`
        //    and then throws when it cannot unlink the read-only source, leaving an
        //    "item with the same name already exists" collision behind.
        let destination = application.url
        let stagingDir = runWorkspace.appendingPathComponent("staged", isDirectory: true)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedBundle = stagingDir.appendingPathComponent(destination.lastPathComponent)

        let copyStage = try await runner.run(
            executable: "/usr/bin/ditto",
            arguments: [incoming.path, stagedBundle.path],
            timeout: 180
        )
        guard copyStage.succeeded, fileManager.fileExists(atPath: stagedBundle.path) else {
            throw UpdateFailure.extraction("Housekeeping could not stage the new copy of \(application.name): \(lastMeaningfulLine(copyStage.stderr) ?? "ditto failed").")
        }
        _ = try? await runner.run(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", stagedBundle.path],
            timeout: 30
        )

        // 4. Verify the staged copy before anything installed is moved.
        if let info = AppInventory.readInfoPlist(bundleAt: stagedBundle),
           let identifier = info["CFBundleIdentifier"] as? String,
           identifier != application.bundleIdentifier {
            throw UpdateFailure.identityChanged(identifier)
        }
        let newSignature = await AppProvenance.readSignature(bundleAt: stagedBundle, using: runner)
        if let oldTeam, let newTeam = newSignature.teamIdentifier, newTeam != oldTeam {
            throw UpdateFailure.signerChanged(from: oldTeam, to: newTeam)
        }
        if oldTeam != nil, newSignature.teamIdentifier == nil {
            throw UpdateFailure.signerMissing(application.name)
        }

        // 5. Atomic swap: move old bundle to Trash backup, ensure destination is clear,
        //    and move/copy the verified staged bundle into place.
        try Task.checkCancellation()
        let backupDirectory = try updateBackupDirectory()
        let backup = uniqueBackupURL(in: backupDirectory, appName: application.name)

        do {
            try moveBundle(from: destination, to: backup)
        } catch {
            if let adminError = await moveBundleWithAdminIfNeeded(from: destination, to: backup) {
                throw UpdateFailure.swapFailed("Housekeeping could not move the existing copy aside: \(adminError)")
            }
        }

        // Guard against case-insensitive or pre-existing sibling collision at destination.
        if fileManager.fileExists(atPath: destination.path) {
            let extraBackup = uniqueBackupURL(in: backupDirectory, appName: "\(application.name)-existing")
            do {
                try moveBundle(from: destination, to: extraBackup)
            } catch {
                _ = await moveBundleWithAdminIfNeeded(from: destination, to: extraBackup)
            }
        }

        do {
            try await placeBundle(from: stagedBundle, to: destination)
        } catch {
            // If placing left a partial copy at destination, move it to Trash before restoring.
            if fileManager.fileExists(atPath: destination.path) {
                let failedCopy = uniqueBackupURL(in: backupDirectory, appName: "\(application.name)-partial")
                try? moveBundle(from: destination, to: failedCopy)
            }
            if (try? moveBundle(from: backup, to: destination)) == nil {
                _ = await moveBundleWithAdminIfNeeded(from: backup, to: destination)
            }
            throw UpdateFailure.swapFailed("Housekeeping could not place the new copy: \(error.localizedDescription). The previous copy was put back.")
        }

        return UpdateOutcome(
            id: application.id,
            name: application.name,
            message: "Replaced with \(download.version). The previous copy is kept at \(escaped(backup)).",
            succeeded: true
        )
    }

    private func uniqueBackupURL(in directory: URL, appName: String) -> URL {
        let base = "\(appName)-\(stamp())"
        var candidate = directory.appendingPathComponent("\(base).app")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).app")
            counter += 1
        }
        return candidate
    }

    private func sameVolume(_ a: URL, _ bParent: URL) -> Bool {
        let volA = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let volB = (try? bParent.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        guard let volA, let volB else { return false }
        return volA.isEqual(volB)
    }

    private func moveBundle(from source: URL, to destination: URL) throws {
        if sameVolume(source, destination.deletingLastPathComponent()) {
            try fileManager.moveItem(at: source, to: destination)
        } else {
            let status = Process()
            status.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            status.arguments = [source.path, destination.path]
            try status.run()
            status.waitUntilExit()
            guard status.terminationStatus == 0 else {
                throw UpdateFailure.swapFailed("Could not copy \(source.lastPathComponent) across volumes.")
            }
            try fileManager.removeItem(at: source)
        }
    }

    private func placeBundle(from staged: URL, to destination: URL) async throws {
        if sameVolume(staged, destination.deletingLastPathComponent()) {
            do {
                try fileManager.moveItem(at: staged, to: destination)
                return
            } catch {
                // Fall back to ditto + admin below if direct rename failed.
                if fileManager.fileExists(atPath: destination.path) {
                    discardToTrash(destination)
                }
            }
        }

        let copyRes = try await runner.run(
            executable: "/usr/bin/ditto",
            arguments: [staged.path, destination.path],
            timeout: 180
        )
        if copyRes.succeeded { return }

        if let adminError = await copyBundleWithAdminIfNeeded(from: staged, to: destination) {
            throw UpdateFailure.swapFailed(adminError)
        }
    }

    @MainActor
    private func runAdminShell(_ command: String) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var errDict: NSDictionary?
        if let script = NSAppleScript(source: source) {
            _ = script.executeAndReturnError(&errDict)
            if let errDict {
                return (errDict[NSAppleScript.errorBriefMessage] as? String)
                    ?? (errDict[NSAppleScript.errorMessage] as? String)
                    ?? "Administrator authorization failed."
            }
            return nil
        }
        return "Could not run administrator authorization."
    }

    private func moveBundleWithAdminIfNeeded(from source: URL, to destination: URL) async -> String? {
        let qSrc = shellQuote(source.path)
        let qDst = shellQuote(destination.path)
        return await runAdminShell("/bin/mv \(qSrc) \(qDst)")
    }

    private func copyBundleWithAdminIfNeeded(from source: URL, to destination: URL) async -> String? {
        let qSrc = shellQuote(source.path)
        let qDst = shellQuote(destination.path)
        return await runAdminShell("/usr/bin/ditto \(qSrc) \(qDst) && /usr/bin/xattr -dr com.apple.quarantine \(qDst) 2>/dev/null || true")
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Container handling

    private func fetch(_ download: UpdateDownload, into workspace: URL) async throws -> URL {
        var request = URLRequest(url: download.url)
        request.setValue("Housekeeping", forHTTPHeaderField: "User-Agent")
        // A large download over a slow link takes minutes; a stalled one should
        // not take the rest of the day.
        request.timeoutInterval = 600
        do {
            let (temporary, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateFailure.download("The download server answered with an error.")
            }
            let destination = workspace.appendingPathComponent("download.\(download.kind == .zip ? "zip" : "dmg")")
            try? fileManager.removeItem(at: destination)
            // The file URLSession hands back is in its own temporary folder, so it
            // is copied into this function's workspace, which is cleaned up later.
            try fileManager.copyItem(at: temporary, to: destination)

            // A short file is the signature of a throttled or dropped connection,
            // which is the ordinary failure on the network this app is used over.
            let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? nil ?? 0
            if size == 0 {
                throw UpdateFailure.truncated(download.url.lastPathComponent)
            }
            if http.expectedContentLength > 0, Int64(size) < http.expectedContentLength {
                throw UpdateFailure.truncated(download.url.lastPathComponent)
            }
            return destination
        } catch let failure as UpdateFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UpdateFailure.download("The download could not be made: \(error.localizedDescription)")
        }
    }

    private func mount(_ image: URL, into workspace: URL) async throws -> URL {
        let mountPoint = workspace.appendingPathComponent("mounted")
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let result: ProcessRunner.Result
        do {
            result = try await runner.run(
                executable: "/usr/bin/hdiutil",
                arguments: ["attach", image.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path],
                timeout: 180
            )
        } catch {
            throw UpdateFailure.extraction("The disk image could not be mounted.")
        }
        guard result.succeeded else {
            throw UpdateFailure.extraction("The disk image could not be mounted: \(lastMeaningfulLine(result.stderr) ?? "hdiutil reported an error")")
        }
        return mountPoint
    }

    private func unzip(_ archive: URL, into workspace: URL) async throws -> URL {
        let destination = workspace.appendingPathComponent("extracted")
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        // `ditto` rather than `unzip`: it preserves the extended attributes and
        // symlinks an application bundle depends on, which `unzip` silently drops.
        let result: ProcessRunner.Result
        do {
            result = try await runner.run(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", archive.path, destination.path],
                timeout: 180
            )
        } catch {
            throw UpdateFailure.extraction("The archive could not be opened.")
        }
        guard result.succeeded else {
            throw UpdateFailure.extraction("The archive could not be opened: \(lastMeaningfulLine(result.stderr) ?? "ditto reported an error")")
        }
        return destination
    }

    private func locateApplication(in root: URL, matching application: InstalledApplication) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "app" {
                candidates.append(url)
                // Do not descend into an application; nested helper bundles are
                // not what should be found.
                enumerator.skipDescendants()
            }
        }
        if let exact = candidates.first(where: {
            AppInventory.readInfoPlist(bundleAt: $0)?["CFBundleIdentifier"] as? String == application.bundleIdentifier
        }) {
            return exact
        }
        let atTop = candidates.filter {
            $0.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
        }
        if atTop.count == 1 { return atTop[0] }
        return candidates.first
    }

    // MARK: - Backup folder

    func updateBackupDirectory() throws -> URL {
        let trash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        if !fileManager.fileExists(atPath: trash.path) {
            try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        }
        return trash
    }

    /// Moves a finished workspace to the user's Trash. Housekeeping never deletes
    /// outright, and a temporary folder is not an exception to that rule — it is
    /// just the case where moving rather than deleting costs nothing.
    private func discardToTrash(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let trash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        var destination = trash.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            destination = trash.appendingPathComponent("\(url.lastPathComponent)-\(stamp())")
        }
        try? fileManager.moveItem(at: url, to: destination)
    }

    private func stamp() -> String { String(Int(Date().timeIntervalSince1970)) }

    private func escaped(_ url: URL) -> String { url.homeAbbreviatedPath }
}

// MARK: - Appcast

/// Reads a Sparkle-style update feed and keeps the newest release it names. The
/// element names carry the `sparkle:` prefix because the parser is left in its
/// default namespace mode, which is what the published feeds contain.
final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item {
        var shortVersion: String?
        var version: String?
        var enclosureURL: String?
    }

    private var items: [Item] = []
    private var current: Item?
    private var buffer = ""

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    /// The newest item, by the same numeric comparison the version footer uses so
    /// that 1.10 beats 1.9. Returns nil only when the feed named no release at
    /// all; an item without a version is skipped rather than guessed at.
    func newest() -> Item? {
        var best: Item?
        for item in items {
            guard let version = item.shortVersion ?? item.version, !version.isEmpty else { continue }
            guard let currentBest = best,
                  let bestVersion = currentBest.shortVersion ?? currentBest.version else {
                best = item
                continue
            }
            if AppState.isNewer(AppState.normalize(version), than: AppState.normalize(bestVersion)) {
                best = item
            }
        }
        return best
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        buffer = ""
        if elementName == "item" {
            current = Item()
        } else if elementName == "enclosure", let url = attributeDict["url"] {
            current?.enclosureURL = url
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "sparkle:shortVersionString":
            current?.shortVersion = text
        case "sparkle:version":
            current?.version = text
        case "item":
            if let current { items.append(current) }
            current = nil
        default:
            break
        }
        buffer = ""
    }
}
