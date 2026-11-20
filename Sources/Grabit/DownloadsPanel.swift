import SwiftUI

/// Right sidebar: what is downloading, what waits in the queue, what is finished.
struct QueueSidebar: View {
    private var manager = DownloadManager.shared
    @AppStorage("downloadFolder") private var folderPath: String = Defaults.downloadFolder.path

    var body: some View {
        VStack(spacing: 0) {
            if manager.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No downloads").font(.headline).foregroundStyle(.secondary)
                    Text("Downloads and the queue show up here.")
                        .font(.callout).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !manager.active.isEmpty {
                        Section("Downloading") {
                            ForEach(manager.active) { QueueRow(item: $0) }
                        }
                    }
                    if !manager.queued.isEmpty {
                        Section {
                            ForEach(manager.queued) { QueueRow(item: $0) }
                        } header: {
                            HStack {
                                Text("Queue · \(manager.queued.count)")
                                Spacer()
                                Button { manager.queuePaused.toggle() } label: {
                                    Image(systemName: manager.queuePaused ? "play.fill" : "pause.fill")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help(manager.queuePaused ? "Resume the queue" : "Pause the queue (the current download finishes)")
                            }
                        }
                    }
                    if !manager.done.isEmpty {
                        Section {
                            ForEach(manager.done) { QueueRow(item: $0) }
                        } header: {
                            HStack {
                                Text("Finished")
                                Spacer()
                                Button("Clear") { manager.clearFinished() }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .help("Remove finished downloads from the list (the files stay)")
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(FileManager.default.displayName(atPath: folderPath)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: folderPath)) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Open the download folder")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct QueueRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            AsyncImage(url: item.thumbnail) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 52, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 4) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 2)
                    buttons
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                switch item.state {
                case .downloading, .converting:
                    ProgressView(value: item.fraction).controlSize(.small)
                        .tint(item.isPaused ? .secondary : .accentColor)
                case .processing, .waiting:
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                default:
                    EmptyView()
                }
                Text(item.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(statusColor)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if case .finished(let url) = item.state {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { DownloadManager.shared.reveal(url) }
            }
            if item.isDone { Button("Remove from List") { DownloadManager.shared.remove(item) } }
        }
        .onTapGesture(count: 2) {
            if case .finished(let url) = item.state { NSWorkspace.shared.open(url) }
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .failed: .red
        case .finished: .green
        default: .secondary
        }
    }

    /// Small icon buttons: pause/resume and cancel while running, remove while queued,
    /// show in Finder when done, retry after a failure.
    @ViewBuilder private var buttons: some View {
        HStack(spacing: 2) {
            switch item.state {
            case .finished(let url):
                small("magnifyingglass", "Show in Finder") { DownloadManager.shared.reveal(url) }
            case .failed, .cancelled:
                small("arrow.clockwise", "Try again") { DownloadManager.shared.retry(item) }
                small("xmark", "Remove from the list") { DownloadManager.shared.remove(item) }
            case .queued:
                small("xmark", "Remove from the queue") { DownloadManager.shared.cancel(item) }
            default:
                small(item.isPaused ? "play.fill" : "pause.fill", item.isPaused ? "Resume" : "Pause") {
                    DownloadManager.shared.togglePause(item)
                }
                small("xmark", "Cancel") { DownloadManager.shared.cancel(item) }
            }
        }
    }

    private func small(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}
