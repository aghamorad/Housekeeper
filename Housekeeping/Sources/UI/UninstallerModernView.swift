// Housekeeping — Dedicated App Uninstaller
//
// CleanMyMac-style application uninstaller.
// Discovers installed applications and all related leftovers (Application Support,
// Caches, Preferences, Saved State, Containers) with granular selection and safe Quarantine removal.

import SwiftUI
import AppKit

@MainActor
final class UninstallerModel: ObservableObject {
    static let shared = UninstallerModel()

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var scanProgress: String = ""
    @Published private(set) var scanNotice: String?
    /// Set when a search or filter change cleared apps the reader can no longer
    /// see, so a selection never disappears without a word.
    @Published private(set) var selectionNotice: String?
    /// How many selections the current search or filter has cleared, cumulatively,
    /// so the notice reports the whole loss rather than only the last keystroke.
    private var clearedSelectionCount = 0
    private var scanWorker: Task<[InstalledApp], Never>?
    private var scanToken = UUID()
    @Published var selectedAppURLs: Set<URL> = []
    private var selectionAnchorURL: URL?
    @Published var expandedAppURLs: Set<URL> = []
    @Published var searchQuery: String = "" {
        didSet {
            // A notice about the last clearing stays until the reader empties the
            // search or makes a new explicit choice; clearing it on every
            // keystroke would erase the message the first character produced.
            if searchQuery.isEmpty {
                selectionNotice = nil
                clearedSelectionCount = 0
            }
            retainOnlyVisibleSelections()
        }
    }
    @Published var sortOption: AppSortOption = .sizeDescending
    @Published var filterOption: AppFilterOption = .all {
        didSet {
            clearedSelectionCount = 0
            retainOnlyVisibleSelections()
        }
    }
    @Published private(set) var isWorking = false
    @Published private(set) var outcome: String?
    @Published private(set) var failures: [String] = []
    @Published private(set) var includedRelatedPaths: Set<String> = []
    @Published var includeLeftoversByDefault: Bool = true
    @Published var pendingUninstallPlan: [InstalledApp]? = nil
    @Published private(set) var session: UninstallSession?

    public enum AppFilterOption: String, CaseIterable, Identifiable, Sendable {
        case all = "All Apps"
        case withLeftovers = "With Leftovers"
        case cleanOnly = "Clean Bundles"

        public var id: String { rawValue }
    }

    var appsWithLeftoversCount: Int {
        apps.filter { !$0.leftovers.isEmpty }.count
    }

    var cleanAppsCount: Int {
        apps.filter { $0.leftovers.isEmpty }.count
    }

    var allExpanded: Bool {
        let targets = filteredApps.filter { !$0.leftovers.isEmpty }
        guard !targets.isEmpty else { return false }
        return targets.allSatisfy { expandedAppURLs.contains($0.url) }
    }

    func expandAll() {
        for app in filteredApps where !app.leftovers.isEmpty {
            expandedAppURLs.insert(app.url)
        }
    }

    func collapseAll() {
        expandedAppURLs.removeAll()
    }

    init() {
        startScan()
    }

