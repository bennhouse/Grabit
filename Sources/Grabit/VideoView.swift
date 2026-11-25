import QuartzCore
import AVKit
import SwiftUI

struct VideoView: View {
    @Environment(AppModel.self) private var model
    let info: VideoInfo

    @State private var controller: PlayerController
    @State private var audioOnly = false
    @State private var videoLabel: Int?
    @State private var audioID: String?
    @State private var audioTouched = false
    @State private var confirmation: String?
    @State private var confirmationIsError = false
    /// The direct download of this video, shown as a progress ring in place of the Download button.
    @State private var ringID: UUID?
    @State private var ringDone = false
    @AppStorage("container") private var container: VideoContainer = .mp4Compatible
    @AppStorage("audioOutput") private var audioOutput: AudioOutput = .aac
    @AppStorage("downloadFolder") private var folderPath: String = Defaults.downloadFolder.path

    init(info: VideoInfo) {
        self.info = info
        _controller = State(initialValue: PlayerController(info: info))
    }

    private var selectedVideo: VideoOption? { info.videoOptions.first { $0.label == videoLabel } ?? info.videoOptions.first }
    private var selectedAudio: AudioOption? { info.audioOptions.first { $0.id == audioID } }
    private var isAudio: Bool { audioOnly || info.videoOptions.isEmpty }

    /// What Download and Add to Queue save. Read only in their actions: the page's body uses
    /// `choice` (no segment), so moving In or Out doesn't rebuild the whole page.
    private var request: DownloadRequest {
        var r = choice
        r.segment = controller.segment
        return r
    }

