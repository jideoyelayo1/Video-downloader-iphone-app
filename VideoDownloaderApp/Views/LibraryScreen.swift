import AVKit
import SwiftData
import SwiftUI
import UIKit

struct LibraryScreen: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Query(filter: #Predicate<DownloadItem> { $0.statusRaw == "completed" }, sort: \DownloadItem.completedAt, order: .reverse)
    private var completed: [DownloadItem]
    @Query(sort: \DownloadFolder.title) private var folders: [DownloadFolder]
    @Environment(\.modelContext) private var modelContext
    @State private var playing: DownloadItem?
    @State private var pendingPlayback: DownloadItem?
    @State private var playbackStartPosition = 0.0
    @State private var renaming: DownloadItem?
    @State private var newTitle = ""
    @State private var searchText = ""
    @State private var selectedFolderID: UUID?
    @State private var showingNewFolder = false
    @State private var showingManageFolders = false
    @State private var newFolderTitle = ""

    private var displayed: [DownloadItem] {
        completed.filter { item in
            !item.isStreamFragment &&
            (selectedFolderID == nil || item.folderID == selectedFolderID) &&
            (searchText.isEmpty || item.title.localizedStandardContains(searchText))
        }
    }

    private var playableCompletedCount: Int { completed.filter { !$0.isStreamFragment }.count }

    var body: some View {
        NavigationStack {
            List {
                if displayed.isEmpty {
                    ContentUnavailableView(playableCompletedCount == 0 ? "Your library is empty" : "No matching videos", systemImage: "play.rectangle",
                                           description: Text(playableCompletedCount == 0 ? "Completed downloads play here, even offline." : "Try another search or folder."))
                }
                ForEach(displayed) { item in
                    Button { open(item) } label: { LibraryRow(item: item) }
                        .accessibilityIdentifier("library.item")
                        .contextMenu { actions(for: item) }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { downloads.delete(item) }
                            Button("Rename") { beginRename(item) }.tint(.blue)
                        }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search videos")
            .onChange(of: folders.map(\.id)) { _, ids in
                if let selectedFolderID, !ids.contains(selectedFolderID) { self.selectedFolderID = nil }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("All Videos") { selectedFolderID = nil }
                        ForEach(folders) { folder in
                            Button(folder.title) { selectedFolderID = folder.id }
                        }
                        Divider()
                        Button("New Folder", systemImage: "folder.badge.plus") { newFolderTitle = ""; showingNewFolder = true }
                        Button("Manage Folders", systemImage: "folder") { showingManageFolders = true }
                    } label: { Label("Folders", systemImage: "folder") }
                        .accessibilityIdentifier("library.folders")
                }
            }
            .sheet(item: $playing) { item in PlayerScreen(item: item, startPosition: playbackStartPosition) }
            .sheet(isPresented: $showingManageFolders) { ManageFoldersSheet() }
            .confirmationDialog("Play video", isPresented: Binding(get: { pendingPlayback != nil }, set: { if !$0 { pendingPlayback = nil } })) {
                Button("Resume") { if let item = pendingPlayback { start(item, at: item.playbackPosition ?? 0) }; pendingPlayback = nil }
                Button("Start from Beginning") { if let item = pendingPlayback { start(item, at: 0) }; pendingPlayback = nil }
            } message: { Text("Continue where you stopped or play from the beginning?") }
            .alert("New Folder", isPresented: $showingNewFolder) {
                TextField("Folder name", text: $newFolderTitle)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Rename video", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Save") { if let renaming { downloads.rename(renaming, to: newTitle) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    @ViewBuilder private func actions(for item: DownloadItem) -> some View {
        Button { beginRename(item) } label: { Label("Rename", systemImage: "pencil") }
        Menu {
            Button("No Folder") { item.folderID = nil; try? modelContext.save() }
            ForEach(folders) { folder in
                Button(folder.title) { item.folderID = folder.id; try? modelContext.save() }
            }
        } label: { Label("Move to Folder", systemImage: "folder") }
        if item.kind != .hls, let url = item.localURL {
            ShareLink(item: url, preview: SharePreview(item.title)) { Label("Export", systemImage: "square.and.arrow.up") }
        }
        Button(role: .destructive) { downloads.delete(item) } label: { Label("Delete", systemImage: "trash") }
    }

    private func beginRename(_ item: DownloadItem) {
        newTitle = item.title
        renaming = item
    }

    private func open(_ item: DownloadItem) {
        if (item.playbackPosition ?? 0) > 10 { pendingPlayback = item }
        else { start(item, at: 0) }
    }

    private func start(_ item: DownloadItem, at position: Double) {
        playbackStartPosition = position
        if position == 0 { item.playbackPosition = 0; try? modelContext.save() }
        playing = item
    }

    private func createFolder() {
        let title = newFolderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let folder = DownloadFolder(title: title)
        modelContext.insert(folder)
        try? modelContext.save()
        selectedFolderID = folder.id
    }
}

private struct ManageFoldersSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DownloadFolder.title) private var folders: [DownloadFolder]
    @Query private var items: [DownloadItem]

    var body: some View {
        NavigationStack {
            List {
                ForEach(folders) { folder in Label(folder.title, systemImage: "folder") }
                    .onDelete { offsets in
                        for folder in offsets.map({ folders[$0] }) {
                            for item in items where item.folderID == folder.id { item.folderID = nil }
                            modelContext.delete(folder)
                        }
                        try? modelContext.save()
                    }
            }
            .navigationTitle("Folders")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct LibraryRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnailView(item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body).foregroundStyle(.primary).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(fileExists ? Color.secondary : Color.red)
            }
        }
    }

    private var fileExists: Bool { item.localURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    private var detail: String {
        guard fileExists else { return "File missing — delete and download again" }
        var parts: [String] = []
        if let size = item.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let date = item.completedAt { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
}

private struct VideoThumbnailView: View {
    let item: DownloadItem
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").font(.title2).foregroundStyle(.tint)
            }
        }
        .frame(width: 72, height: 48)
        .clipped()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: item.localFileName) {
            let cached = DownloadStorage.thumbnailURL(for: item.id)
            if let data = try? Data(contentsOf: cached), let cachedImage = UIImage(data: data) {
                image = cachedImage
                return
            }
            guard let mediaURL = item.localURL else { return }
            let data = await Task.detached(priority: .utility) { () -> Data? in
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 160)
                let time = CMTime(seconds: 1, preferredTimescale: 600)
                guard let frame = (try? generator.copyCGImage(at: time, actualTime: nil)) ??
                    (try? generator.copyCGImage(at: .zero, actualTime: nil)) else { return nil }
                let data = UIImage(cgImage: frame).jpegData(compressionQuality: 0.8)
                try? data?.write(to: cached, options: .atomic)
                return data
            }.value
            if let data { image = UIImage(data: data) }
        }
    }
}