    func startScan() {
        guard !isScanning, !isWorking else { return }
        isScanning = true
        MotionBudget.shared.hold("uninstaller-scan")
        scanNotice = nil
        scanProgress = "Discovering applications…"
        let token = UUID()
        scanToken = token

        let progress: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in
                guard let self, self.scanToken == token, self.isScanning else { return }
                self.scanProgress = line
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            Uninstaller.installed(progress: progress)
        }
        scanWorker = worker
        Task { @MainActor [weak self] in
            let results = await worker.value
            guard let self, self.scanToken == token, !worker.isCancelled else { return }
            self.apps = results
            self.selectedAppURLs.formIntersection(Set(results.map(\.url)))
            self.expandedAppURLs.formIntersection(Set(results.map(\.url)))
            // New related files remain excluded until deliberately selected.
            self.includedRelatedPaths.formIntersection(Set(results.flatMap(\.leftovers).map(\.id)))
            self.isScanning = false
            self.scanWorker = nil
            self.scanProgress = ""
            MotionBudget.shared.release("uninstaller-scan")
        }
    }

    func stopScan() {
        guard isScanning else { return }
        scanToken = UUID()
        scanWorker?.cancel()
        scanWorker = nil
        isScanning = false
        scanProgress = ""
        MotionBudget.shared.release("uninstaller-scan")
        scanNotice = "Scan stopped. Existing complete results are still shown; click Refresh to start again."
    }

    var filteredApps: [InstalledApp] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        var matching = query.isEmpty ? apps : apps.filter {
            $0.name.lowercased().contains(query) ||
            ($0.bundleIdentifier?.lowercased().contains(query) ?? false)
        }
        switch filterOption {
        case .all:
            break
        case .withLeftovers:
            matching = matching.filter { !$0.leftovers.isEmpty }
        case .cleanOnly:
            matching = matching.filter { $0.leftovers.isEmpty }
        }
        return matching.sorted { lhs, rhs in
            switch sortOption {
            case .sizeDescending:
                if lhs.totalSize != rhs.totalSize { return lhs.totalSize > rhs.totalSize }
            case .sizeAscending:
                if lhs.totalSize != rhs.totalSize { return lhs.totalSize < rhs.totalSize }
            case .nameAscending:
                let comp = lhs.name.localizedStandardCompare(rhs.name)
                if comp != .orderedSame { return comp == .orderedAscending }
            case .nameDescending:
                let comp = lhs.name.localizedStandardCompare(rhs.name)
                if comp != .orderedSame { return comp == .orderedDescending }
            case .modifiedNewest:
                if let l = lhs.modifiedDate, let r = rhs.modifiedDate, l != r { return l > r }
                if (lhs.modifiedDate != nil) != (rhs.modifiedDate != nil) { return lhs.modifiedDate != nil }
            case .modifiedOldest:
                if let l = lhs.modifiedDate, let r = rhs.modifiedDate, l != r { return l < r }
                if (lhs.modifiedDate != nil) != (rhs.modifiedDate != nil) { return lhs.modifiedDate != nil }
            case .installedNewest:
                if let l = lhs.createdDate, let r = rhs.createdDate, l != r { return l > r }
                if (lhs.createdDate != nil) != (rhs.createdDate != nil) { return lhs.createdDate != nil }
            case .installedOldest:
                if let l = lhs.createdDate, let r = rhs.createdDate, l != r { return l < r }
                if (lhs.createdDate != nil) != (rhs.createdDate != nil) { return lhs.createdDate != nil }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func retainOnlyVisibleSelections() {
        guard !isWorking else { return }
        // A hidden app must never be removed when someone presses Uninstall
        // Selected after changing a search or category filter — and it must not
        // disappear from the count without telling the reader either.
        let visible = Set(filteredApps.map(\.url))
        let hidden = selectedAppURLs.subtracting(visible)
        guard !hidden.isEmpty else { return }
        selectedAppURLs.formIntersection(visible)
        clearedSelectionCount += hidden.count
        let count = clearedSelectionCount
        selectionNotice = "\(count) selected app\(count == 1 ? "" : "s") \(count == 1 ? "is" : "are") hidden by the current search or filter and \(count == 1 ? "was" : "were") cleared. Clear the search to choose across searches."
    }

    func selectAllFiltered() {
        guard !isWorking && !isScanning else { return }
        selectionNotice = nil
        clearedSelectionCount = 0
        for app in filteredApps {
            selectedAppURLs.insert(app.url)
        }
    }

    func deselectAll() {
        selectionNotice = nil
        clearedSelectionCount = 0
        selectedAppURLs.removeAll()
    }

    /// One-tap Smart Select for apps with leftover residue (Mole & Purge style).
    /// Selects all applications that have associated leftover files in ~/Library and marks their leftovers for quarantine.
    func selectAppsWithLeftovers() {
        guard !isWorking && !isScanning else { return }
        selectionNotice = nil
        clearedSelectionCount = 0
        filterOption = .withLeftovers
        for app in apps where !app.leftovers.isEmpty {
            selectedAppURLs.insert(app.url)
            setRelatedFiles(app, included: true)
            expandedAppURLs.insert(app.url)
        }
    }

    var selectedTotalSize: Int64 {
        apps.filter { selectedAppURLs.contains($0.url) }.reduce(0) { total, app in
            total + app.size + includedLeftovers(app).reduce(0) { $0 + $1.size }
        }
    }

    /// Plain click selects one, Command-click adds or removes one, Shift-click
    /// takes the run between the last click and this one — the behaviour every
    /// Mac list has, and the only practical way to pick a dozen apps at once.
    func applySelectionClick(_ app: InstalledApp, order: [URL]) {
        RowSelection.apply(
            id: app.url,
            order: order,
            selection: &selectedAppURLs,
            anchor: &selectionAnchorURL
        )
    }

    func toggleSelection(_ app: InstalledApp) {
        guard !isWorking && !isScanning else { return }
        selectionNotice = nil
        clearedSelectionCount = 0
        if selectedAppURLs.contains(app.url) {
            selectedAppURLs.remove(app.url)
        } else {
            selectedAppURLs.insert(app.url)
        }
    }

    func toggleExpand(_ app: InstalledApp) {
        if expandedAppURLs.contains(app.url) {
            expandedAppURLs.remove(app.url)
        } else {
            expandedAppURLs.insert(app.url)
        }
    }

    var usesQuarantine: Bool { CleanupModeSettings.isQuarantineModeEnabled }

    /// One press, one app: moves the app (plus its matched leftovers when
    /// `includeLeftoversByDefault` is on) straight to macOS Trash — or to
    /// Quarantine only if the user turned on Quarantine Mode.
    func uninstallImmediately(_ app: InstalledApp) {
        guard !isWorking, !isScanning, !app.isRunning else { return }
        selectedAppURLs = [app.url]
        let unprotected = app.leftovers.filter { !ProtectionList().isProtected($0.url) }.map(\.id)
        if includeLeftoversByDefault {
            includedRelatedPaths.formUnion(unprotected)
        } else {
            includedRelatedPaths.subtract(unprotected)
        }
        prepareUninstall()
        executeUninstall()
    }

    /// Quits a running app gracefully, waits up to 4 seconds for it to exit,
    /// and then uninstalls it automatically in one smooth flow.
    func quitAndUninstall(_ app: InstalledApp) {
        guard !isWorking, !isScanning else { return }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL
                || (app.bundleIdentifier != nil && $0.bundleIdentifier == app.bundleIdentifier)
        }
        guard !running.isEmpty else {
            uninstallImmediately(app)
            return
        }
        for proc in running { _ = proc.terminate() }
        outcome = "Closing \(app.name)…"
        failures = []

        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(4.0)
            while Date() < deadline {
                let stillRunning = NSWorkspace.shared.runningApplications.contains {
                    !$0.isTerminated && (
                        $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL
                        || (app.bundleIdentifier != nil && $0.bundleIdentifier == app.bundleIdentifier)
                    )
                }
                if !stillRunning { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let stillOpen = NSWorkspace.shared.runningApplications.contains {
                !$0.isTerminated && (
                    $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL
                    || (app.bundleIdentifier != nil && $0.bundleIdentifier == app.bundleIdentifier)
                )
            }
            if stillOpen {
                self.outcome = nil
                self.failures = ["\(app.name) is still open (it may have unsaved work). Quit it first, then click Uninstall."]
            } else {
                self.uninstallImmediately(app)
            }
        }
    }

    func prepareUninstall() {
        guard !isWorking, !isScanning else { return }
        retainOnlyVisibleSelections()
        outcome = nil
        let selected = apps.filter { selectedAppURLs.contains($0.url) }
        let targets = selected.filter { !$0.isRunning && !ProtectionList().isProtected($0.url) }
        failures = selected.filter { $0.isRunning || ProtectionList().isProtected($0.url) }.map {
            $0.isRunning ? "\($0.name) is open. Quit it, then try again." : "\($0.name) is on the Leave Alone list."
        }
        guard !targets.isEmpty else { return }
        if includeLeftoversByDefault {
            for app in targets {
                includedRelatedPaths.formUnion(
                    app.leftovers.filter { !ProtectionList().isProtected($0.url) }.map(\.id)
                )
            }
        }
        pendingUninstallPlan = targets
    }

    func requestQuit(_ app: InstalledApp) {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL
                || (app.bundleIdentifier != nil && $0.bundleIdentifier == app.bundleIdentifier)
        }
        let accepted = running.map { $0.terminate() }.allSatisfy { $0 }
        outcome = accepted
            ? "Quit requested for \(app.name). Save any open work, then click Uninstall when it has closed."
            : "\(app.name) could not be closed. Quit it from its own menu, then try Uninstall again."
        failures = []
    }

    func includedLeftovers(_ app: InstalledApp) -> [CleanCandidate] {
        app.leftovers.filter { includedRelatedPaths.contains($0.id) && !ProtectionList().isProtected($0.url) }
    }

    func setRelatedFiles(_ app: InstalledApp, included: Bool) {
        let paths = app.leftovers.filter { !ProtectionList().isProtected($0.url) }.map(\.id)
        if included { includedRelatedPaths.formUnion(paths) }
        else { includedRelatedPaths.subtract(paths) }
    }

    func setRelatedFile(_ item: CleanCandidate, included: Bool) {
        guard !ProtectionList().isProtected(item.url) else { return }
        if included { includedRelatedPaths.insert(item.id) }
        else { includedRelatedPaths.remove(item.id) }
    }

    func executeUninstall() {
        guard !isWorking, let planned = pendingUninstallPlan else { return }
        let quarantineEnabled = usesQuarantine
        let targets = Uninstaller.unambiguousLeftovers(in: planned.map { app in
            var copy = app
            copy.leftovers = includedLeftovers(app)
            return copy
        })
        pendingUninstallPlan = nil
        isWorking = true
        MotionBudget.shared.hold("uninstaller-work")
        outcome = nil
        let skipped = failures
        Task { @MainActor [weak self] in
            guard let self else { return }

            if quarantineEnabled {
                let engine = CleanupEngine()
                self.session = UninstallSession(apps: targets)
                do {
                    let result = try await engine.uninstall(targets) { [weak self] event in
                        await self?.receiveProgress(event)
                    }
                    self.session?.finish(result: result)
                    let movedSet = Set(result.movedPaths)
                    let appCount = targets.filter { movedSet.contains($0.url.path) }.count
                    let relatedCount = targets.flatMap(\.leftovers).filter { movedSet.contains($0.url.path) }.count
                    if appCount > 0 {
                        let leftoverNote = relatedCount > 0
                            ? " and \(relatedCount) leftover item\(relatedCount == 1 ? "" : "s")"
                            : ""
                        self.outcome = "Moved \(appCount) app\(appCount == 1 ? "" : "s")\(leftoverNote) to Quarantine."
                    }
                    let failedMoves = result.moves.filter { !$0.succeeded }.map { "\($0.path) — \($0.message ?? "could not be moved")" }
                    self.failures = skipped + failedMoves
                    self.selectedAppURLs.subtract(targets.filter { movedSet.contains($0.url.path) }.map(\.url))
                    self.apps.removeAll { movedSet.contains($0.url.path) }
                } catch {
                    self.session?.finish(error: error.localizedDescription)
                    self.failures = skipped + [error.localizedDescription]
                }
                self.isWorking = false
                MotionBudget.shared.release("uninstaller-work")
                self.startScan()
                return
            }

            let outcomeResult = await Task.detached(priority: .userInitiated) {
                Self.moveAppsDirectlyToTrash(targets)
            }.value

            let movedIDs = outcomeResult.movedIDs
            let appCount = targets.filter { movedIDs.contains($0.id) }.count
            let relatedCount = targets.flatMap(\.leftovers).filter { movedIDs.contains($0.id) }.count
            if appCount > 0 {
                let leftoverNote = relatedCount > 0
                    ? " and \(relatedCount) leftover item\(relatedCount == 1 ? "" : "s")"
                    : ""
                self.outcome = "Uninstalled \(appCount) app\(appCount == 1 ? "" : "s")\(leftoverNote) straight to macOS Trash."
            }
            self.failures = skipped + outcomeResult.errors
            self.selectedAppURLs.subtract(targets.filter { movedIDs.contains($0.id) }.map(\.url))
            self.apps.removeAll { movedIDs.contains($0.id) }
            self.isWorking = false
            MotionBudget.shared.release("uninstaller-work")
            self.startScan()
        }
    }

    private nonisolated static func moveAppsDirectlyToTrash(_ targets: [InstalledApp]) -> (movedIDs: Set<String>, errors: [String]) {
        var moved = Set<String>()
        var errors: [String] = []
        let fm = FileManager.default

        func trashOne(_ url: URL, id: String) {
            guard fm.fileExists(atPath: url.path) else { return }
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                moved.insert(id)
                return
            } catch {
                // Fallback to Finder AppleScript (prompts macOS admin password cleanly for /Applications owned by root).
                let escaped = url.path
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let script = "tell application \"Finder\" to delete (POSIX file \"\(escaped)\" as alias)"
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                try? proc.run()
                proc.waitUntilExit()
                if !fm.fileExists(atPath: url.path) {
                    moved.insert(id)
                } else {
                    errors.append("\(url.lastPathComponent) — \(error.localizedDescription)")
                }
            }
        }

        for app in targets {
            trashOne(app.url, id: app.id)
            if moved.contains(app.id) {
                for leftover in app.leftovers {
                    trashOne(leftover.url, id: leftover.id)
                }
            }
        }
        return (moved, errors)
    }

    private func receiveProgress(_ event: UninstallProgress) {
        session?.receive(event)
    }

    func dismissSession() {
        guard !isWorking else { return }
        session = nil
    }

}

