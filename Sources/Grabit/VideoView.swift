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

    private var request: DownloadRequest {
        DownloadRequest(info: info, audioOnly: isAudio, video: selectedVideo, audio: selectedAudio,
                        container: container, audioOutput: audioOutput,
                        folder: URL(fileURLWithPath: folderPath), segment: controller.segment)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            ClipEditor(info: info, controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                ScrollView {
                    options.padding(.trailing, 8)
                }
                .scrollIndicators(.automatic)
            }
            .frame(width: 330)
        }
        .padding(20)
        .onAppear(perform: setDefaults)
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
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
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
                .help("Add to Queue — \(DownloadManager.describe(request))")
                .accessibilityLabel("Add to Queue")
                Button(action: download) {
                    Image(systemName: "arrow.down").fontWeight(.semibold).frame(width: 22, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Download Now — \(DownloadManager.describe(request)) (↩)")
                .accessibilityLabel("Download Now")
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
                                  detail: videoDetail(v), trailing: videoSize(v)) { videoLabel = v.label }
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
                                  trailing: isAudio ? sized(info.estimatedSize(a.format)) : nil) {
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
                        ForEach(VideoContainer.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    if let note = formatNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

    /// Estimated size of the saved file; a segment is the matching share of the whole.
    private func sized(_ bytes: Double?) -> String? {
        guard var b = bytes else { return nil }
        if let s = controller.segment, let d = info.duration, d > 0 { b *= s.duration / d }
        return Fmt.bytes(b).map { "~" + $0 }
    }

    private func videoSize(_ v: VideoOption) -> String? {
        let f = container == .mp4Compatible ? (v.compatible ?? v.best) : v.best
        guard let vs = info.estimatedSize(f) else { return nil }
        let a = (info.hasSeparateAudio ? selectedAudio.flatMap { info.estimatedSize($0.format) } : nil) ?? 0
        return sized(vs + a)
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
        let plan = DownloadPlan(request)
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
        if controller.segment != nil {
            note += " The segment is cut to the exact frame, which re-encodes it with the hardware encoder."
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

    private func download() {
        DownloadManager.shared.start(request)
        confirm("Downloading")
    }

    private func enqueue() {
        DownloadManager.shared.enqueue(request)
        confirm("Added to the queue")
    }

    private func confirm(_ text: String) {
        model.showQueue = true
        withAnimation { confirmation = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
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

// MARK: - Preview with In and Out

/// The preview, a scrub bar and the editor keys: Space plays, ← → step one frame (⇧ one second),
/// I and O mark In and Out, ↑ ↓ go to them, ⌥X clears them, J K L back / pause / play.
struct ClipEditor: View {
    let info: VideoInfo
    @Bindable var controller: PlayerController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            picture
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if controller.available {
                Timeline(controller: controller)
                transport
            }
            segmentLine
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down, action: handle)
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
            if info.videoOptions.isEmpty || !controller.isReady || (controller.time == 0 && !controller.isPlaying) {
                AsyncImage(url: info.thumbnail) { phase in
                    if let img = phase.image {
                        // Fill: a vertical video's 16:9 thumbnail has side bars that get cropped away.
                        img.resizable().scaledToFill()
                    } else if phase.error == nil {
                        ProgressView()
                    }
                }
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
        .help(controller.available ? "Space: play · ←/→: frame · I/O: mark In/Out" : "")
    }

    private var transport: some View {
        HStack(spacing: 4) {
            icon("arrow.up.to.line", "Go to In (↑)") { controller.goToIn() }
            icon("backward.frame.fill", "Previous frame (←), one second back (⇧←)") { controller.step(-1) }
            icon(controller.isPlaying ? "pause.fill" : "play.fill", "Play / Pause (Space)") { controller.togglePlay() }
            icon("forward.frame.fill", "Next frame (→), one second forward (⇧→)") { controller.step(1) }
            icon("arrow.down.to.line", "Go to Out (↓)") { controller.goToOut() }
            Text(Fmt.timecode(controller.time) + " / " + Fmt.timecode(controller.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            Spacer(minLength: 6)
            markButton("I", "Mark In (I)") { controller.markIn() }
            markButton("O", "Mark Out (O)") { controller.markOut() }
            icon("xmark", "Clear In and Out (⌥X)") { controller.clearMarks() }
                .keyboardShortcut("x", modifiers: .option)
                .disabled(controller.inPoint == nil && controller.outPoint == nil)
        }
    }

    private var segmentLine: some View {
        Group {
            if let s = controller.segment {
                Label {
                    Text("Segment \(Fmt.timecode(s.start)) – \(Fmt.timecode(s.end)) · \(String(format: "%.2f", s.duration)) s. Only this part is saved.")
                } icon: {
                    Image(systemName: "scissors")
                }
                .foregroundStyle(Color.accentColor)
            } else if controller.available {
                Text("Whole video. Press I and O on the timeline to save only a part.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No preview stream for this video: the whole video is downloaded.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func markButton(_ letter: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: { focused = true; action() }) {
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

struct OptionRow: View {
    let selected: Bool
    let title: String
    let badge: String?
    let detail: String
    let trailing: String?
    let action: () -> Void
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
