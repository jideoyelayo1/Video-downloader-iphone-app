import SwiftData
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var labelStore: LabelStore
    @Query private var items: [DownloadItem]
    @Query private var shows: [Show]
    /// Sizes of videos saved before sizes were recorded, which need a directory walk.
    @State private var measuredSizes: [UUID: Int64] = [:]
    @State private var freeSpace: Int64?
    @State private var confirmingDeleteWatched = false
    @State private var showingDiagnostics = false

    var body: some View {
        let stats = LibraryStats(items: items, shows: shows, sizes: measuredSizes)
        NavigationStack {
            List {
                librarySection(stats)
                downloadsSection
                watchedSection(stats)
                labelsSection
                aboutSection
            }
            .navigationTitle("Settings")
            .task(id: storageKey) { await measureStorage() }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsScreen() }
            // An alert, so iOS 26 shows Cancel too (its action sheets have none).
            .alert("Delete \(Self.videosText(stats.watched)) you've watched?", isPresented: $confirmingDeleteWatched) {
                Button("Delete", role: .destructive) { downloads.deleteWatchedVideos() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This frees \(Self.sizeText(stats.watchedBytes)) on this iPhone. Shows stay, with the episodes you haven't watched.")
            }
        }
    }

    private func librarySection(_ stats: LibraryStats) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatTile(label: "Videos", value: stats.videos.formatted(), detail: "\(stats.unwatched.formatted()) unwatched")
                    .accessibilityIdentifier("settings.stat.videos")
                StatTile(label: "Shows", value: shows.count.formatted(),
                         detail: Self.countText(stats.shows.reduce(0) { $0 + $1.count }, "episode"))
                    .accessibilityIdentifier("settings.stat.shows")
                StatTile(label: "Watched", value: stats.watched.formatted(), detail: Self.sizeText(stats.watchedBytes))
                    .accessibilityIdentifier("settings.stat.watched")
                StatTile(label: "Space used", value: Self.sizeText(stats.bytes),
                         detail: freeSpace.map { "\(Self.sizeText($0)) free" } ?? "Measuring…")
                    .accessibilityIdentifier("settings.stat.space")
            }
            .padding(.vertical, 4)
            StorageBar(unwatched: stats.unwatchedBytes, watched: stats.watchedBytes, free: freeSpace)
            NavigationLink { StatisticsScreen(stats: stats) } label: { Label("More Statistics", systemImage: "chart.bar.xaxis") }
                .accessibilityIdentifier("settings.moreStatistics")
        } header: {
            Text("Library")
        }
    }

    private var downloadsSection: some View {
        Section {
            Stepper("At most \(downloads.maxConcurrentDownloads) at once", value: Binding(get: { downloads.maxConcurrentDownloads },
                                                                                        set: { downloads.maxConcurrentDownloads = $0 }), in: 1...4)
                .accessibilityIdentifier("settings.concurrent")
            Toggle("Wi-Fi Only", isOn: Binding(get: { downloads.downloadsOnWiFiOnly }, set: { downloads.downloadsOnWiFiOnly = $0 }))
                .accessibilityIdentifier("settings.wifiOnly")
            Toggle("Notify When Finished", isOn: Binding(get: { downloads.notifiesWhenFinished }, set: { on in
                downloads.notifiesWhenFinished = on
                if on { Task { _ = await NewEpisodeChecker.requestPermission() } }
            }))
            .accessibilityIdentifier("settings.notifyFinished")
        } header: {
            Text("Downloads")
        } footer: {
            Text("More downloads wait as Queued. With Wi-Fi Only, new downloads don't use mobile data.")
        }
    }

    private func watchedSection(_ stats: LibraryStats) -> some View {
        Section {
            Picker("Delete Watched Videos", selection: Binding(get: { downloads.deleteWatchedAfterDays }, set: { downloads.deleteWatchedAfterDays = $0 })) {
                // A number of days chosen some other way stays on the list.
                ForEach(Set(StorageCleanup.dayChoices + [downloads.deleteWatchedAfterDays]).sorted(), id: \.self) { days in
                    Text(StorageCleanup.choiceName(days: days)).tag(days)
                }
            }
            .accessibilityIdentifier("settings.deleteWatched")
            Picker("Delete Finished Episodes", selection: Binding(get: { downloads.finishedEpisodes }, set: { downloads.finishedEpisodes = $0 })) {
                ForEach(FinishedEpisodes.allCases) { Text($0.name).tag($0) }
            }
            .accessibilityIdentifier("settings.finishedEpisodes")
            Button(stats.watched > 0 ? "Delete All Watched Videos (\(stats.watched), \(Self.sizeText(stats.watchedBytes)))…" : "Delete All Watched Videos…",
                   role: .destructive) { confirmingDeleteWatched = true }
                .disabled(stats.watched == 0)
                .accessibilityIdentifier("settings.deleteAllWatched")
        } header: {
            Text("Watched Videos")
        } footer: {
            Text(watchedFooter)
        }
    }

    /// Says what the next automatic cleanup will delete, so a shorter period doesn't surprise.
    private var watchedFooter: String {
        let finished = "An episode of a show is finished when it plays to the end or its credits, or you close it near the end. Ask First asks before the next episode plays."
        let days = downloads.deleteWatchedAfterDays
        guard days > 0 else { return finished }
        let due = StorageCleanup.watched(items, olderThan: days)
        let next = due.isEmpty ? "." : ": \(Self.videosText(due.count)) (\(Self.sizeText(due.reduce(0) { $0 + size(of: $1) }))) next time."
        return "Videos you watched more than \(StorageCleanup.periodText(days: days)) ago are deleted when the app opens\(next) \(finished)"
    }

    private var labelsSection: some View {
        Section {
            Toggle("Label Downloads with Their Site", isOn: Binding(get: { labelStore.labelsDownloadsWithSite },
                                                                    set: { labelStore.labelsDownloadsWithSite = $0 }))
                .accessibilityIdentifier("settings.siteLabels")
        } header: {
            Text("Labels")
        } footer: {
            Text("Each new download gets a label named after the site it came from, such as ***REMOVED***. My Videos → Folders → Manage Labels has the rest.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
            if let expiry = BuildExpiry.date {
                LabeledContent(expiry > Date() ? "Stops Opening" : "Expired",
                               value: expiry.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
            }
            Button { showingDiagnostics = true } label: { Label("Error Log", systemImage: "stethoscope") }
                .accessibilityIdentifier("settings.errorLog")
        } header: {
            Text("About")
        } footer: {
            if BuildExpiry.date != nil {
                Text("A copy installed from Xcode with a free Apple ID stops opening after 7 days. Reinstalling keeps your videos.")
            }
        }
    }

    private func size(of item: DownloadItem) -> Int64 { item.fileSize ?? measuredSizes[item.id] ?? 0 }

    /// Changes when a download completes, is deleted, or learns its size.
    private var storageKey: [String] {
        items.filter { $0.status == .completed }.map { "\($0.id.uuidString)|\($0.fileSize ?? -1)" }
    }

    /// Off the main thread: older videos without a recorded size need a directory walk.
    private func measureStorage() async {
        let unsized = items.filter { $0.status == .completed && $0.fileSize == nil }.compactMap { item in item.localURL.map { (item.id, $0) } }
        let (sizes, free) = await Task.detached(priority: .utility) {
            let sizes = unsized.compactMap { id, url in DownloadStorage.allocatedSize(of: url).map { (id, $0) } }
            return (Dictionary(sizes, uniquingKeysWith: { first, _ in first }), DownloadStorage.availableCapacity())
        }.value
        guard !Task.isCancelled else { return }
        measuredSizes = sizes
        freeSpace = free
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        return (info?["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }

    static func sizeText(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "0 MB"
    }

    static func countText(_ count: Int, _ noun: String) -> String { "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")" }
    static func videosText(_ count: Int) -> String { countText(count, "video") }
}

struct StatisticsScreen: View {
    @EnvironmentObject private var downloads: DownloadManager
    let stats: LibraryStats

    var body: some View {
        List {
            Section("Videos") {
                LabeledContent("Unwatched", value: countAndSize(stats.unwatched, stats.unwatchedBytes))
                LabeledContent("In Progress", value: stats.inProgress.formatted())
                LabeledContent("Watched", value: countAndSize(stats.watched, stats.watchedBytes))
                LabeledContent("Added This Week", value: countAndSize(stats.addedThisWeek, stats.addedThisWeekBytes))
            }
            if !stats.shows.isEmpty {
                let groups = stats.shows + [stats.movies, stats.notInShow].filter { $0.count > 0 }
                Section("Space by Show") {
                    sizeRows(groups, noun: { $0 == stats.movies ? "movie" : $0 == stats.notInShow ? "video" : "episode" })
                }
            }
            if !stats.sites.isEmpty {
                Section("Space by Site") { sizeRows(stats.sites, noun: { _ in "video" }) }
            }
            cleanupSection
        }
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Bars on one scale, so groups compare by length.
    private func sizeRows(_ groups: [LibraryStats.Group], noun: @escaping (LibraryStats.Group) -> String) -> some View {
        let largest = max(groups.map(\.bytes).max() ?? 0, 1)
        return ForEach(groups) { group in
            SizeRow(name: group.name, detail: SettingsScreen.countText(group.count, noun(group)), bytes: group.bytes,
                    fraction: Double(group.bytes) / Double(largest))
        }
    }

    private var cleanupSection: some View {
        Section {
            if let last = downloads.lastCleanup {
                LabeledContent("Last Time", value: last.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Deleted Then", value: countAndSize(last.count, last.bytes, videos: true))
                if let totals = downloads.cleanupTotals {
                    LabeledContent("Since \(totals.date.formatted(date: .abbreviated, time: .omitted))",
                                   value: countAndSize(totals.count, totals.bytes, videos: true))
                }
            } else {
                Text(downloads.deleteWatchedAfterDays > 0 ? "Nothing yet" : "Off").foregroundStyle(.secondary)
            }
        } header: {
            Text("Deleted Automatically")
        } footer: {
            let days = downloads.deleteWatchedAfterDays
            Text(days > 0 ? "Videos you watched more than \(StorageCleanup.periodText(days: days)) ago are deleted when the app opens."
                          : "Settings → Delete Watched Videos can free space by itself.")
        }
    }

    private func countAndSize(_ count: Int, _ bytes: Int64, videos: Bool = false) -> String {
        let number = videos ? SettingsScreen.videosText(count) : count.formatted()
        return count > 0 ? "\(number) · \(SettingsScreen.sizeText(bytes))" : number
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Storage chart colours, checked for colour-blind separation against the dark list background.
private extension Color {
    static let unwatchedVideos = Color(red: 57 / 255, green: 135 / 255, blue: 229 / 255)
    static let watchedVideos = Color(red: 217 / 255, green: 89 / 255, blue: 38 / 255)
    static let freeSpace = Color(.systemGray4)
}

private struct StorageBar: View {
    let unwatched: Int64
    let watched: Int64
    let free: Int64?

    private struct Part: Identifiable {
        let name: String
        let bytes: Int64?
        let color: Color
        var id: String { name }
    }

    private var parts: [Part] {
        [Part(name: "Unwatched", bytes: unwatched, color: .unwatchedVideos),
         Part(name: "Watched", bytes: watched, color: .watchedVideos),
         Part(name: "Free on iPhone", bytes: free, color: .freeSpace)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in bar(width: geometry.size.width) }
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(spacing: 6) {
                ForEach(parts) { part in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 10, height: 10)
                        Text(part.name)
                        Spacer()
                        Text(part.bytes.map(SettingsScreen.sizeText) ?? "Measuring…").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map { "\($0.name) \($0.bytes.map(SettingsScreen.sizeText) ?? "measuring")" }.joined(separator: ", "))
        .accessibilityIdentifier("settings.storageBar")
    }

    /// A part too small to see still shows, at least 3 points wide.
    @ViewBuilder private func bar(width: CGFloat) -> some View {
        let shown = parts.filter { ($0.bytes ?? 0) > 0 }
        let total = shown.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let usable = max(width - CGFloat(max(shown.count - 1, 0)) * 2, 0)
        if shown.isEmpty {
            Rectangle().fill(Color.freeSpace)
        } else {
            HStack(spacing: 2) {
                ForEach(shown) { part in
                    if part.id == shown.last?.id {
                        Rectangle().fill(part.color)
                    } else {
                        Rectangle().fill(part.color).frame(width: max(usable * CGFloat(part.bytes ?? 0) / CGFloat(total), 3))
                    }
                }
            }
        }
    }
}

private struct SizeRow: View {
    let name: String
    let detail: String
    let bytes: Int64
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).lineLimit(1)
                Spacer()
                Text(SettingsScreen.sizeText(bytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.unwatchedVideos.opacity(0.22))
                    RoundedRectangle(cornerRadius: 3).fill(Color.unwatchedVideos)
                        .frame(width: fraction > 0 ? max(geometry.size.width * fraction, 4) : 0)
                }
            }
            .frame(height: 6)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(SettingsScreen.sizeText(bytes)), \(detail)")
    }
}