struct UninstallerModernView: View {
    @ObservedObject var model: UninstallerModel = .shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.uiStyle) private var style

    var body: some View {
        Group {
            if let session = model.session {
                UninstallActivityView(session: session, done: model.dismissSession) {
                    appState.refreshQuarantineAvailability()
                    appState.showQuarantineManagement = true
                }
            } else {
                browser
            }
        }
        .background { HousekeepingBackdrop(style: style) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            model.objectWillChange.send()
        }
        .sheet(item: Binding(
            get: { model.pendingUninstallPlan.map { UninstallPlanWrapper(items: $0) } },
            set: { model.pendingUninstallPlan = $0?.items }
        )) { wrapper in
            uninstallConfirmationSheet(wrapper.items)
                .housekeepingSurface(style)
        }
    }

    private var browser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let notice = model.scanNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(style.smallFont)
                        .foregroundStyle(style.secondaryText)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 9))
                }
                searchAndActionBar
                if let notice = model.selectionNotice {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(style.smallFont)
                        .foregroundStyle(style.secondaryText)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 9))
                }
                if model.isScanning && !model.apps.isEmpty { scanningView }
                if model.outcome != nil || !model.failures.isEmpty {
                    ThemePanel {
                        VStack(alignment: .leading, spacing: 10) {
                            if let outcome = model.outcome { Text(outcome).font(style.bodyFont) }
                            ForEach(model.failures, id: \.self) { failure in
                                Text(failure).font(style.smallFont).foregroundColor(style.negative).textSelection(.enabled)
                            }
                            ThemeButton(title: "Open Trash in Finder", systemImage: "trash") {
                                let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
                                NSWorkspace.shared.open(trashURL)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if model.isScanning && model.apps.isEmpty {
                    scanningView
                } else if model.filteredApps.isEmpty {
                    emptyView
                } else {
                    appsList
                }
            }
            .padding(32)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { HousekeepingBackdrop(style: style) }
        .disabled(model.isWorking)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Uninstall Apps")
                    .font(style.isRetro ? style.titleFont : .system(size: 26, weight: .semibold, design: .rounded))
                Text(model.usesQuarantine
                     ? "Click Uninstall to move an app and its leftovers to Quarantine."
                     : "Click Uninstall and it goes straight to macOS Trash — along with its leftovers.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.filteredApps.count) apps")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ThemeButton(
                title: "Refresh",
                systemImage: "arrow.clockwise",
                isEnabled: !model.isScanning
            ) {
                model.startScan()
            }
        }
    }

    // MARK: - Search & Action Bar

    private var searchAndActionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Single sleek control bar — no 3-row toolbar clutter.
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Search apps…", text: $model.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !model.searchQuery.isEmpty {
                        Button {
                            model.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(style.rowBackground, in: Capsule())
                .overlay(Capsule().stroke(style.border, lineWidth: 0.75))
                .frame(maxWidth: 260)

                Picker("Filter", selection: $model.filterOption) {
                    Text("All (\(model.apps.count))").tag(UninstallerModel.AppFilterOption.all)
                    Text("With Leftovers (\(model.appsWithLeftoversCount))").tag(UninstallerModel.AppFilterOption.withLeftovers)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)

                Menu {
                    Picker("Sort by", selection: $model.sortOption) {
                        ForEach(AppSortOption.allCases) { opt in
                            Label(opt.rawValue, systemImage: opt.systemImage)
                                .tag(opt)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(style.accent)
                        Text(model.sortOption.rawValue)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(style.rowBackground, in: Capsule())
                    .overlay(Capsule().stroke(style.border, lineWidth: 0.75))
                }
                .menuStyle(.borderlessButton)

                Spacer(minLength: 4)

                Toggle("Include leftovers", isOn: $model.includeLeftoversByDefault)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12, weight: .medium))
                    .help("Remove matched ~/Library caches and support files together with the app.")
            }

            // Contextual bulk bar — appears only when apps are ticked.
            if !model.selectedAppURLs.isEmpty {
                HStack(spacing: 12) {
                    Text("\(model.selectedAppURLs.count) selected · \(ByteCountFormatter.string(fromByteCount: model.selectedTotalSize, countStyle: .file))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(style.text)
                        .monospacedDigit()
                    Spacer()
                    Button("Clear") {
                        model.deselectAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                    ThemeButton(
                        title: "Uninstall \(model.selectedAppURLs.count) Selected",
                        systemImage: "trash.fill",
                        isDestructive: true
                    ) {
                        model.prepareUninstall()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .housekeepingCard(cornerRadius: 12, highlighted: true)
            }
        }
    }

    // MARK: - Apps List

    private var appsList: some View {
        LazyVStack(spacing: 8) {
            ForEach(model.filteredApps) { app in
                appRow(app)
            }
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let isSelected = model.selectedAppURLs.contains(app.url)
        let isExpanded = model.expandedAppURLs.contains(app.url)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { _ in model.toggleSelection(app) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)

                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(app.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if let v = app.version {
                            Text("v\(v)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if app.isRunning {
                            Text("Open")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(style.caution)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(style.caution.opacity(0.14), in: Capsule())
                        }
                    }

                    if !app.leftovers.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                                model.toggleExpand(app)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(app.leftovers.count) leftover\(app.leftovers.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: app.leftoverSize, countStyle: .file))")
                                    .font(.system(size: 11.5, weight: .medium))
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8.5, weight: .bold))
                            }
                            .foregroundStyle(style.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Show or hide matched ~/Library files for \(app.name)")
                    } else {
                        Text("No leftover files")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Text(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(style.text)
                    .frame(minWidth: 68, alignment: .trailing)

                ThemeButton(
                    title: app.isRunning ? "Quit & Uninstall" : "Uninstall",
                    systemImage: app.isRunning ? "stop.circle" : "trash",
                    isDestructive: !app.isRunning,
                    isEnabled: !model.isScanning
                ) {
                    if app.isRunning {
                        model.quitAndUninstall(app)
                    } else {
                        model.uninstallImmediately(app)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if isExpanded {
                Divider().padding(.horizontal, 14)
                leftoversDetail(app)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.applySelectionClick(app, order: model.filteredApps.map(\.url))
        }
        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? style.accent : style.border, lineWidth: isSelected ? 1.25 : 0.75)
        )
        .contextMenu {
            Button {
                HousekeeperTopic.ask(.installedApp(app))
            } label: {
                Label("Ask the Housekeeper About \(app.name)", systemImage: "sparkles")
            }

            Divider()

            Button {
                NSWorkspace.shared.open(app.url)
            } label: {
                Label("Open \(app.name)", systemImage: "arrow.up.forward.app")
            }

            Button {
                NSWorkspace.shared.selectFile(app.url.path, inFileViewerRootedAtPath: app.url.deletingLastPathComponent().path)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.url.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            Button {
                _ = ProtectionList().protect(path: app.url.path, kind: "Installed App")
            } label: {
                Label("Add to Ignore List (Leave Alone)", systemImage: "eye.slash")
            }

            if !app.leftovers.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.toggleExpand(app)
                    }
                } label: {
                    Label(isExpanded ? "Hide Leftovers" : "Inspect Leftovers (\(app.leftovers.count))", systemImage: "folder.badge.gearshape")
                }
            }

            Divider()

            Button(role: .destructive) {
                model.selectedAppURLs = [app.url]
                model.prepareUninstall()
            } label: {
                Label("Uninstall \(app.name)", systemImage: "trash")
            }
        }
    }

    private func leftoversDetail(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header summary bar
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(style.accent)
                    Text("Found Related Files (\(app.leftovers.count))")
                        .font(.system(size: 12, weight: .bold))
                }

                Spacer()

                HStack(spacing: 12) {
                    Text("Bundle: \(ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text("Leftovers: \(ByteCountFormatter.string(fromByteCount: app.leftoverSize, countStyle: .file))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(style.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            Text("These are shown for inspection, not automatically selected for removal.")
                .font(.system(size: 11))
                .foregroundStyle(style.secondaryText)
                .padding(.horizontal, 16)

            VStack(spacing: 6) {
                // Main Application Bundle
                HStack(spacing: 10) {
                    Image(systemName: "app.fill")
                        .foregroundStyle(style.accent)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Application Binary")
                                .font(.system(size: 12, weight: .semibold))
                            badgeTag(label: "Main App Bundle", icon: "app.badge", color: .blue)
                        }
                        Text(abbreviatedPath(app.url))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Text(ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([app.url])
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Reveal")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Reveal main app bundle in Finder")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))

                // Leftover items
                ForEach(app.leftovers) { leftover in
                    let badge = categoryBadge(for: leftover.url)
                    HStack(spacing: 10) {
                        Image(systemName: badge.icon)
                            .foregroundStyle(badge.color)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(leftover.name)
                                    .font(.system(size: 12, weight: .medium))
                                badgeTag(label: badge.label, icon: badge.icon, color: badge.color)
                            }
                            Text(abbreviatedPath(leftover.url))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Spacer()

                        Text(ByteCountFormatter.string(fromByteCount: leftover.size, countStyle: .file))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([leftover.url])
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.right.square")
                                Text("Reveal")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help("Reveal this leftover in Finder")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
                    .contextMenu {
                        Button {
                            HousekeeperTopic.ask(.candidate(leftover))
                        } label: {
                            Label("Ask the Housekeeper About This Item", systemImage: "sparkles")
                        }

                        Divider()

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([leftover.url])
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(leftover.url.path, forType: .string)
                        } label: {
                            Label("Copy Path", systemImage: "doc.on.doc")
                        }

                        Button {
                            _ = ProtectionList().protect(path: leftover.url.path, kind: "Uninstaller Leftovers")
                        } label: {
                            Label("Add to Ignore List (Leave Alone)", systemImage: "eye.slash")
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .background(Color.primary.opacity(0.03))
    }

    private func badgeTag(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(label)
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }

    private func abbreviatedPath(_ url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func categoryBadge(for url: URL) -> (label: String, icon: String, color: Color) {
        let path = url.path
        if path.contains("/Library/Application Support/") {
            return ("App Support", "folder.fill", .blue)
        } else if path.contains("/Library/Caches/") {
            return ("Caches", "archivebox.fill", .orange)
        } else if path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/") {
            return ("Sandbox", "shippingbox.fill", .purple)
        } else if path.contains("/Library/Preferences/") {
            return ("Preferences", "slider.horizontal.3", .green)
        } else if path.contains("/Library/Saved Application State/") {
            return ("Saved State", "clock.arrow.circlepath", .teal)
        } else if path.contains("/Library/WebKit/") {
            return ("WebKit", "safari.fill", .indigo)
        } else if path.contains("/Library/Logs/") {
            return ("Logs", "doc.text.fill", .gray)
        } else {
            return ("Leftover", "folder.fill", .orange)
        }
    }

    // MARK: - Scanning & Empty Views

    private var scanningView: some View {
        HousekeeperScanningBanner(
            title: "Housekeeper is finding installed apps & leftovers…",
            subtitle: "Reading applications and associated files safely. No files are changed.",
            currentItem: model.scanProgress.isEmpty ? nil : model.scanProgress,
            stepCount: model.apps.isEmpty ? nil : "\(model.apps.count) found",
            onStop: { model.stopScan() }
        )
        .padding(.vertical, 8)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No applications found matching \"\(model.searchQuery)\"")
                .font(.system(size: 14, weight: .medium))
        }
        .frame(maxWidth: .infinity)
        .padding(48)
    }

    // MARK: - Confirmation Sheet

    private func uninstallConfirmationSheet(_ targets: [InstalledApp]) -> some View {
        let included = targets.flatMap { model.includedLeftovers($0) }
        let size = targets.reduce(Int64(0)) { $0 + $1.size } + included.reduce(0) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: model.usesQuarantine ? "archivebox.fill" : "trash.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(model.usesQuarantine ? style.accent : style.negative)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.usesQuarantine ? "Move Apps to Quarantine" : "Uninstall Apps to Trash")
                        .font(.system(size: 18, weight: .bold))
                    Text(model.usesQuarantine
                         ? "Selected apps and ticked leftovers move into ~/Housekeeping Quarantine where you can restore them anytime."
                         : "Selected apps and ticked leftovers go straight to macOS Trash. Untick any leftover you want to keep.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 18) {
                Label("\(targets.count) app\(targets.count == 1 ? "" : "s")", systemImage: "square.stack.3d.up")
                Label("\(included.count) related items included", systemImage: "folder")
                Spacer()
                Text(size.sizeDescription).monospacedDigit()
            }
            .font(.system(size: 14, weight: .semibold))
            .padding(14).background(style.rowSelection, in: RoundedRectangle(cornerRadius: 10))

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(targets) { app in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable()
                                .frame(width: 36, height: 36)
                            Text(app.name)
                                .font(.system(size: 15, weight: .bold))
                            Spacer()
                            Text((app.size + model.includedLeftovers(app).reduce(0) { $0 + $1.size }).sizeDescription)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(app.url.homeAbbreviatedPath).font(style.pathFont).textSelection(.enabled)
                        if !app.leftovers.isEmpty {
                            HStack {
                                Text("\(model.includedLeftovers(app).count) of \(app.leftovers.count) related files included")
                                    .font(.system(size: 13)).foregroundStyle(style.secondaryText)
                                Spacer()
                                Button("Include All (review first)") { model.setRelatedFiles(app, included: true) }
                                    .frame(minHeight: 44)
                                Button("Keep All Related Files") { model.setRelatedFiles(app, included: false) }
                                    .frame(minHeight: 44)
                            }
                        }
                        ForEach(app.leftovers) { item in
                            Toggle(isOn: Binding(
                                get: { model.includedRelatedPaths.contains(item.id) && !ProtectionList().isProtected(item.url) },
                                set: { include in model.setRelatedFile(item, included: include) }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(item.name) · \(item.size.sizeDescription)").font(style.bodyFont)
                                    Text(categoryBadge(for: item.url).label)
                                        .font(.system(size: 12, weight: .medium)).foregroundStyle(style.accent)
                                    Text(item.url.homeAbbreviatedPath).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                    if ProtectionList().isProtected(item.url) {
                                        Label("Kept: on the Leave Alone list", systemImage: "hand.raised")
                                            .font(.system(size: 12)).foregroundStyle(style.caution)
                                    }
                                }
                            }
                            .disabled(ProtectionList().isProtected(item.url))
                            .padding(.vertical, 6).frame(minHeight: 48)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 340)

            Divider()

            HStack {
                ThemeButton(title: "Cancel", systemImage: "xmark") {
                    model.pendingUninstallPlan = nil
                }
                Spacer()
                ThemeButton(
                    title: model.usesQuarantine
                        ? "Move \(targets.count) App\(targets.count == 1 ? "" : "s") to Quarantine"
                        : "Uninstall \(targets.count) App\(targets.count == 1 ? "" : "s")",
                    systemImage: model.usesQuarantine ? "archivebox.fill" : "trash.fill",
                    isPrimary: model.usesQuarantine,
                    isDestructive: !model.usesQuarantine
                ) {
                    model.executeUninstall()
                }
            }
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 500)
    }
}

private struct UninstallPlanWrapper: Identifiable {
    var id: String { items.map(\.id).joined(separator: ",") }
    let items: [InstalledApp]
}
