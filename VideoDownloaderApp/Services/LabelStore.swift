import Foundation
import SwiftData

/// Creates, applies and removes Library labels, including the automatic ones: a label named
/// after each download's site ("***REMOVED***"), and labels the viewer gave sites to watch for.
@MainActor
final class LabelStore: ObservableObject {
    static let colorNames = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "teal"]
    private static let siteLabelsKey = "labelDownloadsWithSite"
    private static let backfillKey = "siteLabelsBackfilledV1"

    private let context: ModelContext
    private let preferences: UserDefaults

    init(context: ModelContext, preferences: UserDefaults = .standard) {
        self.context = context
        self.preferences = preferences
    }

    /// Whether each download is labelled with its site's name. On unless the viewer turns it off.
    var labelsDownloadsWithSite: Bool {
        get { preferences.object(forKey: Self.siteLabelsKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            preferences.set(newValue, forKey: Self.siteLabelsKey)
        }
    }

    var labels: [VideoLabel] {
        ((try? context.fetch(FetchDescriptor<VideoLabel>())) ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func create(name: String, colorName: String? = nil, sites: [String] = []) -> VideoLabel? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = labels.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return existing }
        let label = VideoLabel(name: name, colorName: colorName ?? Self.color(for: name), sites: sites)
        context.insert(label)
        save()
        return label
    }

    /// Removes the label from every video; the videos stay.
    func delete(_ label: VideoLabel) {
        let id = label.id
        for item in videos() where item.labelIDs?.contains(id) == true { item.labelIDs?.removeAll { $0 == id } }
        context.delete(label)
        save()
    }

    func toggle(_ label: VideoLabel, on item: DownloadItem) {
        if item.labelIDs?.contains(label.id) == true { item.labelIDs?.removeAll { $0 == label.id } } else { add(label, to: item) }
        save()
    }

    /// Adds the site label and any rule labels that match where the video came from.
    func applyAutomaticLabels(to item: DownloadItem) {
        guard let host = item.sourcePageURL.host else { return }
        for label in labels where !(label.isSiteLabel ?? false) && (label.sites ?? []).contains(where: { SiteMatch.matches(host: host, site: $0) }) {
            add(label, to: item)
        }
        if labelsDownloadsWithSite { add(siteLabel(for: host), to: item) }
        save()
    }

    /// The label named after a site, created the first time a video comes from it.
    func siteLabel(for host: String) -> VideoLabel {
        let site = SiteNames.normalized(host)
        let siteLabels = labels.filter { $0.isSiteLabel ?? false }
        if let existing = siteLabels.first(where: { ($0.sites ?? []).contains { SiteMatch.matches(host: site, site: $0) } }) { return existing }
        let name = SiteNames.name(for: site)
        // Another domain of a site already labelled, such as ***REMOVED***.tv beside ***REMOVED***.to.
        if let sameName = labels.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            if sameName.isSiteLabel ?? false { sameName.sites = (sameName.sites ?? []) + [site] }
            return sameName
        }
        let label = VideoLabel(name: name, colorName: Self.color(for: name), sites: [site], isSiteLabel: true)
        context.insert(label)
        return label
    }

    /// Videos already in the library that a label's sites match but that don't have the label yet.
    func unlabelledMatches(for label: VideoLabel) -> [DownloadItem] {
        let sites = label.sites ?? []
        guard !sites.isEmpty else { return [] }
        return videos().filter { item in
            item.labelIDs?.contains(label.id) != true && item.sourcePageURL.host.map { host in sites.contains { SiteMatch.matches(host: host, site: $0) } } == true
        }
    }

    func applyToExisting(_ label: VideoLabel) {
        for item in unlabelledMatches(for: label) { add(label, to: item) }
        save()
    }

    /// Videos saved before labels existed get their site labels once.
    func backfillSiteLabelsIfNeeded() {
        guard !preferences.bool(forKey: Self.backfillKey) else { return }
        preferences.set(true, forKey: Self.backfillKey)
        guard labelsDownloadsWithSite else { return }
        for item in videos() {
            if let host = item.sourcePageURL.host { add(siteLabel(for: host), to: item) }
        }
        save()
    }

    /// Sites to offer in a label's rules: the sites the app ships bookmarks for and every site in the library.
    var knownSites: [String] {
        let starters = Bookmark.knownSites.compactMap { $0.1.host.map(SiteNames.normalized) }
        let library = videos().compactMap { $0.sourcePageURL.host.map(SiteNames.normalized) }
        return Array(Set(starters + library)).sorted()
    }

    func save() { try? context.save() }

    private func add(_ label: VideoLabel, to item: DownloadItem) {
        var ids = item.labelIDs ?? []
        guard !ids.contains(label.id) else { return }
        ids.append(label.id)
        item.labelIDs = ids
    }

    private func videos() -> [DownloadItem] { (try? context.fetch(FetchDescriptor<DownloadItem>())) ?? [] }

    /// The same name always gets the same colour.
    static func color(for name: String) -> String {
        colorNames[name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 997 } % colorNames.count]
    }
}
