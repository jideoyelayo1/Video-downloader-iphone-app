import SwiftUI

/// Debug tool for the site compatibility gate: what each page and player frame loaded.
struct DiagnosticsScreen: View {
    @EnvironmentObject private var diagnostics: DiagnosticsLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(diagnostics.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.event).font(.caption.bold())
                        Text(entry.isMainFrame ? "main" : "frame").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(entry.url).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                    if let note = entry.note { Text(note).font(.caption2) }
                    if let type = entry.contentType { Text(type).font(.caption2).foregroundStyle(.secondary) }
                    if let frame = entry.frameURL { Text("in \(frame)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .overlay { if diagnostics.entries.isEmpty { ContentUnavailableView("Nothing recorded yet", systemImage: "stethoscope") } }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Clear", role: .destructive) { diagnostics.clear() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: diagnostics.exportFile()) { Label("Share log", systemImage: "square.and.arrow.up") }
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
