// Housekeeping — Space Analyzer & Storage Intelligence
//
// Fast, non-blocking disk capacity analyzer, app sizer, and folder explorer.
// Powers the Space Lens storage view with instant volume stats, category breakdowns,
// real folder & .app bundle sizing, large file discovery, and safe Trash actions.

import Foundation
import AppKit

public struct StorageCategory: Identifiable, Sendable {
    public let id: String
    public let name: String
    public var size: Int64
    public let colorName: String
    public let icon: String
    public var isCalculating: Bool

    public init(
        id: String,
        name: String,
        size: Int64,
        colorName: String,
        icon: String,
        isCalculating: Bool = false
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.colorName = colorName
        self.icon = icon
        self.isCalculating = isCalculating
    }

    public var humanSize: String {
        if isCalculating && size == 0 {
            return "Measuring…"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

public struct StorageItem: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public var size: Int64
    public let isDirectory: Bool
    public let isPackage: Bool
    public var isMeasuring: Bool
    public let modifiedDate: Date?
    public let kind: String
    public let appVersion: String?
    public let parentDisplayPath: String

    public init(
        url: URL,
        name: String,
        size: Int64,
        isDirectory: Bool,
        isPackage: Bool = false,
        isMeasuring: Bool = false,
        modifiedDate: Date?,
        kind: String,
        appVersion: String? = nil,
        parentDisplayPath: String = ""
    ) {
        self.url = url
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isMeasuring = isMeasuring
        self.modifiedDate = modifiedDate
        self.kind = kind
        self.appVersion = appVersion
        self.parentDisplayPath = parentDisplayPath
    }

    public var humanSize: String {
        if isMeasuring && size == 0 {
            return "Measuring…"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

@MainActor
public final class SpaceAnalyzer: ObservableObject {
    public static let shared = SpaceAnalyzer()

    @Published public private(set) var volumeName: String = "Macintosh HD"
    @Published public private(set) var totalDiskBytes: Int64 = 0
    @Published public private(set) var freeDiskBytes: Int64 = 0
    @Published public private(set) var usedDiskBytes: Int64 = 0
    @Published public private(set) var isAnalyzing: Bool = false

    @Published public private(set) var categories: [StorageCategory] = []
    @Published public private(set) var installedApps: [StorageItem] = []
    @Published public private(set) var isLoadingApps: Bool = false
    @Published public private(set) var largeFiles: [StorageItem] = []

    @Published public private(set) var currentFolderItems: [StorageItem] = []
    @Published public private(set) var currentFolderTotalBytes: Int64 = 0
    @Published public private(set) var currentFolderPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published public private(set) var isMeasuringFolder: Bool = false
    @Published public private(set) var folderMeasureProgress: String? = nil

    @Published public private(set) var navigationHistory: [String] = []
    @Published public private(set) var forwardHistory: [String] = []
    @Published public var showHiddenFiles: Bool = false
    @Published public var trashError: String? = nil

    @Published public private(set) var subfolderSearchResults: [StorageItem] = []
    @Published public private(set) var isSearchingSubfolders: Bool = false

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var sizeCache: [String: Int64] = [:]
    private var folderMeasureTask: Task<Void, Never>?
    private var appsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    /// Paths skipped when measuring `/` so APFS firmlinks and virtual mounts are never double-counted.
    private nonisolated static let skippedRootSubpaths: Set<String> = [
        "/System/Volumes/Data",
        "/System/Volumes/VM",
        "/.vol",
        "/Volumes",
        "/dev",
        "/net",
        "/home",
        "/.MobileBackups"
    ]

    public init() {
        refreshVolumeInfo()
        loadFolder(path: home.path)
        startCategoryAnalysis()
        loadApps()
    }

    public var usedFraction: Double {
        guard totalDiskBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedDiskBytes) / Double(totalDiskBytes)))
    }

    public func refreshVolumeInfo() {
        do {
            let values = try home.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            if let name = values.volumeName, !name.isEmpty {
                volumeName = name
            }
            if let total = values.volumeTotalCapacity {
                totalDiskBytes = Int64(total)
            }
            if let avail = values.volumeAvailableCapacityForImportantUsage, avail > 0 {
                freeDiskBytes = avail
            } else if let avail = values.volumeAvailableCapacity {
                freeDiskBytes = Int64(avail)
            } else {
                let fsAttrs = try FileManager.default.attributesOfFileSystem(forPath: home.path)
                freeDiskBytes = (fsAttrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            }
            usedDiskBytes = max(0, totalDiskBytes - freeDiskBytes)
        } catch {
            totalDiskBytes = 500_000_000_000
            freeDiskBytes = 150_000_000_000
            usedDiskBytes = 350_000_000_000
        }
    }

    // MARK: - Category Analysis & Large Files

    public func startCategoryAnalysis() {
        analysisTask?.cancel()
        isAnalyzing = true
        let homeURL = self.home

        if self.categories.isEmpty {
            self.categories = [
                StorageCategory(id: "apps", name: "Applications", size: 0, colorName: "blue", icon: "app.badge", isCalculating: true),
                StorageCategory(id: "dev", name: "Developer & Caches", size: 0, colorName: "purple", icon: "hammer.fill", isCalculating: true),
                StorageCategory(id: "media", name: "Media & Audio", size: 0, colorName: "pink", icon: "film.fill", isCalculating: true),
                StorageCategory(id: "downloads", name: "Downloads", size: 0, colorName: "orange", icon: "arrow.down.circle.fill", isCalculating: true),
                StorageCategory(id: "docs", name: "Documents & Projects", size: 0, colorName: "green", icon: "doc.fill", isCalculating: true),
                StorageCategory(id: "trash", name: "Trash", size: 0, colorName: "gray", icon: "trash.fill", isCalculating: true)
            ]
        } else {
            for i in self.categories.indices {
                self.categories[i].isCalculating = true
            }
        }

        let categoryPaths: [(id: String, paths: [String])] = [
            ("apps", [
                "/Applications",
                "/Applications/Utilities",
                homeURL.appendingPathComponent("Applications").path
            ]),
            ("downloads", [homeURL.appendingPathComponent("Downloads").path]),
            ("trash", [homeURL.appendingPathComponent(".Trash").path]),
            ("media", [
                homeURL.appendingPathComponent("Movies").path,
                homeURL.appendingPathComponent("Music").path,
                homeURL.appendingPathComponent("Pictures").path
            ]),
            ("dev", [
                homeURL.appendingPathComponent("Library/Caches").path,
                homeURL.appendingPathComponent(".cache").path,
                homeURL.appendingPathComponent("Library/Developer/Xcode").path,
                homeURL.appendingPathComponent(".ollama").path,
                homeURL.appendingPathComponent(".cache/huggingface").path
            ]),
            ("docs", [
                homeURL.appendingPathComponent("Documents").path,
                homeURL.appendingPathComponent("Desktop").path,
                homeURL.appendingPathComponent("C3PO").path
            ])
        ]

        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for entry in categoryPaths {
                    group.addTask { [weak self] in
                        var total: Int64 = 0
                        var perPath: [(String, Int64)] = []
                        // Deduplicate overlapping paths (e.g. ~/.cache and ~/.cache/huggingface)
                        let uniqueRoots = Self.deduplicatedPaths(entry.paths)
                        for p in uniqueRoots {
                            if Task.isCancelled { return }
                            let bytes = Self.measurePathBytes(p)
                            total += bytes
                            perPath.append((p, bytes))
                        }
                        if Task.isCancelled { return }
                        let finalTotal = total
                        let finalPerPath = perPath
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            for (p, bytes) in finalPerPath {
                                self.sizeCache[p] = bytes
                            }
                            if let idx = self.categories.firstIndex(where: { $0.id == entry.id }) {
                                self.categories[idx].size = finalTotal
                                self.categories[idx].isCalculating = false
                            }
                        }
                    }
                }

                group.addTask { [weak self] in
                    let files = Self.findLargeFiles(homeURL: homeURL)
                    if Task.isCancelled { return }
                    await MainActor.run { [weak self] in
                        self?.largeFiles = files
                    }
                }
            }

            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for i in self.categories.indices {
                    self.categories[i].isCalculating = false
                }
                self.isAnalyzing = false
            }
        }
    }

    // MARK: - Installed Apps Sizing

    public func loadApps(forceRefresh: Bool = false) {
        appsTask?.cancel()
        isLoadingApps = true
        let homeURL = self.home
        let snapshotCache = forceRefresh ? [:] : sizeCache

        appsTask = Task.detached(priority: .userInitiated) { [weak self] in
            let appDirs = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/Applications/Utilities"),
                homeURL.appendingPathComponent("Applications")
            ]
            let fm = FileManager.default
            var discovered: [StorageItem] = []
            var seenPaths = Set<String>()

            for dir in appDirs {
                guard let contents = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isPackageKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for item in contents where item.pathExtension.lowercased() == "app" {
                    let stdPath = item.standardizedFileURL.path
                    guard seenPaths.insert(stdPath).inserted else { continue }

                    let vals = try? item.resourceValues(forKeys: [.contentModificationDateKey])
                    let cached = snapshotCache[stdPath]
                    let version = Bundle(url: item)?.infoDictionary?["CFBundleShortVersionString"] as? String
                    let displayParent = Self.abbreviateHome(dir.path, homePath: homeURL.path)

                    discovered.append(StorageItem(
                        url: item,
                        name: item.deletingPathExtension().lastPathComponent,
                        size: cached ?? 0,
                        isDirectory: false,
                        isPackage: true,
                        isMeasuring: cached == nil,
                        modifiedDate: vals?.contentModificationDate,
                        kind: "Application",
                        appVersion: version,
                        parentDisplayPath: displayParent
                    ))
                }
            }

            discovered.sort { lhs, rhs in
                if lhs.size != rhs.size { return lhs.size > rhs.size }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            if Task.isCancelled { return }
            let initialApps = discovered
            await MainActor.run { [weak self] in
                self?.installedApps = initialApps
            }

            let uncached = discovered.filter { $0.isMeasuring }
            if !uncached.isEmpty {
                var measured: [String: Int64] = [:]
                await withTaskGroup(of: (String, Int64).self) { group in
                    var iterator = uncached.makeIterator()
                    let maxConcurrent = 6
                    for _ in 0..<maxConcurrent {
                        if let next = iterator.next() {
                            let path = next.url.path
                            group.addTask { (path, Self.measurePathBytes(path)) }
                        }
                    }

                    var pendingFlush = 0
                    while let (path, bytes) = await group.next() {
                        if Task.isCancelled { return }
                        measured[path] = bytes
                        pendingFlush += 1

                        if let next = iterator.next() {
                            let nextPath = next.url.path
                            group.addTask { (nextPath, Self.measurePathBytes(nextPath)) }
                        }

                        if pendingFlush >= 4 {
                            pendingFlush = 0
                            let batch = measured
                            await MainActor.run { [weak self] in
                                self?.applyAppMeasurements(batch)
                            }
                        }
                    }
                }

                if Task.isCancelled { return }
                let finalBatch = measured
                await MainActor.run { [weak self] in
                    self?.applyAppMeasurements(finalBatch)
                    self?.isLoadingApps = false
                }
            } else {
                await MainActor.run { [weak self] in
                    self?.isLoadingApps = false
                }
            }
        }
    }

    private func applyAppMeasurements(_ measured: [String: Int64]) {
        for (path, bytes) in measured {
            sizeCache[path] = bytes
        }
        var updated = installedApps
        for i in updated.indices {
            if let bytes = measured[updated[i].url.path] {
                updated[i].size = bytes
                updated[i].isMeasuring = false
            }
        }
        updated.sort { lhs, rhs in
            if lhs.isMeasuring != rhs.isMeasuring { return !lhs.isMeasuring && rhs.isMeasuring }
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        installedApps = updated
    }

    // MARK: - Folder Explorer

    public func loadFolder(path: String, forceRefresh: Bool = false) {
        folderMeasureTask?.cancel()

        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        let isTrash = url.lastPathComponent == ".Trash"
        let options: FileManager.DirectoryEnumerationOptions = (showHiddenFiles || isTrash) ? [] : [.skipsHiddenFiles]

        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .totalFileSizeKey,
                .totalFileAllocatedSizeKey,
                .contentModificationDateKey,
                .isDirectoryKey,
                .isPackageKey,
                .isSymbolicLinkKey
            ],
            options: options
        ) else {
            currentFolderPath = path
            currentFolderItems = []
            currentFolderTotalBytes = 0
            isMeasuringFolder = false
            folderMeasureProgress = nil
            return
        }

        if forceRefresh {
            for item in contents {
                sizeCache.removeValue(forKey: item.path)
            }
        }

        let homePath = home.path
        var items: [StorageItem] = []
        var uncachedPaths: [String] = []

        for item in contents {
            let vals = try? item.resourceValues(forKeys: [
                .fileSizeKey,
                .totalFileSizeKey,
                .totalFileAllocatedSizeKey,
                .contentModificationDateKey,
                .isDirectoryKey,
                .isPackageKey,
                .isSymbolicLinkKey
            ])

            let isSymlink = vals?.isSymbolicLink == true
            let isPackage = vals?.isPackage == true
            let isDir = !isSymlink && vals?.isDirectory == true && !isPackage
            let isContainerToMeasure = !isSymlink && (isDir || isPackage)

            let size: Int64
            let measuring: Bool
            if isContainerToMeasure {
                if Self.skippedRootSubpaths.contains(item.path) {
                    size = 0
                    measuring = false
                } else if let cached = sizeCache[item.path] {
                    size = cached
                    measuring = false
                } else {
                    size = 0
                    measuring = true
                    uncachedPaths.append(item.path)
                }
            } else {
                size = Int64(vals?.totalFileAllocatedSize ?? vals?.totalFileSize ?? vals?.fileSize ?? 0)
                measuring = false
            }

            let kind: String
            if isSymlink {
                kind = "Alias / Symlink"
            } else if isPackage {
                kind = item.pathExtension.lowercased() == "app" ? "Application" : "Package"
            } else if isDir {
                kind = Self.skippedRootSubpaths.contains(item.path) ? "System Volume (Skipped)" : "Folder"
            } else {
                let ext = item.pathExtension.uppercased()
                kind = ext.isEmpty ? "File" : ext
            }

            let version = isPackage && item.pathExtension.lowercased() == "app"
                ? (Bundle(url: item)?.infoDictionary?["CFBundleShortVersionString"] as? String)
                : nil

            items.append(StorageItem(
                url: item,
                name: item.lastPathComponent,
                size: size,
                isDirectory: isDir,
                isPackage: isPackage,
                isMeasuring: measuring,
                modifiedDate: vals?.contentModificationDate,
                kind: kind,
                appVersion: version,
                parentDisplayPath: Self.abbreviateHome(path, homePath: homePath)
            ))
        }

        items = Self.sortFolderItems(items)
        currentFolderPath = path
        currentFolderItems = items
        currentFolderTotalBytes = items.reduce(0) { $0 + $1.size }

        guard !uncachedPaths.isEmpty else {
            isMeasuringFolder = false
            folderMeasureProgress = nil
            return
        }

        isMeasuringFolder = true
        let totalToMeasure = uncachedPaths.count
        folderMeasureProgress = "Measuring 0 of \(totalToMeasure)…"

        folderMeasureTask = Task.detached(priority: .userInitiated) { [weak self] in
            var measured: [String: Int64] = [:]
            var completed = 0

            await withTaskGroup(of: (String, Int64).self) { group in
                var iterator = uncachedPaths.makeIterator()
                let maxConcurrent = 6
                for _ in 0..<maxConcurrent {
                    if let next = iterator.next() {
                        group.addTask { (next, Self.measurePathBytes(next)) }
                    }
                }

                var pendingFlush = 0
                while let (itemPath, bytes) = await group.next() {
                    if Task.isCancelled { return }
                    measured[itemPath] = bytes
                    completed += 1
                    pendingFlush += 1

                    if let next = iterator.next() {
                        group.addTask { (next, Self.measurePathBytes(next)) }
                    }

                    if pendingFlush >= 4 || completed == totalToMeasure {
                        pendingFlush = 0
                        let batch = measured
                        let doneCount = completed
                        await MainActor.run { [weak self] in
                            guard let self, self.currentFolderPath == path else { return }
                            self.applyFolderMeasurements(batch)
                            self.folderMeasureProgress = "Measuring \(doneCount) of \(totalToMeasure)…"
                        }
                    }
                }
            }

            if Task.isCancelled { return }
            let finalBatch = measured
            await MainActor.run { [weak self] in
                guard let self, self.currentFolderPath == path else { return }
                self.applyFolderMeasurements(finalBatch)
                self.isMeasuringFolder = false
                self.folderMeasureProgress = nil
            }
        }
    }

    private func applyFolderMeasurements(_ measured: [String: Int64]) {
        for (path, bytes) in measured {
            sizeCache[path] = bytes
        }
        var updated = currentFolderItems
        for i in updated.indices {
            if let bytes = measured[updated[i].url.path] {
                updated[i].size = bytes
                updated[i].isMeasuring = false
            }
        }
        updated = Self.sortFolderItems(updated)
        currentFolderItems = updated
        currentFolderTotalBytes = updated.reduce(0) { $0 + $1.size }
    }

    private nonisolated static func sortFolderItems(_ items: [StorageItem]) -> [StorageItem] {
        items.sorted { lhs, rhs in
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            if lhs.isMeasuring != rhs.isMeasuring { return !lhs.isMeasuring && rhs.isMeasuring }
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Navigation

    public func navigateInto(_ item: StorageItem) {
        guard item.isDirectory else {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
            return
        }
        navigationHistory.append(currentFolderPath)
        forwardHistory.removeAll()
        loadFolder(path: item.url.path)
    }

    public func navigateTo(path: String) {
        guard path != currentFolderPath else { return }
        navigationHistory.append(currentFolderPath)
        forwardHistory.removeAll()
        loadFolder(path: path)
    }

    public func goBack() {
        guard let prev = navigationHistory.popLast() else { return }
        forwardHistory.append(currentFolderPath)
        loadFolder(path: prev)
    }

    public func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        navigationHistory.append(currentFolderPath)
        loadFolder(path: next)
    }

    public func goUp() {
        let parent = (currentFolderPath as NSString).deletingLastPathComponent
        guard parent != currentFolderPath, FileManager.default.fileExists(atPath: parent) else { return }
        navigationHistory.append(currentFolderPath)
        forwardHistory.removeAll()
        loadFolder(path: parent)
    }

    public struct Breadcrumb: Identifiable, Hashable {
        public let title: String
        public let path: String
        public var id: String { path }
    }

    public var breadcrumbs: [Breadcrumb] {
        let std = URL(fileURLWithPath: currentFolderPath).standardizedFileURL.path
        let homeStd = home.standardizedFileURL.path
        if std == homeStd || std.hasPrefix(homeStd + "/") {
            var crumbs: [Breadcrumb] = [Breadcrumb(title: "Home", path: homeStd)]
            let suffix = String(std.dropFirst(homeStd.count))
            var running = homeStd
            for part in suffix.split(separator: "/") {
                running = (running as NSString).appendingPathComponent(String(part))
                crumbs.append(Breadcrumb(title: String(part), path: running))
            }
            return crumbs
        }
        var crumbs: [Breadcrumb] = [Breadcrumb(title: volumeName, path: "/")]
        var running = ""
        for part in std.split(separator: "/") {
            running += "/" + part
            crumbs.append(Breadcrumb(title: String(part), path: running))
        }
        return crumbs
    }

    public func clearSubfolderSearch() {
        searchTask?.cancel()
        isSearchingSubfolders = false
        subfolderSearchResults = []
    }

    public func searchSubfolders(rootPath: String, query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearchingSubfolders = false
            subfolderSearchResults = []
            return
        }

        isSearchingSubfolders = true
        let includeHidden = showHiddenFiles
        let homePath = home.path
        let cachedSizes = sizeCache

        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let matches = Self.runRecursiveSearch(
                rootPath: rootPath,
                query: trimmed,
                includeHidden: includeHidden,
                homePath: homePath,
                cachedSizes: cachedSizes
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.subfolderSearchResults = matches
                self.isSearchingSubfolders = false
            }

            // Measure directory hits without cached sizes in the background so results show real sizes.
            let unmeasured = matches.filter { $0.isMeasuring }
            if !unmeasured.isEmpty {
                var measured: [String: Int64] = [:]
                await withTaskGroup(of: (String, Int64).self) { group in
                    var iterator = unmeasured.prefix(30).makeIterator()
                    for _ in 0..<4 {
                        if let next = iterator.next() {
                            let path = next.url.path
                            group.addTask { (path, Self.measurePathBytes(path)) }
                        }
                    }
                    while let (path, bytes) = await group.next() {
                        if Task.isCancelled { return }
                        measured[path] = bytes
                        if let next = iterator.next() {
                            let nextPath = next.url.path
                            group.addTask { (nextPath, Self.measurePathBytes(nextPath)) }
                        }
                    }
                }
                if Task.isCancelled { return }
                let finalMeasured = measured
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for (p, b) in finalMeasured { self.sizeCache[p] = b }
                    var updated = self.subfolderSearchResults
                    for i in updated.indices {
                        if let b = finalMeasured[updated[i].url.path] {
                            updated[i].size = b
                            updated[i].isMeasuring = false
                        }
                    }
                    self.subfolderSearchResults = updated
                }
            }
        }
    }

    public nonisolated static func runRecursiveSearch(
        rootPath: String,
        query: String,
        includeHidden: Bool,
        homePath: String,
        cachedSizes: [String: Int64]
    ) -> [StorageItem] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath)
        var candidateURLs: [URL] = []
        var seen = Set<String>()

        let skipDirs: Set<String> = [".git", "node_modules", ".build", ".venv", "__pycache__"]
        let options: FileManager.DirectoryEnumerationOptions = includeHidden
            ? [.skipsPackageDescendants]
            : [.skipsHiddenFiles, .skipsPackageDescendants]

        if let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey, .totalFileSizeKey, .fileSizeKey, .contentModificationDateKey
            ],
            options: options,
            errorHandler: { _, _ in true }
        ) {
            var scanned = 0
            for case let url as URL in enumerator {
                if Task.isCancelled { break }
                scanned += 1
                if scanned > 18_000 || candidateURLs.count >= 200 { break }

                let name = url.lastPathComponent
                if skipDirs.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                if name.localizedCaseInsensitiveContains(query) {
                    let std = url.standardizedFileURL.path
                    if seen.insert(std).inserted {
                        candidateURLs.append(url)
                    }
                }
            }
        }

        // Supplement with Spotlight when the directory is huge or contains many hidden/deep items.
        if candidateURLs.count < 80 {
            let escaped = query.replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "'", with: "")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            task.arguments = ["-onlyin", rootPath, "kMDItemFSName == '*\(escaped)*'cdw"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            if (try? task.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                if let output = String(data: data, encoding: .utf8) {
                    for line in output.components(separatedBy: "\n") where !line.isEmpty {
                        if candidateURLs.count >= 250 { break }
                        let url = URL(fileURLWithPath: line)
                        if !includeHidden && url.pathComponents.contains(where: { $0.hasPrefix(".") }) {
                            continue
                        }
                        let std = url.standardizedFileURL.path
                        if seen.insert(std).inserted {
                            candidateURLs.append(url)
                        }
                    }
                }
            }
        }

        var items: [StorageItem] = []
        for url in candidateURLs {
            if Task.isCancelled { break }
            guard let vals = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey, .totalFileSizeKey, .fileSizeKey, .contentModificationDateKey
            ]) else { continue }

            let isSymlink = vals.isSymbolicLink == true
            let isPackage = vals.isPackage == true
            let isDir = !isSymlink && vals.isDirectory == true && !isPackage
            let isContainer = !isSymlink && (isDir || isPackage)

            let size: Int64
            let measuring: Bool
            if isContainer {
                if let cached = cachedSizes[url.path] {
                    size = cached
                    measuring = false
                } else {
                    size = 0
                    measuring = true
                }
            } else {
                size = Int64(vals.totalFileAllocatedSize ?? vals.totalFileSize ?? vals.fileSize ?? 0)
                measuring = false
            }

            let kind = isSymlink ? "Alias / Symlink"
                : isPackage ? (url.pathExtension.lowercased() == "app" ? "Application" : "Package")
                : isDir ? "Folder"
                : (url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased())

            items.append(StorageItem(
                url: url,
                name: url.lastPathComponent,
                size: size,
                isDirectory: isDir,
                isPackage: isPackage,
                isMeasuring: measuring,
                modifiedDate: vals.contentModificationDate,
                kind: kind,
                parentDisplayPath: abbreviateHome(url.deletingLastPathComponent().path, homePath: homePath)
            ))
        }

        return items.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Safe Move to Trash

    public nonisolated func canTrash(_ item: StorageItem) -> Bool {
        let stdPath = item.url.standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let protected: Set<String> = [
            "/", "/System", "/Applications", "/Applications/Utilities",
            "/Library", "/Users", "/Volumes", "/bin", "/sbin", "/usr", "/private",
            homePath,
            "\(homePath)/Library",
            "\(homePath)/Desktop",
            "\(homePath)/Documents",
            "\(homePath)/Downloads",
            "\(homePath)/Pictures",
            "\(homePath)/Movies",
            "\(homePath)/Music",
            "\(homePath)/.Trash"
        ]
        if protected.contains(stdPath) { return false }
        if stdPath.hasPrefix("/System/") { return false }
        return true
    }

    public func moveToTrash(_ item: StorageItem) async -> Bool {
        trashError = nil
        guard canTrash(item) else {
            trashError = "\(item.name) is a protected system folder and cannot be moved to Trash."
            return false
        }

        let targetURL = item.url
        let itemSize = item.size
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.trashItem(at: targetURL, resultingItemURL: nil)
            }.value

            // Invalidate cache for item and all ancestor paths
            let stdPath = targetURL.standardizedFileURL.path
            sizeCache.removeValue(forKey: stdPath)
            var parent = (stdPath as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "/" {
                sizeCache.removeValue(forKey: parent)
                parent = (parent as NSString).deletingLastPathComponent
            }

            currentFolderItems.removeAll { $0.url.path == targetURL.path }
            currentFolderTotalBytes = currentFolderItems.reduce(0) { $0 + $1.size }
            largeFiles.removeAll { $0.url.path == targetURL.path }
            installedApps.removeAll { $0.url.path == targetURL.path }

            if itemSize > 0 {
                refreshVolumeInfo()
            }
            return true
        } catch {
            trashError = "Could not move \(item.name) to Trash: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Fast, Accurate Byte Measurement

    public nonisolated static func measurePathBytes(_ path: String) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return 0 }
        let rootURL = URL(fileURLWithPath: path)

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .totalFileSizeKey,
            .fileSizeKey,
            .linkCountKey,
            .fileResourceIdentifierKey
        ]

        // Single file case
        if let rootVals = try? rootURL.resourceValues(forKeys: keys),
           rootVals.isSymbolicLink != true,
           rootVals.isDirectory != true {
            return Int64(rootVals.totalFileAllocatedSize ?? rootVals.totalFileSize ?? rootVals.fileSize ?? 0)
        }

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var totalBytes: Int64 = 0
        var seenHardLinks = Set<Data>()
        var visitedCount = 0

        for case let fileURL as URL in enumerator {
            visitedCount += 1
            if visitedCount % 512 == 0, Task.isCancelled {
                return totalBytes
            }

            guard let vals = try? fileURL.resourceValues(forKeys: keys) else { continue }

            if vals.isSymbolicLink == true {
                if vals.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if vals.isDirectory == true {
                if skippedRootSubpaths.contains(fileURL.path) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let fileSize = Int64(vals.totalFileAllocatedSize ?? vals.totalFileSize ?? vals.fileSize ?? 0)
            if fileSize <= 0 { continue }

            // Deduplicate hard links >= 1 MB
            if fileSize >= 1_048_576, let linkCount = vals.linkCount, linkCount > 1,
               let fileID = vals.fileResourceIdentifier as? Data {
                if !seenHardLinks.insert(fileID).inserted {
                    continue
                }
            }

            totalBytes += fileSize
        }

        return totalBytes
    }

    private nonisolated static func deduplicatedPaths(_ paths: [String]) -> [String] {
        let existing = paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        var kept: [String] = []
        for p in existing.sorted(by: { $0.count < $1.count }) {
            let isNested = kept.contains { parent in
                p == parent || p.hasPrefix(parent == "/" ? "/" : parent + "/")
            }
            if !isNested {
                kept.append(p)
            }
        }
        return kept
    }

    // MARK: - Large File Discovery

    private nonisolated static func findLargeFiles(homeURL: URL) -> [StorageItem] {
        let minBytes: Int64 = 104_857_600 // 100 MB
        let homePath = homeURL.path
        var candidates: [URL] = []

        // 1. Fast Spotlight query across home
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["kMDItemFSSize > \(minBytes)", "-onlyin", homePath]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        if (try? task.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: "\n") where !line.isEmpty {
                    candidates.append(URL(fileURLWithPath: line))
                }
            }
        }

        // 2. Fallback / supplement in key user folders if Spotlight returned nothing
        if candidates.isEmpty {
            let scanDirs = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures", ".Trash"]
                .map { homeURL.appendingPathComponent($0) }
            let fm = FileManager.default
            for dir in scanDirs {
                guard let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                ) else { continue }
                for case let fileURL as URL in enumerator {
                    if Task.isCancelled { break }
                    guard let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]),
                          vals.isSymbolicLink != true,
                          vals.isDirectory != true,
                          let sz = vals.fileSize, Int64(sz) >= minBytes else { continue }
                    candidates.append(fileURL)
                }
            }
        }

        var items: [StorageItem] = []
        var seen = Set<String>()
        for url in candidates {
            if Task.isCancelled { break }
            let stdPath = url.standardizedFileURL.path
            guard seen.insert(stdPath).inserted else { continue }
            guard let vals = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .totalFileSizeKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .isDirectoryKey,
                .isPackageKey
            ]),
                  vals.isDirectory != true || vals.isPackage == true else { continue }

            let sz = Int64(vals.totalFileAllocatedSize ?? vals.totalFileSize ?? vals.fileSize ?? 0)
            guard sz >= minBytes else { continue }

            let ext = url.pathExtension.lowercased()
            let kind: String
            if ["dmg", "iso", "zip", "tar", "gz", "pkg", "xip"].contains(ext) {
                kind = "Archive / Installer"
            } else if ["mp4", "mkv", "mov", "avi", "m4v"].contains(ext) {
                kind = "Video"
            } else if ["mp3", "m4a", "m4b", "flac", "wav"].contains(ext) {
                kind = "Audio"
            } else if ["gguf", "safetensors", "bin", "mlx", "pt", "onnx"].contains(ext) {
                kind = "AI Model / Weights"
            } else {
                kind = ext.isEmpty ? "File" : ext.uppercased()
            }

            let parent = abbreviateHome(url.deletingLastPathComponent().path, homePath: homePath)
            items.append(StorageItem(
                url: url,
                name: url.lastPathComponent,
                size: sz,
                isDirectory: false,
                isPackage: vals.isPackage == true,
                isMeasuring: false,
                modifiedDate: vals.contentModificationDate,
                kind: kind,
                parentDisplayPath: parent
            ))
        }

        items.sort { $0.size > $1.size }
        return Array(items.prefix(100))
    }

    private nonisolated static func abbreviateHome(_ path: String, homePath: String) -> String {
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }
}
