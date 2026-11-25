import AVFoundation
import AppKit
import Observation
import SwiftUI

/// Plays the preview stream and keeps the In and Out marks, like the source viewer of an editor.
@MainActor @Observable
final class PlayerController {
    let player = AVPlayer()
    var duration: Double
    var time: Double = 0
    var isPlaying = false
    var isReady = false
    /// Played or moved away from the very start at least once (the cover gives way to the picture).
    var hasMoved = false
    /// Preview volume, 50% the first time, then as last set.
    var volume: Double = UserDefaults.standard.object(forKey: "previewVolume") as? Double ?? 0.5 {
        didSet {
            player.volume = Float(volume)
            UserDefaults.standard.set(volume, forKey: "previewVolume")
        }
    }
    var failed = false
    var inPoint: Double?
    var outPoint: Double?
    let fps: Double
    let available: Bool

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var scrubStop: Task<Void, Never>?
    @ObservationIgnored private var dragging = false
    @ObservationIgnored private var playingBeforeDrag = false

    init(info: VideoInfo) {
        duration = info.duration ?? 0
        fps = info.fps
        available = info.previewURL != nil
        self.info = info
    }

    @ObservationIgnored private let info: VideoInfo
    @ObservationIgnored private var loaded = false

    /// Opens the preview stream; called when the video screen appears (SwiftUI may create a
    /// controller and throw it away, which loaded the stream twice).
    func load() {
        guard !loaded, let url = info.previewURL else { return }
        loaded = true
        player.actionAtItemEnd = .pause
        player.volume = Float(volume)
        PlayerTrace.log("open \(url.absoluteString.prefix(80)) headers=\(info.previewHeaders.count)")
        if HLSPreview.isMaster(url) {
            // The site's HLS playlist lists every size in H.264, VP9 and AV1; AVPlayer picked a
            // VP9/AV1 one as soon as the picture was on screen and failed ("Cannot Decode"). The
            // preview gets a copy with H.264 up to 720p only (the download keeps its own quality).
            let headers = info.previewHeaders
            Task { [weak self] in
                let asset = await HLSPreview.asset(master: url, headers: headers)
                self?.attach(AVPlayerItem(asset: asset))
            }
        } else {
            var options: [String: Any] = [:]
            if !info.previewHeaders.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = info.previewHeaders }
            attach(AVPlayerItem(asset: AVURLAsset(url: url, options: options)))
        }
        // Meanwhile a light copy (H.264 up to 720p, original audio) is downloaded to a temporary
        // folder; once there, the player switches to it: play, seeks and scrubbing no longer wait
        // for the network.
        local = PreviewDownload.start(info) { [weak self] file in self?.useLocal(file) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                // (Not before the stream is ready: a position chosen meanwhile would be reset to 0.)
                guard let self, !self.dragging, self.isReady, self.pendingSeeks == 0 else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                let playing = self.player.rate != 0
                if self.isPlaying != playing { self.isPlaying = playing }   // (only on change: views depend on it)
                if !self.hasMoved, playing || self.time > 0 { self.hasMoved = true }
                if Int(self.time * 30) % 30 == 0 { PlayerTrace.log("t=\(self.time) rate=\(self.player.rate) wait=\(self.player.reasonForWaitingToPlay?.rawValue ?? "-") status=\(self.player.timeControlStatus.rawValue) size=\(self.player.currentItem?.presentationSize ?? .zero)") }
            }
        }
    }

    private func attach(_ item: AVPlayerItem) {
        item.preferredMaximumResolution = CGSize(width: 1280, height: 720)
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                PlayerTrace.log("status \(item.status.rawValue) error=\(item.error.map { "\($0)" } ?? "-")")
                guard let self else { return }
                self.isReady = item.status == .readyToPlay
                self.failed = item.status == .failed
                if self.duration <= 0, item.duration.isNumeric { self.duration = item.duration.seconds }
                // Marks or a seek made while the playlist was still loading.
                if item.status == .readyToPlay, self.time > 0 { self.seek(self.time) }
            }
        }
    }

    @ObservationIgnored private var local: PreviewDownload?
    /// Playing from the temporary copy.
    @ObservationIgnored private(set) var isLocal = false

    /// Switches to the downloaded copy at the same position, playing if it was playing.
    private func useLocal(_ file: URL) {
        guard !isLocal else { return }
        if dragging {   // not in the middle of a scrub: right after it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.useLocal(file) }
            return
        }
        let asset = AVURLAsset(url: file)
        Task { [weak self] in
            guard (try? await asset.load(.isPlayable)) == true, let self else { return }
            let wasPlaying = self.player.rate != 0
            let at = self.time
            let item = AVPlayerItem(asset: asset)
            self.isLocal = true
            self.statusObservation = nil
            self.player.replaceCurrentItem(with: item)
            self.statusObservation = item.observe(\.status) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, item.status == .readyToPlay else { return }
                    self.statusObservation = nil
                    self.exactSeek(at) { [weak self] in if wasPlaying { self?.player.play() } }
                }
            }
            PlayerTrace.log("local copy in use at \(at)")
        }
    }

    func stop() {
        local?.cancel()
        local = nil
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
    }

    // MARK: Transport

    func togglePlay() {
        guard available else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if duration > 0, time >= duration - 0.05 { seek(0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func pause() { player.pause(); isPlaying = false }
    func play() { player.play(); isPlaying = true }

    func seek(_ t: Double) {
        let t = min(max(0, t), max(duration, 0))
        time = t
        if t > 0, !hasMoved { hasMoved = true }
        exactSeek(t)
    }

    /// Seeks still under way. Until they end, the player reports the position it is leaving: the
    /// playhead jumped back, and I or O pressed then marked the old position. Meanwhile `time` stays
    /// where it was asked to go.
    @ObservationIgnored private var pendingSeeks = 0

    private func exactSeek(_ t: Double, then: (@MainActor () -> Void)? = nil) {
        pendingSeeks += 1
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingSeeks -= 1
                then?()
            }
        }
    }

    /// One frame forward or back (several with `count`), on the frames of the preview stream.
    func step(_ count: Int) {
        guard available else { return }
        pause()
        if let item = player.currentItem, count > 0 ? item.canStepForward : item.canStepBackward {
            item.step(byCount: count)
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                let t = player.currentTime().seconds
                if t.isFinite { time = t }
            }
        } else {
            seek(time + Double(count) / fps)
        }
    }

    func jump(_ seconds: Double) { seek(time + seconds) }

    // MARK: Scrubbing (with sound)

    func beginScrub() {
        guard !dragging else { return }
        dragging = true
        playingBeforeDrag = player.rate != 0
        player.pause()
    }

    /// While dragging, every move seeks and plays a short burst of sound, like an editor's scrub.
    func scrub(to t: Double) {
        let t = min(max(0, t), max(duration, 0))
        time = t
        if !hasMoved { hasMoved = true }
        chase(t)
    }

    // One seek at a time, always to the latest position (Apple's "chase" seek, QA1820): a seek per
    // mouse move piled up and the picture lagged far behind the playhead, above all on HLS.
    @ObservationIgnored private var chaseTarget: Double = 0
    @ObservationIgnored private var chasing = false

    private func chase(_ t: Double) {
        chaseTarget = t
        guard !chasing else { return }
        seekToChaseTarget()
    }

    private func seekToChaseTarget() {
        chasing = true
        let t = chaseTarget
        exactSeek(t) { [weak self] in
            guard let self else { return }
            if self.chaseTarget != t {
                self.seekToChaseTarget()
                return
            }
            self.chasing = false
            // A short burst of sound at the new position, like an editor's scrub.
            guard self.dragging else { return }
            self.player.play()
            self.scrubStop?.cancel()
            self.scrubStop = Task {
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled, self.dragging else { return }
                self.player.pause()
            }
        }
    }

    /// `at`: a mark the click landed on, to stand exactly on it.
    func endScrub(at mark: Double? = nil) {
        if let mark { time = mark }
        dragging = false
        scrubStop?.cancel()
        player.pause()
        exactSeek(time)
        if playingBeforeDrag { player.play() }
        isPlaying = player.rate != 0
    }

    // MARK: In and Out

    /// The position to mark: while playing, the player's own clock (the playhead updates 30 times a
    /// second); otherwise the position asked for, even if the seek to it hasn't finished.
    private var markTime: Double {
        if player.rate != 0, pendingSeeks == 0, !dragging {
            let t = player.currentTime().seconds
            if t.isFinite { time = t; return t }
        }
        return time
    }

    func markIn() {
        let time = markTime
        inPoint = time
        if let o = outPoint, o <= time + 0.04 { outPoint = nil }
    }

    func markOut() {
        let time = markTime
        outPoint = time
        if let i = inPoint, i >= time - 0.04 { inPoint = nil }
    }

    func clearMarks() { inPoint = nil; outPoint = nil }
    func goToIn() { seek(inPoint ?? 0) }
    func goToOut() { seek(outPoint ?? duration) }

    /// The part between the marks. Out alone means "from the start"; In alone means "to the end".
    var segment: Segment? {
        guard inPoint != nil || outPoint != nil, duration > 0 else { return nil }
        let s = Segment(start: inPoint ?? 0, end: outPoint ?? duration)
        return s.duration > 0.05 ? s : nil
    }
}

