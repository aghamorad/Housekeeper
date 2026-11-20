// Housekeeping — Space Lens & Visual Storage Explorer
//
// Modern, intuitive disk visualizer and storage manager.
// Provides instant volume overview, category breakdown, full installed-app sizing,
// large-file discovery, fluid folder exploration with real sizes, and safe Trash actions.

import SwiftUI
import AppKit

struct SpaceLensView: View {
    @ObservedObject var analyzer: SpaceAnalyzer = .shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.uiStyle) private var style

    @State private var activeTab: Tab = .categories
    @State private var searchFilter: String = ""
    @State private var largeFileSort: LargeFileSort = .largest
    @State private var appSort: AppSort = .largest
    @State private var itemPendingTrash: StorageItem? = nil

    private enum Tab: String, CaseIterable, Identifiable {
        case categories = "Storage Lens"
        case apps = "Apps"
        case largeFiles = "Big & Old Files"
        case explorer = "Folder Explorer"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .categories: return "circle.grid.cross"
            case .apps: return "app.badge"
            case .largeFiles: return "doc.zipper"
            case .explorer: return "folder.badge.gearshape"
            }
        }
    }

    private enum LargeFileSort: String, CaseIterable, Identifiable {
        case largest = "Size (Largest)"
        case smallest = "Size (Smallest)"
        case newest = "Recently Modified"
        case oldest = "Oldest Modified"
        case name = "Name (A–Z)"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .largest: return "arrow.down.circle"
            case .smallest: return "arrow.up.circle"
            case .newest: return "clock.arrow.circlepath"
            case .oldest: return "clock"
            case .name: return "textformat.size.smaller"
            }
        }
    }

    private enum AppSort: String, CaseIterable, Identifiable {
        case largest = "Size (Largest)"
        case smallest = "Size (Smallest)"
        case newest = "Recently Updated"
        case name = "Name (A–Z)"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .largest: return "arrow.down.circle"
            case .smallest: return "arrow.up.circle"
            case .newest: return "clock.arrow.circlepath"
            case .name: return "textformat.size.smaller"
            }
        }
    }

    private var filteredApps: [StorageItem] {
        let query = searchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = query.isEmpty
            ? analyzer.installedApps
            : analyzer.installedApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return base.sorted { lhs, rhs in
            if lhs.isMeasuring != rhs.isMeasuring { return !lhs.isMeasuring && rhs.isMeasuring }
            switch appSort {
            case .largest:
                if lhs.size != rhs.size { return lhs.size > rhs.size }
            case .smallest:
                if lhs.size != rhs.size { return lhs.size < rhs.size }
            case .newest:
                if let l = lhs.modifiedDate, let r = rhs.modifiedDate, l != r { return l > r }
            case .name:
                break
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var filteredLargeFiles: [StorageItem] {
        let query = searchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = query.isEmpty
            ? analyzer.largeFiles
            : analyzer.largeFiles.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                || $0.parentDisplayPath.localizedCaseInsensitiveContains(query)
            }
        return base.sorted { lhs, rhs in
            switch largeFileSort {
            case .largest:
                if lhs.size != rhs.size { return lhs.size > rhs.size }
            case .smallest:
                if lhs.size != rhs.size { return lhs.size < rhs.size }
            case .newest:
                if let l = lhs.modifiedDate, let r = rhs.modifiedDate, l != r { return l > r }
                if (lhs.modifiedDate != nil) != (rhs.modifiedDate != nil) { return lhs.modifiedDate != nil }
            case .oldest:
                if let l = lhs.modifiedDate, let r = rhs.modifiedDate, l != r { return l < r }
                if (lhs.modifiedDate != nil) != (rhs.modifiedDate != nil) { return lhs.modifiedDate != nil }
            case .name:
                let comp = lhs.name.localizedStandardCompare(rhs.name)
                if comp != .orderedSame { return comp == .orderedAscending }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var filteredFolderItems: [StorageItem] {
        let query = searchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return analyzer.currentFolderItems }
        return analyzer.currentFolderItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                diskCapacityHero

                if let err = analyzer.trashError {
                    errorBanner(err)
                }

                tabPicker

                switch activeTab {
                case .categories:
                    categoriesSection
                case .apps:
                    appsSection
                case .largeFiles:
                    largeFilesSection
                case .explorer:
                    folderExplorerSection
                }
            }
            .padding(32)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { HousekeepingBackdrop(style: style) }
        .onAppear {
            analyzer.refreshVolumeInfo()
            if analyzer.categories.isEmpty {
                analyzer.startCategoryAnalysis()
            }
            if analyzer.installedApps.isEmpty {
                analyzer.loadApps()
            }
        }
        .alert(
            "Move to Trash?",
            isPresented: Binding(
                get: { itemPendingTrash != nil },
                set: { if !$0 { itemPendingTrash = nil } }
            ),
            presenting: itemPendingTrash
        ) { item in
            Button("Move to Trash", role: .destructive) {
                let target = item
                itemPendingTrash = nil
                Task { await analyzer.moveToTrash(target) }
            }
            Button("Cancel", role: .cancel) {
                itemPendingTrash = nil
            }
        } message: { item in
            Text("\"\(item.name)\" (\(item.humanSize)) will be moved to the Trash. You can restore it from Trash later.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(style.accent)
                    Text("Space Lens & Storage")
                        .font(style.isRetro ? style.titleFont : .system(size: 28, weight: .bold))
                }
                Text("See what is using your Mac's storage — apps, folders, and large files — and clear space safely.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ThemeButton(
                title: "Analyze Again",
                systemImage: "arrow.clockwise",
                isEnabled: !analyzer.isAnalyzing,
                help: "Recalculate volume capacity, apps, categories, and large files"
            ) {
                analyzer.refreshVolumeInfo()
                analyzer.startCategoryAnalysis()
                analyzer.loadApps(forceRefresh: true)
                analyzer.loadFolder(path: analyzer.currentFolderPath, forceRefresh: true)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 13))
            Spacer()
            Button("Dismiss") {
                analyzer.trashError = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(style.accent)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Disk Hero Bar

    private var diskCapacityHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(analyzer.volumeName)
                        .font(.system(size: 16, weight: .bold))
                    Text("\(humanSize(analyzer.usedDiskBytes)) used of \(humanSize(analyzer.totalDiskBytes))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(humanSize(analyzer.freeDiskBytes)) Free")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 16)

                    let usedWidth = geo.size.width * CGFloat(analyzer.usedFraction)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [style.accent, style.accent.opacity(0.8)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, usedWidth), height: 16)
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: analyzer.usedFraction)
                }
            }
            .frame(height: 16)

            HStack {
                Label("Used (\(Int(analyzer.usedFraction * 100))%)", systemImage: "circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(style.accent)
                Spacer()
                Label("Available (\(Int((1 - analyzer.usedFraction) * 100))%)", systemImage: "circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(20)
        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(style.border, lineWidth: 1))
    }

    // MARK: - Tab Switcher

    private var tabPicker: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases) { tab in
                let isSelected = activeTab == tab
                Button {
                    activeTab = tab
                    searchFilter = ""
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13))
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isSelected ? style.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(isSelected ? style.accent : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Search Field

    private func searchBar(placeholder: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $searchFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchFilter.isEmpty {
                Button {
                    searchFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 260)
        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.border, lineWidth: 1))
    }

    // MARK: - Categories Section

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Storage by Category")
                .font(.system(size: 16, weight: .semibold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(analyzer.categories) { cat in
                    categoryCard(cat)
                }
            }

            // Quick Top Space Hogs Preview
            HStack(alignment: .top, spacing: 16) {
                topPreviewCard(
                    title: "Largest Apps",
                    subtitle: "See all \(analyzer.installedApps.count) apps",
                    items: Array(analyzer.installedApps.prefix(5)),
                    isLoading: analyzer.isLoadingApps && analyzer.installedApps.isEmpty
                ) {
                    activeTab = .apps
                }

                topPreviewCard(
                    title: "Largest Files (> 100 MB)",
                    subtitle: "See all \(analyzer.largeFiles.count) files",
                    items: Array(analyzer.largeFiles.prefix(5)),
                    isLoading: analyzer.isAnalyzing && analyzer.largeFiles.isEmpty
                ) {
                    activeTab = .largeFiles
                }
            }
        }
    }

    private func topPreviewCard(
        title: String,
        subtitle: String,
        items: [StorageItem],
        isLoading: Bool,
        onSeeAll: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button(subtitle) {
                    onSeeAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.accent)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else if items.isEmpty {
                Text("Nothing large found.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Image(nsImage: iconForItem(item))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(item.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            if item.isMeasuring {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text(item.humanSize)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.border, lineWidth: 1))
    }

    private func categoryCard(_ cat: StorageCategory) -> some View {
        let share = analyzer.usedDiskBytes > 0 ? min(1.0, Double(cat.size) / Double(analyzer.usedDiskBytes)) : 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(catColor(cat.colorName).opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: cat.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(catColor(cat.colorName))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(cat.name)
                        .font(.system(size: 14, weight: .bold))
                    if cat.isCalculating && cat.size == 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Measuring…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(cat.humanSize)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(8)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 4)
                    Capsule()
                        .fill(catColor(cat.colorName).opacity(0.75))
                        .frame(width: max(4, geo.size.width * CGFloat(share)), height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture {
            quickJumpToCategory(cat.id)
        }
        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.border, lineWidth: 1))
    }

    private func catColor(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "orange": return .orange
        case "green": return .green
        default: return .gray
        }
    }

    private func quickJumpToCategory(_ id: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        searchFilter = ""
        if id == "apps" {
            activeTab = .apps
            return
        }
        activeTab = .explorer
        switch id {
        case "downloads":
            analyzer.navigateTo(path: home.appendingPathComponent("Downloads").path)
        case "dev":
            analyzer.navigateTo(path: home.appendingPathComponent("Library/Caches").path)
        case "media":
            analyzer.navigateTo(path: home.appendingPathComponent("Pictures").path)
        case "trash":
            analyzer.navigateTo(path: home.appendingPathComponent(".Trash").path)
        case "docs":
            analyzer.navigateTo(path: home.appendingPathComponent("Documents").path)
        default:
            analyzer.navigateTo(path: home.path)
        }
    }

    // MARK: - Apps Section

    private var appsSection: some View {
        let apps = filteredApps
        let totalAppsBytes = apps.reduce(Int64(0)) { $0 + $1.size }
        let maxAppBytes = max(1, apps.map(\.size).max() ?? 1)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installed Applications")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(apps.count) apps · \(humanSize(totalAppsBytes)) total")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if analyzer.isLoadingApps {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Measuring apps…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                searchBar(placeholder: "Filter apps…")

                Menu {
                    Picker("Sort apps", selection: $appSort) {
                        ForEach(AppSort.allCases) { opt in
                            Label(opt.rawValue, systemImage: opt.systemImage).tag(opt)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: appSort.systemImage)
                            .foregroundStyle(style.accent)
                        Text(appSort.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(style.border, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)

                ThemeButton(title: "Uninstaller", systemImage: "xmark.app", help: "Open full App Uninstaller to remove apps with their leftover support files") {
                    appState.showUninstaller = true
                }
            }

            if apps.isEmpty && !analyzer.isLoadingApps {
                emptyStateCard(icon: "app.badge", text: searchFilter.isEmpty ? "No applications found." : "No apps match \"\(searchFilter)\".")
            } else {
                VStack(spacing: 1) {
                    ForEach(apps) { item in
                        storageItemRow(item, maxReferenceBytes: maxAppBytes, showParentPath: false)
                    }
                }
                .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.border, lineWidth: 1))
            }
        }
    }

    // MARK: - Large Files Section

    private var largeFilesSection: some View {
        let files = filteredLargeFiles
        let maxFileBytes = max(1, files.map(\.size).max() ?? 1)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Large & Forgotten Files")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Top files over 100 MB in your user folders (\(files.count) shown).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                searchBar(placeholder: "Filter files or folder…")

                Menu {
                    Picker("Organize by", selection: $largeFileSort) {
                        ForEach(LargeFileSort.allCases) { opt in
                            Label(opt.rawValue, systemImage: opt.systemImage)
                                .tag(opt)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: largeFileSort.systemImage)
                            .foregroundStyle(style.accent)
                        Text(largeFileSort.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(style.border, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
            }

            if files.isEmpty {
                emptyStateCard(
                    icon: "checkmark.seal",
                    iconColor: .green,
                    text: searchFilter.isEmpty ? "No files over 100 MB detected." : "No large files match \"\(searchFilter)\"."
                )
            } else {
                VStack(spacing: 1) {
                    ForEach(files) { item in
                        storageItemRow(item, maxReferenceBytes: maxFileBytes, showParentPath: true)
                    }
                }
                .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.border, lineWidth: 1))
            }
        }
    }

    // MARK: - Folder Explorer Section

    private var folderExplorerSection: some View {
        let items = filteredFolderItems
        let maxFolderBytes = max(1, items.map(\.size).max() ?? 1)

        return VStack(alignment: .leading, spacing: 14) {
            // Navigation Breadcrumbs & Controls
            HStack(spacing: 8) {
                ThemeButton(
                    title: "Back",
                    systemImage: "chevron.left",
                    isEnabled: !analyzer.navigationHistory.isEmpty
                ) {
                    analyzer.goBack()
                }

                ThemeButton(
                    title: "Forward",
                    systemImage: "chevron.right",
                    isEnabled: !analyzer.forwardHistory.isEmpty
                ) {
                    analyzer.goForward()
                }

                ThemeButton(
                    title: "Up",
                    systemImage: "arrow.up",
                    isEnabled: analyzer.currentFolderPath != "/"
                ) {
                    analyzer.goUp()
                }

                Text(analyzer.currentFolderPath)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)

                Spacer()

                if let prog = analyzer.folderMeasureProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(prog)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                ThemeButton(
                    title: "Refresh",
                    systemImage: "arrow.clockwise",
                    help: "Recalculate sizes in this folder"
                ) {
                    analyzer.loadFolder(path: analyzer.currentFolderPath, forceRefresh: true)
                }

                ThemeButton(
                    title: "Finder",
                    systemImage: "macwindow"
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: analyzer.currentFolderPath)])
                }
            }

            // Quick Location Chips + Search + Hidden Toggle
            HStack(spacing: 8) {
                let home = FileManager.default.homeDirectoryForCurrentUser
                locationChip("Home", path: home.path)
                locationChip("Applications", path: "/Applications")
                locationChip("Downloads", path: home.appendingPathComponent("Downloads").path)
                locationChip("Caches", path: home.appendingPathComponent("Library/Caches").path)
                locationChip("Documents", path: home.appendingPathComponent("Documents").path)
                locationChip("C3PO", path: home.appendingPathComponent("C3PO").path)
                locationChip("Trash", path: home.appendingPathComponent(".Trash").path)

                Spacer()

                Toggle("Hidden", isOn: Binding(
                    get: { analyzer.showHiddenFiles },
                    set: { newVal in
                        analyzer.showHiddenFiles = newVal
                        analyzer.loadFolder(path: analyzer.currentFolderPath)
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

                searchBar(placeholder: "Filter folder…")
            }

            if analyzer.currentFolderTotalBytes > 0 {
                Text("Measured total in this folder: \(humanSize(analyzer.currentFolderTotalBytes)) (\(items.count) items)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Items List
            if items.isEmpty {
                emptyStateCard(
                    icon: "folder",
                    text: searchFilter.isEmpty ? "Folder is empty." : "No items match \"\(searchFilter)\"."
                )
            } else {
                VStack(spacing: 1) {
                    ForEach(items) { item in
                        storageItemRow(item, maxReferenceBytes: maxFolderBytes, showParentPath: false)
                    }
                }
                .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.border, lineWidth: 1))
            }
        }
    }

    private func locationChip(_ title: String, path: String) -> some View {
        Button {
            analyzer.navigateTo(path: path)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(analyzer.currentFolderPath == path ? style.accent.opacity(0.12) : Color.secondary.opacity(0.1), in: Capsule())
                .foregroundStyle(analyzer.currentFolderPath == path ? style.accent : .primary)
        }
        .buttonStyle(.plain)
    }

    private func emptyStateCard(icon: String, iconColor: Color = .secondary, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(iconColor)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.border, lineWidth: 1))
    }

    // MARK: - Item Row

    private func storageItemRow(_ item: StorageItem, maxReferenceBytes: Int64, showParentPath: Bool) -> some View {
        let share = maxReferenceBytes > 0 && item.size > 0 ? min(1.0, Double(item.size) / Double(maxReferenceBytes)) : 0

        return HStack(spacing: 12) {
            Image(nsImage: iconForItem(item))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let ver = item.appVersion, !ver.isEmpty {
                        Text("v\(ver)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(item.kind)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if showParentPath, !item.parentDisplayPath.isEmpty {
                        Text("· \(item.parentDisplayPath)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let mod = item.modifiedDate {
                        Text("· \(mod.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Proportional visual bar
            if item.size > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 5)
                        Capsule()
                            .fill(style.accent.opacity(0.7))
                            .frame(width: max(3, geo.size.width * CGFloat(share)), height: 5)
                    }
                }
                .frame(width: 80, height: 5)
            }

            // Size or Measuring indicator
            if item.isMeasuring && item.size == 0 {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Measuring…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 85, alignment: .trailing)
            } else {
                Text(item.humanSize)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(item.size > 0 ? .primary : .tertiary)
                    .frame(minWidth: 85, alignment: .trailing)
            }

            HStack(spacing: 4) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                if analyzer.canTrash(item) {
                    Button {
                        itemPendingTrash = item
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.8))
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .help("Move to Trash")
                }

                if item.isDirectory {
                    Button {
                        analyzer.navigateInto(item)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(style.accent)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .help("Open folder")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.isDirectory {
                analyzer.navigateInto(item)
            }
        }
        .contextMenu {
            Button {
                HousekeeperTopic.ask(.diskItem(name: item.name, path: item.url.path, size: item.size, isDirectory: item.isDirectory))
            } label: {
                Label("Ask the Housekeeper About This \(item.isDirectory ? "Folder" : "Item")", systemImage: "sparkles")
            }

            Divider()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            if item.isDirectory {
                Button {
                    analyzer.navigateInto(item)
                } label: {
                    Label("Open Folder in Space Lens", systemImage: "arrow.right.circle")
                }
            }

            if item.isPackage && item.url.pathExtension.lowercased() == "app" {
                Button {
                    appState.showUninstaller = true
                } label: {
                    Label("Uninstall with Leftovers…", systemImage: "xmark.app")
                }
            }

            if analyzer.canTrash(item) {
                Divider()
                Button(role: .destructive) {
                    itemPendingTrash = item
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
    }

    private func iconForItem(_ item: StorageItem) -> NSImage {
        NSWorkspace.shared.icon(forFile: item.url.path)
    }

    private func humanSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
