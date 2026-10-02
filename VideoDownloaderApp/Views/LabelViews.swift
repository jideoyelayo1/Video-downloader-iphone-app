import SwiftData
import SwiftUI

extension VideoLabel {
    var color: Color { Self.color(named: colorName) }

    static func color(named name: String) -> Color {
        switch name {
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "teal": .teal
        default: .blue
        }
    }
}

/// A video's labels as small capsules: the first three, then "+N".
struct LabelChips: View {
    let labels: [VideoLabel]

    var body: some View {
        if !labels.isEmpty {
            HStack(spacing: 4) {
                ForEach(labels.prefix(3)) { label in
                    Text(label.name)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(label.color)
                        .background(label.color.opacity(0.18), in: Capsule())
                }
                if labels.count > 3 {
                    Text("+\(labels.count - 3)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Labels: " + labels.map(\.name).joined(separator: ", "))
        }
    }
}

struct ManageLabelsSheet: View {
    @EnvironmentObject private var store: LabelStore
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \VideoLabel.name) private var labels: [VideoLabel]
    @Query private var items: [DownloadItem]
    @State private var showingNewLabel = false
    @State private var newLabelName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Label downloads with their site", isOn: Binding(get: { store.labelsDownloadsWithSite },
                                                                           set: { store.labelsDownloadsWithSite = $0 }))
                } footer: {
                    Text("Each new download gets a label named after the site it came from, such as ***REMOVED***.")
                }
                Section {
                    ForEach(labels) { label in
                        NavigationLink { LabelEditor(label: label) } label: {
                            HStack(spacing: 10) {
                                Circle().fill(label.color).frame(width: 12, height: 12)
                                Text(label.name)
                                if !(label.sites ?? []).isEmpty {
                                    Image(systemName: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
                                        .accessibilityLabel("Added automatically")
                                }
                                Spacer()
                                Text("\(count(for: label))").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .onDelete { offsets in offsets.map { labels[$0] }.forEach(store.delete) }
                    Button { newLabelName = ""; showingNewLabel = true } label: { Label("New Label", systemImage: "plus") }
                } header: {
                    Text("Labels")
                } footer: {
                    Text("Deleting a label keeps its videos.")
                }
            }
            .navigationTitle("Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .alert("New Label", isPresented: $showingNewLabel) {
                TextField("Label name", text: $newLabelName)
                Button("Create") { store.create(name: newLabelName) }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    private func count(for label: VideoLabel) -> Int { items.filter { $0.labelIDs?.contains(label.id) == true }.count }
}

/// Name, colour and the sites whose downloads get the label automatically.
private struct LabelEditor: View {
    @Bindable var label: VideoLabel
    @EnvironmentObject private var store: LabelStore
    @Environment(\.dismiss) private var dismiss
    @State private var newSite = ""
    @State private var existingMatches = 0

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $label.name)
                    .onSubmit { store.save() }
            }
            Section("Colour") {
                HStack {
                    ForEach(LabelStore.colorNames, id: \.self) { name in
                        Button { label.colorName = name; store.save() } label: {
                            Circle().fill(VideoLabel.color(named: name)).frame(width: 28, height: 28)
                                .overlay { if label.colorName == name { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name.capitalized)
                        .accessibilityAddTraits(label.colorName == name ? .isSelected : [])
                        if name != LabelStore.colorNames.last { Spacer(minLength: 0) }
                    }
                }
            }
            Section {
                ForEach(sites, id: \.self) { site in
                    Toggle(site, isOn: Binding(get: { (label.sites ?? []).contains(site) }, set: { setSite(site, $0) }))
                }
                HStack {
                    TextField("Another site, e.g. ***REMOVED***.to", text: $newSite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(addSite)
                    Button("Add", action: addSite).disabled(SiteNames.site(fromInput: newSite) == nil)
                }
            } header: {
                Text("Add automatically to downloads from")
            } footer: {
                Text(label.isSiteLabel ?? false ? "Created for the site it's named after." : "New downloads from these sites get this label.")
            }
            if existingMatches > 0 {
                Section {
                    Button("Add to \(existingMatches) saved \(existingMatches == 1 ? "video" : "videos") from these sites") {
                        store.applyToExisting(label)
                        refreshMatches()
                    }
                }
            }
            Section {
                Button("Delete Label", role: .destructive) {
                    // Leave the editor first: it reads the label while it animates away.
                    let label = label
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        store.delete(label)
                    }
                }
            }
        }
        .navigationTitle(label.name.isEmpty ? "Label" : label.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshMatches)
        .onDisappear { store.save() }
    }

    private var sites: [String] { Array(Set(store.knownSites + (label.sites ?? []))).sorted() }

    private func setSite(_ site: String, _ on: Bool) {
        var current = label.sites ?? []
        if on { if !current.contains(site) { current.append(site) } } else { current.removeAll { $0 == site } }
        label.sites = current
        store.save()
        refreshMatches()
    }

    private func addSite() {
        guard let site = SiteNames.site(fromInput: newSite) else { return }
        setSite(site, true)
        newSite = ""
    }

    private func refreshMatches() { existingMatches = store.unlabelledMatches(for: label).count }
}