/// Downloads the light preview copy with yt-dlp into a temporary folder, removed when the video
/// screen closes (and at the next launch, if Grabit didn't quit normally).
@MainActor
final class PreviewDownload {
    static let folderPrefix = "Grabit-preview-"
    private let dir: URL
    private var process: Process?
    private var cancelled = false

    private init(dir: URL) { self.dir = dir }

    /// Nil when the site has no H.264 up to 720p (the preview then keeps streaming).
    static func start(_ info: VideoInfo, ready: @escaping (URL) -> Void) -> PreviewDownload? {
        guard info.duration ?? 0 > 0, !info.isLive,
              let video = info.videoOptions.filter({ max($0.width, $0.height) <= 1280 && min($0.width, $0.height) <= 720 })
                .compactMap(\.compatible).first else { return nil }
        var spec = video.format_id
        if !video.hasAudio {
            guard let audio = info.audioOptions.first(where: { $0.isAAC && !$0.fromVideo }) ?? info.audioOptions.first(where: { !$0.fromVideo }) else { return nil }
            spec += "+" + audio.format.format_id
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(folderPrefix + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = PreviewDownload(dir: dir)
        let p = Process()
        p.executableURL = Tools.ytdlp
        p.arguments = Tools.commonArgs + ["--force-ipv4", "-f", spec, "--merge-output-format", "mp4", "--no-playlist", "--no-mtime",
                                          "-N", "8", "--quiet", "-P", dir.path, "-o", "preview.%(ext)s", info.webpageURL]
        p.environment = Tools.environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let t0 = Date()
        p.terminationHandler = { p in
            Task { @MainActor in
                let file = dir.appendingPathComponent("preview.mp4")
                PlayerTrace.log(String(format: "local copy: status %d after %.1f s", p.terminationStatus, Date().timeIntervalSince(t0)))
                guard !d.cancelled, p.terminationStatus == 0, FileManager.default.fileExists(atPath: file.path) else { return }
                ready(file)
            }
        }
        do { try p.run() } catch { return nil }
        d.process = p
        running.append(d)
        return d
    }

    private static var running: [PreviewDownload] = []

    func cancel() {
        Self.running.removeAll { $0 === self }
        cancelled = true
        if let p = process, p.isRunning { p.terminate() }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Stops the downloads still running and removes every preview folder (at quit, and at launch
    /// for the leftovers of a session that didn't end normally).
    static func removeLeftovers() {
        running.forEach { $0.cancel() }
        let tmp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(folderPrefix) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }
}

/// A copy of a site's HLS master playlist with only the H.264 sizes up to 720p (and their audio),
/// served to AVPlayer through a resource loader; the size playlists it points to stay on the site.
enum HLSPreview {
    static let scheme = "grabit-hls"

    static func isMaster(_ url: URL) -> Bool {
        url.host()?.hasPrefix("manifest.") == true && url.path().contains("hls_variant")
    }

    static func asset(master: URL, headers: [String: String]) async -> AVURLAsset {
        var options: [String: Any] = [:]
        if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        var request = URLRequest(url: master)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8), let filtered = filter(text) else {
            return AVURLAsset(url: master, options: options)   // as it is, if anything goes wrong
        }
        let asset = AVURLAsset(url: URL(string: "\(scheme)://preview/master.m3u8")!, options: options)
        let loader = Loader(playlist: Data(filtered.utf8))
        asset.resourceLoader.setDelegate(loader, queue: .main)
        objc_setAssociatedObject(asset, &loaderKey, loader, .OBJC_ASSOCIATION_RETAIN)   // the loader is held weakly
        PlayerTrace.log("hls: kept\n" + filtered.components(separatedBy: "\n").filter { $0.hasPrefix("#EXT-X-") && !$0.hasPrefix("#EXT-X-MEDIA:URI") || $0.contains("TYPE=AUDIO") }.map { $0.replacingOccurrences(of: #"URI="[^"]*""#, with: "URI=…", options: .regularExpression) }.joined(separator: "\n"))
        return asset
    }

    nonisolated(unsafe) private static var loaderKey = 0

    /// Keeps the sharpest H.264 (avc1) size up to 720p and, among the audio renditions, only the
    /// original track (YouTube also lists its automatic dubs, and AVPlayer would pick the one in the
    /// Mac's language); nil if nothing usable is left.
    static func filter(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        // Variants: (header line, uri, height).
        var variants: [(String, String, Int)] = []
        var i = 0
        while i < lines.count {
            if lines[i].hasPrefix("#EXT-X-STREAM-INF:") {
                let line = lines[i]
                let codecs = attribute("CODECS", in: line) ?? ""
                let height = attribute("RESOLUTION", in: line)?.split(separator: "x").last.flatMap { Int($0) } ?? 0
                if codecs.contains("avc1"), height <= 720, i + 1 < lines.count { variants.append((line, lines[i + 1], height)) }
                i += 2
                continue
            }
            i += 1
        }
        guard let best = variants.map(\.2).max() else { return nil }
        let kept = variants.filter { $0.2 == best }

        let audio = lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=AUDIO") }
        let name = { (l: String) in (attribute("NAME", in: l) ?? "").lowercased() }
        let original = audio.filter { name($0).contains("original") }
        var keptAudio = original.isEmpty ? audio.filter { !name($0).contains("dubbed") } : original
        if keptAudio.isEmpty { keptAudio = audio }
        // The one left in each group is the default, whatever the Mac's language.
        keptAudio = keptAudio.map { $0.replacingOccurrences(of: "DEFAULT=NO", with: "DEFAULT=YES") }
        let groups = Set(keptAudio.compactMap { attribute("GROUP-ID", in: $0) })
        let finalVariants = kept.filter { v in attribute("AUDIO", in: v.0).map(groups.contains) ?? true }
        guard !finalVariants.isEmpty else { return nil }

        var out = lines.filter { $0.hasPrefix("#EXTM3U") || $0.hasPrefix("#EXT-X-INDEPENDENT-SEGMENTS") || $0.hasPrefix("#EXT-X-VERSION") }
        out += keptAudio
        // No subtitle tracks: the playlist marks them "autoselect" and they showed over the picture.
        for v in finalVariants {
            let header = v.0.replacingOccurrences(of: #",SUBTITLES="[^"]*""#, with: "", options: .regularExpression)
            out += [header, v.1]
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let r = line.range(of: name + "=") else { return nil }
        var rest = line[r.upperBound...]
        if rest.first == "\"" {
            rest = rest.dropFirst()
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        return String(rest.prefix { $0 != "," })
    }

    final class Loader: NSObject, AVAssetResourceLoaderDelegate {
        let playlist: Data
        init(playlist: Data) { self.playlist = playlist }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
            guard loadingRequest.request.url?.scheme == HLSPreview.scheme else { return false }
            loadingRequest.contentInformationRequest?.contentType = "public.m3u-playlist"
            loadingRequest.contentInformationRequest?.contentLength = Int64(playlist.count)
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
            loadingRequest.dataRequest?.respond(with: playlist)
            loadingRequest.finishLoading()
            return true
        }
    }
}

/// GRABIT_SNAPSHOT + GRABIT_PLAYERLOG=1: the preview player's events in <folder>/player.log.
enum PlayerTrace {
    static let path: String? = {
        let env = ProcessInfo.processInfo.environment
        guard let d = env["GRABIT_SNAPSHOT"], env["GRABIT_PLAYERLOG"] != nil else { return nil }
        FileManager.default.createFile(atPath: d + "/player.log", contents: nil)
        return d + "/player.log"
    }()
    static let start = Date()
    static func log(_ s: String) {
        guard let path, let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile()
        h.write(Data(String(format: "%.2f %@\n", Date().timeIntervalSince(start), s).utf8))
        try? h.close()
    }
}

/// The video picture alone (no system controls, so the editor keys reach Grabit).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        v.layer = layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Scrub bar with the played part, the playhead and the In/Out marks.
struct Timeline: View {
    @Bindable var controller: PlayerController

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(controller.duration, 0.001)
            let x = { (t: Double) in CGFloat(t / d) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 6)
                Capsule().fill(Color.primary.opacity(0.28)).frame(width: max(0, x(controller.time)), height: 6)
                // The part that will be saved: from In (or the start) to Out (or the end).
                if controller.inPoint != nil || controller.outPoint != nil {
                    let a = x(controller.inPoint ?? 0), b = x(controller.outPoint ?? d)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(6, b - a), height: 6)
                        .offset(x: a)
                }
                if let i = controller.inPoint { marker(x(i)) }
                if let o = controller.outPoint { marker(x(o)) }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 22)
                    .offset(x: min(max(0, x(controller.time) - 1), w - 2))
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        controller.beginScrub()
                        controller.scrub(to: Double(min(max(0, g.location.x), w) / w) * d)
                    }
                    // A click on an In or Out dot puts the playhead exactly on it. Dragging doesn't
                    // stick to the dots.
                    .onEnded { g in
                        let click = abs(g.translation.width) < 3 && abs(g.translation.height) < 3
                        let mark = click ? [controller.inPoint, controller.outPoint].compactMap { $0 }
                            .filter { abs(x($0) - g.startLocation.x) <= 7 }
                            .min { abs(x($0) - g.startLocation.x) < abs(x($1) - g.startLocation.x) } : nil
                        controller.endScrub(at: mark)
                    }
            )
        }
        .frame(height: 30)
        .disabled(!controller.available)
        .accessibilityLabel("Timeline")
        .accessibilityValue(Fmt.timecode(controller.time))
    }

    /// An In or Out mark: a dot on the bar.
    private func marker(_ x: CGFloat) -> some View {
        Circle().fill(Color.accentColor).frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .offset(x: x - 4.5)
    }
}