    private var choice: DownloadRequest {
        DownloadRequest(info: info, audioOnly: isAudio, video: selectedVideo, audio: selectedAudio,
                        container: container, audioOutput: audioOutput,
                        folder: URL(fileURLWithPath: folderPath))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                ClipEditor(info: info, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    header
                    Divider()
                    ScrollView {
                        options
                    }
                    .scrollIndicators(.never)
                }
                .frame(width: 330)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 14)
            // Status bar, as in the other apps: what part of the video will be saved.
            StatusBar { SegmentCaption(controller: controller) }
        }
        .onAppear {
            controller.load()
            setDefaults()
            // Back on a video that is still downloading: its ring again.
            ringID = DownloadManager.shared.items.last { !$0.fromQueue && $0.isActive && $0.request.info.id == info.id }?.id
            if let m = Snapshots.env["GRABIT_MARKS"], Snapshots.dir != nil {
                let v = m.split(separator: ",").compactMap { Double($0) }
                if v.count == 2 { controller.seek(v[0]); controller.markIn(); controller.seek(v[1]); controller.markOut() }
                if v.count == 1 { controller.seek(v[0]); controller.markIn() }
            }
            if let s = Snapshots.autoDownload {
                Task { try? await Task.sleep(for: .seconds(s)); download() }
            }
        }
        .onChange(of: ringItem?.state) { _, state in ringStateChanged(state) }
        .onDisappear { controller.stop() }
        .onChange(of: container) { if !audioTouched { pickDefaultAudio() } }
        .onChange(of: audioOnly) { if !audioTouched { pickDefaultAudio() } }
    }

    private func setDefaults() {
        audioOnly = info.videoOptions.isEmpty || (model.platform.prefersAudio && info.platform != .youtube)
        videoLabel = info.videoOptions.first?.label
        pickDefaultAudio()
    }

    private func pickDefaultAudio() {
        audioID = Defaults.audio(info, preferAAC: !audioOnly && container == .mp4Compatible)?.id
    }

    // MARK: Header: title and the two actions

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(info.title)
                    .font(.headline)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text([info.channel, Fmt.duration(info.duration), Fmt.views(info.views)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let confirmation {
                    Label(confirmation, systemImage: confirmationIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(confirmationIsError ? .red : .green)
                        .transition(.opacity)
                } else if let url = URL(string: info.webpageURL) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            PlatformIcon(platform: info.platform, size: 11)
                            Text("Open on \(info.platform == .other ? (url.host() ?? "the web") : info.platform.name)")
                        }
                        .font(.caption)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button(action: enqueue) {
                    Image(systemName: "text.badge.plus").frame(width: 22, height: 18)
                }
                .buttonStyle(.bordered)
                .help("Add to Queue — \(DownloadManager.describe(choice))")
                .accessibilityLabel("Add to Queue")
                // While this video downloads, a progress ring takes the button's place (App Store
                // style); clicking it stops the download. The button stays in the layout, hidden,
                // so nothing moves.
                Button(action: download) {
                    Image(systemName: "arrow.down").fontWeight(.semibold).frame(width: 22, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(ringID == nil ? .defaultAction : nil)
                .help("Download Now — \(DownloadManager.describe(choice)) (↩)")
                .accessibilityLabel("Download Now")
                .opacity(ringID == nil ? 1 : 0)
                .scaleEffect(ringID == nil ? 1 : 0.6)
                .allowsHitTesting(ringID == nil)
                .overlay {
                    if let item = ringItem {
                        DownloadRing(item: item, done: ringDone) { DownloadManager.shared.cancel(item) }
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(.smooth(duration: 0.3), value: ringID)
                .animation(.smooth(duration: 0.3), value: ringDone)
            }
            .controlSize(.large)
            .disabled(isAudio ? selectedAudio == nil : selectedVideo == nil)
        }
    }

    // MARK: Options

    @ViewBuilder private var options: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("", selection: $audioOnly) {
                Label("Video", systemImage: "film").tag(false)
                Label("Audio Only", systemImage: "music.note").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(info.videoOptions.isEmpty)

            if !isAudio {
                section("Resolution") {
                    ForEach(info.videoOptions) { v in
                        OptionRow(selected: v.label == selectedVideo?.label, title: v.title, badge: v.badge,
                                  detail: videoDetail(v), bytes: videoSize(v), size: sizing) { videoLabel = v.label }
                    }
                }
            }

            section("Audio Quality") {
                if !isAudio && !info.hasSeparateAudio {
                    Text(info.audioOptions.isEmpty ? "This video has no sound." : "The sound comes with the video at the best quality the site offers.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if info.audioOptions.isEmpty {
                    Text("No audio found.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(info.audioOptions) { a in
                        OptionRow(selected: a.id == audioID, title: a.title, badge: nil, detail: a.detail,
                                  bytes: isAudio ? info.estimatedSize(a.format) : nil, size: sizing) {
                            audioID = a.id
                            audioTouched = true
                        }
                    }
                }
            }

            section("Format") {
                if isAudio {
                    audioFormatPicker
                } else {
                    Picker("", selection: $container) {
                        ForEach(VideoContainer.allCases) { Text(containerTitle($0)).tag($0) }
                    }
                    .labelsHidden()
                    if let note = formatNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SegmentNote(controller: controller)
                }
            }

            section("Save To") {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(FileManager.default.displayName(atPath: folderPath))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…", action: chooseFolder)
                }
            }
        }
    }

    @ViewBuilder private var audioFormatPicker: some View {
        let a = selectedAudio
        Picker("", selection: $audioOutput) {
            Text("AAC (.m4a)").tag(AudioOutput.aac)
            Text("MP3 · \(mp3Bitrate(for: a?.kbps ?? 128)) kbps").tag(AudioOutput.mp3)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text(audioOutput == .aac
             ? (a?.isAAC == true ? "Saved exactly as the site streams it, no conversion." : "Converted to AAC \(aacBitrate(for: a?.kbps ?? 128)) kbps.")
             : "Converted to MP3 with ffmpeg. Converting can’t add quality that isn’t in the source.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func videoDetail(_ v: VideoOption) -> String {
        var parts: [String] = []
        if v.fps > 30 { parts.append("\(v.fps) fps") }
        let f = container == .mp4Compatible ? (v.compatible ?? v.best) : v.best
        parts.append(codecName(f.vcodec))
        return parts.joined(separator: " · ")
    }

    private var sizing: SizeEstimate { SizeEstimate(controller: controller, duration: info.duration) }

    /// Estimated size of the whole video at this resolution (the row scales it to the segment).
    private func videoSize(_ v: VideoOption) -> Double? {
        let f = container == .mp4Compatible ? (v.compatible ?? v.best) : v.best
        guard let vs = info.estimatedSize(f) else { return nil }
        let a = (info.hasSeparateAudio ? selectedAudio.flatMap { info.estimatedSize($0.format) } : nil) ?? 0
        return vs + a
    }

    /// "MP4 · H.264", "MP4 · VP9 (original)": the codec the file will have at the chosen resolution.
    private func containerTitle(_ c: VideoContainer) -> String {
        let box = c == .mkv ? "MKV" : "MP4"
        guard let v = selectedVideo else { return c.title }
        switch c {
        case .mp4Compatible:
            // Above 1080p YouTube has no H.264: Grabit converts to HEVC.
            return v.compatible == nil && !FormatAnalysis.playsEverywhere(video: v.best.vcodec) ? "\(box) · HEVC (converted)" : "\(box) · H.264"
        case .mp4, .mkv:
            return "\(box) · \(codecName(v.best.vcodec)) (original)"
        }
    }

    private func codecName(_ v: String?) -> String {
        let c = (v ?? "").lowercased()
        if c.hasPrefix("avc") || c.hasPrefix("h264") { return "H.264" }
        if c.hasPrefix("hvc") || c.hasPrefix("hev") { return "HEVC" }
        if c.hasPrefix("av01") { return "AV1" }
        if c.hasPrefix("vp9") || c.hasPrefix("vp09") { return "VP9" }
        if c.hasPrefix("vp8") { return "VP8" }
        return c.isEmpty ? "Video" : c.uppercased()
    }

    private var formatNote: String? {
        let plan = DownloadPlan(choice)
        let codec = codecName(plan.videoFormat?.vcodec)
        var note: String
        switch container {
        case .mp4Compatible:
            if plan.convertVideo {
                note = "At this resolution \(info.platform.name) only offers \(codec). After the download Grabit converts it to HEVC with your Mac’s hardware encoder, so it opens in QuickTime, Photos and Final Cut."
            } else if plan.convertAudio {
                note = "The \(selectedAudio?.codec ?? "audio") track is converted to AAC so the file plays in QuickTime."
            } else {
                note = "H.264 and AAC: opens everywhere."
            }
        case .mp4, .mkv:
            if FormatAnalysis.playsEverywhere(video: plan.videoFormat?.vcodec) { note = "\(codec): plays everywhere." }
            else { note = "\(codec) as streamed. Plays in IINA, VLC and browsers; QuickTime plays AV1 only on M3 Macs and later, and not VP9." }
        }
        return note
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: folderPath)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }

    private var ringItem: DownloadItem? {
        guard let ringID else { return nil }
        return DownloadManager.shared.items.first { $0.id == ringID }
    }

    /// Downloads right away; the queue doesn't open, the progress shows on the button.
    private func download() {
        ringDone = false
        ringID = DownloadManager.shared.start(request).id
    }

    private func ringStateChanged(_ state: DownloadItem.State?) {
        guard let id = ringID else { return }
        switch state {
        case .finished:
            // A tick for a moment, then the Download button again.
            ringDone = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                guard ringID == id else { return }
                ringID = nil
                try? await Task.sleep(for: .seconds(0.3))
                ringDone = false
            }
            confirm("Downloaded")
        case .failed(let message):
            ringID = nil
            confirm("Download failed: \(message)", error: true, seconds: 5)
        case .cancelled, nil:
            ringID = nil
        default:
            break
        }
    }

    /// Adds to the queue (without starting it) and opens the queue.
    private func enqueue() {
        DownloadManager.shared.enqueue(request)
        if !model.showQueue { model.toggleQueue() }
        confirm("Added to the queue")
    }

    private func confirm(_ text: String, error: Bool = false, seconds: Double = 2) {
        confirmationIsError = error
        withAnimation { confirmation = text }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard confirmation == text else { return }
            withAnimation { confirmation = nil }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// The playhead time. A view of its own: it changes 30 times a second while playing, and only it
/// is redrawn then, not the whole editor.
struct TimeLabel: View {
    let controller: PlayerController
    let full: Bool
    let withDuration: Bool

    var body: some View {
        let stamp = { (t: Double) in full ? Fmt.timecode(t) : Fmt.clock(t) }
        ZStack(alignment: .leading) {
            // The widest the text can get, so its width never changes (no new layout of the window).
            Text(withDuration ? stamp(controller.duration) + " / " + stamp(controller.duration) : stamp(controller.duration)).hidden()
            Text(withDuration ? stamp(controller.time) + " / " + stamp(controller.duration) : stamp(controller.time))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

/// I and O stacked, each with its time, and the button that clears them. A view of its own: only
/// it is redrawn when a mark changes.
struct MarkColumn: View {
    let controller: PlayerController
    let full: Bool
    let focus: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
                GridRow {
                    markButton("I", "Mark In (I)") { controller.markIn() }
                    markTime(controller.inPoint)
                }
                GridRow {
                    markButton("O", "Mark Out (O)") { controller.markOut() }
                    markTime(controller.outPoint)
                }
            }
            Button { focus(); controller.clearMarks() } label: {
                Image(systemName: "xmark").frame(width: 22, height: 18)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("x", modifiers: .option)
            .disabled(controller.inPoint == nil && controller.outPoint == nil)
            .help("Clear In and Out (Esc)")
            .accessibilityLabel("Clear In and Out")
            .padding(.leading, 4)
        }
    }

    private func stamp(_ t: Double) -> String { full ? Fmt.timecode(t) : Fmt.clock(t) }

    /// A mark's time, or a dash when it isn't set. The longest time of this video sets the width,
    /// so the column doesn't move as marks are set.
    private func markTime(_ t: Double?) -> some View {
        ZStack(alignment: .leading) {
            Text(stamp(controller.duration)).hidden()
            Text(t.map { stamp($0) } ?? "–")
                .foregroundStyle(t == nil ? .tertiary : .secondary)
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }

    private func markButton(_ letter: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: { focus(); action() }) {
            Text(letter)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .frame(width: 20, height: 18)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Scales a whole-video size to the segment, read where it is shown (so a mark change only
/// redraws the size labels).
@MainActor struct SizeEstimate {
    let controller: PlayerController
    let duration: Double?
    func text(_ bytes: Double?) -> String? {
        guard var b = bytes else { return nil }
        if let s = controller.segment, let d = duration, d > 0 { b *= s.duration / d }
        return Fmt.bytes(b).map { "~" + $0 }
    }
}

/// The line under the format note while a segment is set.
struct SegmentNote: View {
    let controller: PlayerController
    var body: some View {
        if controller.segment != nil {
            Text("The segment is cut to the exact frame, which re-encodes it with the hardware encoder.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Speaker button (mutes) and a small slider for the preview's volume.
struct VolumeControl: View {
    @Bindable var controller: PlayerController
    let compact: Bool
    @State private var beforeMute = 0.5

    private var symbol: String {
        switch controller.volume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if controller.volume > 0 { beforeMute = controller.volume; controller.volume = 0 }
                else { controller.volume = beforeMute > 0 ? beforeMute : 0.5 }
            } label: {
                Image(systemName: symbol).frame(width: 22, height: 18, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .help(controller.volume > 0 ? "Mute" : "Unmute")
            .accessibilityLabel("Volume")
            if !compact {
                Slider(value: $controller.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 80)
                    .accessibilityLabel("Volume")
            }
        }
    }
}

// MARK: - Status bar

/// The bar at the bottom of the window, as in the other apps of the suite: a line on top, 37 pt
/// high (the same as the bar under the queue, so their lines meet).
struct StatusBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) { content }
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: StatusBarMetrics.height - 1)
        }
    }
}

enum StatusBarMetrics { static let height: CGFloat = 37 }

/// What will be saved: the whole video or the segment between In and Out. Shorter in a narrow
/// window, never wrapped.
struct SegmentCaption: View {
    let controller: PlayerController

    var body: some View {
        Group {
            if let s = controller.segment {
                let length = String(format: "%.2f s", s.duration)
                ViewThatFits(in: .horizontal) {
                    segmentLabel("Segment \(Fmt.timecode(s.start)) – \(Fmt.timecode(s.end)) · \(length). Only this part is saved.")
                    segmentLabel("Segment · \(length) · only this part is saved")
                    segmentLabel("Segment · \(length)")
                }
                .foregroundStyle(Color.accentColor)
            } else if controller.available {
                ViewThatFits(in: .horizontal) {
                    Text("Whole video. Press I and O on the timeline to save only a part.")
                    Text("Whole video. I and O mark a part.")
                    Text("Whole video")
                }
                .foregroundStyle(.secondary)
            } else {
                Text("No preview stream for this video: the whole video is downloaded.")
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segmentLabel(_ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: "scissors") }
    }

}

// MARK: - Progress ring

/// App Store style progress: a thin track, the share done in the accent colour and a stop square in
/// the middle; a spinning arc while there is no percentage yet; a tick when done.
struct DownloadRing: View {
    let item: DownloadItem
    let done: Bool
    let stop: () -> Void
    @State private var spin = false

    var body: some View {
        Button(action: stop) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.14), lineWidth: 2.5)
                if done {
                    Circle().stroke(Color.accentColor, lineWidth: 2.5)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    if let f = item.ringFraction {
                        Circle().trim(from: 0, to: max(0.02, f))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.smooth(duration: 0.4), value: f)
                    } else {
                        Circle().trim(from: 0, to: 0.28)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(spin ? 270 : -90))
                            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                            .onAppear { spin = true }
                    }
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 8, height: 8)
                }
            }
            .frame(width: 24, height: 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .tip(done ? "Downloaded" : "Stop the download")
        .accessibilityLabel(done ? "Downloaded" : "Stop the download")
        .accessibilityValue(item.ringFraction.map { "\(Int($0 * 100))%" } ?? "Starting")
    }
}

// MARK: - Preview with In and Out

/// The preview, a scrub bar and the editor keys: Space plays, ← → step one frame (⇧ one second),
/// I and O mark In and Out, ↑ ↓ go to them, ⌥X clears them, J K L back / pause / play.
struct ClipEditor: View {
    let info: VideoInfo
    @Bindable var controller: PlayerController
    @FocusState private var focused: Bool
    @State private var transportWidth: Double = 1000

    var body: some View {
        VStack(spacing: 10) {
            picture
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if controller.available {
                Timeline(controller: controller)
                transport
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down, action: handle)
        .onReceive(NotificationCenter.default.publisher(for: .grabitTestMark)) { n in
            if n.object as? String == "toggle" {
                if controller.inPoint == nil { controller.markIn() } else { controller.clearMarks() }
                return
            }
            let t0 = CACurrentMediaTime()
            // Seek somewhere, then mark at once (before the seek can finish).
            let target = Double(Int.random(in: 30...600))
            controller.seek(target)
            if n.object as? String == "i" { controller.markIn() } else { controller.markOut() }
            let marked = (n.object as? String == "i" ? controller.inPoint : controller.outPoint) ?? -1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                FrameLog.mark("target \(target) marked \(marked) playhead after 0.4 s \(String(format: "%.2f", controller.time))")
            }
            DispatchQueue.main.async { FrameLog.mark(String(format: "mark handled, next turn after %.1f ms", (CACurrentMediaTime() - t0) * 1000)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .grabitTestPlay)) { _ in
            PlayerTrace.log("test: play pressed")
            controller.togglePlay()
        }
        .simultaneousGesture(TapGesture().onEnded { focused = true })
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            focused = true
        }
    }

    private var picture: some View {
        ZStack {
            Color.black
            if controller.available && !info.videoOptions.isEmpty {
                PlayerLayerView(player: controller.player)
            }
            // Cover art for music, and the thumbnail until the first frame is ready.
            // (`hasMoved`, not the time itself: this view would be rebuilt 30 times a second.)
            if info.videoOptions.isEmpty || !controller.isReady || !controller.hasMoved {
                // In an overlay of an empty view: a filled image reports a size larger than the frame
                // (a 4:3 thumbnail in a 16:9 frame), which pushed the whole page out of the window.
                Color.clear.overlay {
                    AsyncImage(url: info.thumbnail) { phase in
                        if let img = phase.image {
                            // Fill: a vertical video's 16:9 thumbnail has side bars that get cropped away.
                            img.resizable().scaledToFill()
                        } else if phase.error == nil {
                            ProgressView()
                        }
                    }
                }
                .clipped()
                .allowsHitTesting(false)
            }
            if controller.available && !controller.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(.black.opacity(0.5), in: Circle())
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(info.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            Text(verbatim: (info.isVertical ? "Vertical · " : "") + "\(info.width)×\(info.height)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                .padding(8)
                .opacity(controller.isPlaying ? 0 : 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(focused && controller.available ? 0.6 : 0), lineWidth: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true; controller.togglePlay() }
        .help(controller.available ? "Space: play · ←/→: frame · I/O: mark In/Out · ↑/↓: go to In/Out · Esc: clear" : "")
    }

    /// Frame back, play, frame forward and the time on the left; In and Out stacked, each with its
    /// time, and the clear button on the right. In a narrow window the times get shorter instead of
    /// wrapping.
    private var transport: some View {
        // The detail level comes from the width (only recomputed when the window is resized): a
        // ViewThatFits measured all three rows again at every mark change and every play/pause.
        transportRow(detail(for: transportWidth))
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: Double.self) { $0.size.width } action: { transportWidth = $0 }
    }

    private enum Detail { case full, short, minimal }

    /// The widest row that fits: three buttons, the time, I/O with their times and the clear button.
    private func detail(for width: Double) -> Detail {
        let char = 6.6   // caption digits
        let fixed = 3 * 22 + 3 * 4 + 6 + 10 + 20 + 6 + 4 + 4 + 22 + 10 + 22 + 80   // … + volume
        func need(_ d: Detail) -> Double {
            let mark = Double(stamp(controller.duration, d).count)
            let time = d == .minimal ? mark : 2 * mark + 3
            return Double(fixed) + (time + mark) * char
        }
        if width >= need(.full) { return .full }
        if width >= need(.short) { return .short }
        return .minimal
    }

    private func stamp(_ t: Double, _ d: Detail) -> String {
        d == .full ? Fmt.timecode(t) : Fmt.clock(t)
    }

    private func transportRow(_ d: Detail) -> some View {
        HStack(alignment: .center, spacing: 4) {
            icon("backward.frame.fill", "Previous frame (←), one second back (⇧←)") { controller.step(-1) }
            icon(controller.isPlaying ? "pause.fill" : "play.fill", "Play / Pause (Space)") { controller.togglePlay() }
            icon("forward.frame.fill", "Next frame (→), one second forward (⇧→)") { controller.step(1) }
            TimeLabel(controller: controller, full: d == .full, withDuration: d != .minimal)
                .padding(.leading, 6)
            VolumeControl(controller: controller, compact: d == .minimal)
                .padding(.leading, 10)
            Spacer(minLength: 10)
            MarkColumn(controller: controller, full: d == .full) { focused = true }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard controller.available else { return .ignored }
        let shift = press.modifiers.contains(.shift)
        guard !press.modifiers.contains(.command) else { return .ignored }
        switch press.key {
        case .space: controller.togglePlay(); return .handled
        case .leftArrow: shift ? controller.jump(-1) : controller.step(-1); return .handled
        case .rightArrow: shift ? controller.jump(1) : controller.step(1); return .handled
        case .upArrow: controller.goToIn(); return .handled
        case .downArrow: controller.goToOut(); return .handled
        case .escape:
            guard controller.inPoint != nil || controller.outPoint != nil else { return .ignored }
            controller.clearMarks(); return .handled
        default: break
        }
        guard !press.modifiers.contains(.option) else { return .ignored }
        switch press.characters.lowercased() {
        case "i": controller.markIn(); return .handled
        case "o": controller.markOut(); return .handled
        case "k": controller.pause(); return .handled
        case "l": controller.play(); return .handled
        case "j": controller.jump(-5); return .handled
        default: return .ignored
        }
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: { focused = true; action() }) {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

}

struct OptionRow: View {
    let selected: Bool
    let title: String
    let badge: String?
    let detail: String
    let bytes: Double?
    let size: SizeEstimate
    let action: () -> Void
    private var trailing: String? { size.text(bytes) }
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(title).font(.callout.weight(.semibold).monospacedDigit())
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Color.accentColor)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.12) : (hover ? Color.primary.opacity(0.05) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel([title, badge, detail, trailing].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
