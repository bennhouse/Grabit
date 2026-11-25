import SwiftUI

/// Right sidebar: what is downloading, what waits in the queue, what is finished.
struct QueueSidebar: View {
    private var manager = DownloadManager.shared
    /// Section titles start this far from the left edge (and Clear ends this far from the right one).
    private let headerInset: CGFloat = 14
    /// Rows start this far from either edge.
    private let rowInset: CGFloat = 16
    private let sectionGap: CGFloat = 13
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
                // A plain stack rather than a List: the List's table re-measured every row the
                // first time the queue opened, which cost a few frames of the animation. It looks
                // like the sidebar list it replaces (same insets, section titles that don't fold).
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !manager.active.isEmpty {
                            header("Downloading")
                            rows(manager.active)
                        }
                        if !manager.queued.isEmpty {
                            header("Queue · \(manager.queued.count)")
                                .padding(.top, manager.active.isEmpty ? 0 : sectionGap)
                            rows(manager.queued)
                        }
                        if !manager.done.isEmpty {
                            header("Finished") {
                                Button("Clear") { manager.clearFinished() }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .font(.system(size: 11, weight: .bold))
                                    .tip("Remove finished downloads from the list (the files stay)")
                            }
                            .padding(.top, manager.active.isEmpty && manager.queued.isEmpty ? 0 : sectionGap)
                            rows(manager.done)
                        }
                    }
                    .padding(.vertical, 10)
                }
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
            // As high as the page's status bar, so the two lines meet.
            .frame(height: StatusBarMetrics.height - 1)
        }
    }
}

extension QueueSidebar {
    /// A section title: small, bold and grey like a sidebar's.
    private func header(_ title: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack {
            Text(title).foregroundStyle(.tertiary)
            Spacer()
            trailing().foregroundStyle(.secondary)
        }
        .font(.system(size: 11, weight: .bold))
        .frame(height: 19)
        .padding(.horizontal, headerInset)
    }

    private func rows(_ items: [DownloadItem]) -> some View {
        ForEach(items) { item in
            QueueRow(item: item)
                .padding(.horizontal, rowInset)
                .padding(.vertical, 4)
        }
    }
}

/// Stop, Pause and Play for the queue, in the top bar over the queue (only while it is open).
struct QueueControls: View {
    @Environment(AppModel.self) private var model
    private var manager = DownloadManager.shared

    var body: some View {
        // Spaced like separate toolbar buttons (as the queue button next to them). Always in the
        // toolbar (adding them when the queue opens cost a few frames of its animation), but no
        // wider than nothing while the queue is closed, so a narrow window keeps the queue button.
        HStack(spacing: 1) {
            button("stop.fill", "Stop", "Stop the queue: the current download starts again from the beginning with Play",
                   enabled: manager.canStop) { manager.stop() }
            button("pause.fill", "Pause", "Pause the queue and its current download", enabled: manager.canPause) { manager.pause() }
            button("play.fill", "Play", manager.queueState == .paused ? "Resume the queue" : "Start the queue: one download at a time",
                   enabled: manager.canPlay) { manager.play() }
        }
        .fixedSize()
        .frame(width: model.showQueue ? nil : 0, alignment: .trailing)
        .clipped()
        .opacity(model.showQueue ? 1 : 0)
        .allowsHitTesting(model.showQueue)
        .accessibilityHidden(!model.showQueue)
    }

    private func button(_ symbol: String, _ title: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 22)
        }
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(title)
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
        .tip(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Tooltips

extension View {
    /// A tooltip for a view that can disappear under the mouse (a row's buttons, the progress ring,
    /// Clear). SwiftUI's own `.help` crashed then (its tooltip tracking read the removed view); an
    /// AppKit tooltip goes away with its view.
    func tip(_ text: String) -> some View {
        overlay(TooltipView(text: text).allowsHitTesting(false))
    }
}

private struct TooltipView: NSViewRepresentable {
    let text: String

    final class View: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the button
    }

    func makeNSView(context: Context) -> View {
        let v = View()
        v.toolTip = text
        return v
    }

    func updateNSView(_ v: View, context: Context) {
        if v.toolTip != text { v.toolTip = text }
    }
}