struct PlayerScreen: View {
    let item: DownloadItem
    let startPosition: Double
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var player: AVPlayer?
    @State private var playbackError: String?
    @State private var playbackEnded = false
    @State private var showingFullScreen = false
    @State private var isInPictureInPicture = false

    var body: some View {
        NavigationStack {
            Group {
                if let playbackError {
                    ContentUnavailableView("Unable to play video", systemImage: "exclamationmark.triangle",
                                           description: Text(playbackError))
                } else if let url = item.localURL, FileManager.default.fileExists(atPath: url.path) {
                    if let player {
                        NativePlayer(player: player, isInPictureInPicture: $isInPictureInPicture)
                            .ignoresSafeArea(edges: .bottom)
                            .accessibilityIdentifier("player.video")
                    } else {
                        ProgressView("Loading video")
                    }
                } else {
                    ContentUnavailableView("File unavailable", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // HLS packages can only be played inside the app.
                    if item.kind != .hls, let url = item.localURL {
                        ShareLink(item: url, preview: SharePreview(item.title)) { Label("Export", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("player.export")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingFullScreen = true } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .disabled(player == nil || playbackError != nil)
                        .accessibilityIdentifier("player.fullScreen")
                }
            }
            .fullScreenCover(isPresented: $showingFullScreen) {
                if let player {
                    NativePlayer(player: player, isInPictureInPicture: $isInPictureInPicture,
                                 dismiss: { showingFullScreen = false })
                        .ignoresSafeArea()
                }
            }
            .task {
                guard let url = item.localURL else { return }
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                let asset = AVURLAsset(url: url)
                guard (try? await asset.load(.isPlayable)) == true else {
                    playbackError = "The saved file is not a playable iPhone video. Replay it in Browse and choose another source."
                    return
                }
                let audioMissing = item.kind == .hls ? await HLSMediaSelections.isOfflineAudioMissing(in: asset) : false
                if audioMissing {
                    playbackError = "This saved stream has no offline audio track. Replay it in Browse and download again."
                    return
                }
                // VideoPlayer otherwise inherits the app's ambient audio category,
                // which can be silent when the iPhone's Ring/Silent switch is off.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try? AVAudioSession.sharedInstance().setActive(true)
                let playerItem = AVPlayerItem(asset: asset)
                if let preferred = try? await asset.load(.preferredMediaSelection),
                   let (group, option) = await HLSMediaSelections.audibleOption(for: asset, preferred: preferred) {
                    playerItem.select(option, in: group)
                }
                player = AVPlayer(playerItem: playerItem)
                player?.isMuted = false
                player?.volume = 1
                if startPosition > 0 {
                    player?.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600)) { _ in player?.play() }
                } else { player?.play() }
            }
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in savePosition() }
            .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
                if let current = player?.currentItem, notification.object as? AVPlayerItem === current {
                    playbackEnded = true
                    item.playbackPosition = 0
                    try? modelContext.save()
                }
            }
            .onDisappear {
                guard !showingFullScreen && !isInPictureInPicture else { return }
                savePosition()
                player?.pause()
                player = nil
            }
        }
    }

    private func savePosition() {
        guard !playbackEnded else { return }
        guard let seconds = player?.currentTime().seconds, seconds.isFinite, seconds > 0 else { return }
        item.playbackPosition = seconds
        try? modelContext.save()
    }
}

private struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    @Binding var isInPictureInPicture: Bool
    var dismiss: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(isInPictureInPicture: $isInPictureInPicture) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.view.backgroundColor = .black
        if let dismiss {
            let close = UIButton(type: .system)
            close.setTitle("Done", for: .normal)
            close.accessibilityIdentifier = "player.fullScreenDone"
            close.addAction(UIAction { _ in dismiss() }, for: .touchUpInside)
            close.translatesAutoresizingMaskIntoConstraints = false
            controller.contentOverlayView?.addSubview(close)
            if let overlay = controller.contentOverlayView {
                NSLayoutConstraint.activate([
                    close.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 8),
                    close.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -16)
                ])
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private var isInPictureInPicture: Binding<Bool>

        init(isInPictureInPicture: Binding<Bool>) {
            self.isInPictureInPicture = isInPictureInPicture
        }

        func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
            false
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            isInPictureInPicture.wrappedValue = true
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  failedToStartPictureInPictureWithError error: Error) {
            isInPictureInPicture.wrappedValue = false
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            isInPictureInPicture.wrappedValue = false
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }
    }
}
