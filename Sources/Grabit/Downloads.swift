import AppKit
import Foundation
import Observation

enum VideoContainer: String, CaseIterable, Identifiable {
    case mp4Compatible, mp4, mkv
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mp4Compatible: "MP4 · plays everywhere"
        case .mp4: "MP4 · original codecs"
        case .mkv: "MKV · original codecs"
        }
    }
}

enum AudioOutput: String, CaseIterable, Identifiable {
    case aac, mp3
    var id: String { rawValue }
}

/// A part of the video chosen with In and Out, in seconds.
struct Segment: Equatable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
    /// For file names: "1m05s-1m20s" (no colons, Finder shows them as slashes).
    var stamp: String { "\(Segment.stamp(start))-\(Segment.stamp(end))" }

    static func stamp(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        if s >= 3600 { return String(format: "%dh%02dm%02ds", s / 3600, s / 60 % 60, s % 60) }
        if s >= 60 { return String(format: "%dm%02ds", s / 60, s % 60) }
        return "\(s)s"
    }
}

/// Added to the file name while downloading, and removed by `finalName` at the end. yt-dlp treats an
/// existing file with its target name as "already downloaded" and would convert (and delete) it,
/// so it never sees the final name.
let downloadMarker = ".grabit-download"

/// The file without the marker, numbered (" 2", " 3"…) when that name is taken.
func finalName(_ url: URL) -> URL {
    let dir = url.deletingLastPathComponent()
    let ext = url.pathExtension
    let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: downloadMarker, with: "")
    var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
        n += 1
    }
    return candidate
}

/// Moves a finished file to its final name.
func publish(_ url: URL) -> URL {
    let target = finalName(url)
    do { try FileManager.default.moveItem(at: url, to: target); return target } catch { return url }
}

/// Bitrate for an MP3 made from a source of `kbps`: the next standard step, at most 320.
func mp3Bitrate(for kbps: Int) -> Int {
    [128, 160, 192, 256, 320].first { $0 >= kbps } ?? 320
}

/// AAC bitrate when Grabit has to re-encode audio (Opus → AAC for QuickTime).
func aacBitrate(for kbps: Int) -> Int {
    [128, 160, 192, 256, 320].first { $0 >= kbps } ?? 320
}

struct DownloadRequest {
    let info: VideoInfo
    let audioOnly: Bool
    let video: VideoOption?
    let audio: AudioOption?
    let container: VideoContainer
    let audioOutput: AudioOutput
    let folder: URL
    var segment: Segment? = nil
}

/// What will actually be fetched and done for a request. The download screen uses it too, to
/// say when a conversion will follow.
///
/// A segment is cut by Grabit after the download: yt-dlp's own section download goes through
/// ffmpeg's HTTP client, which YouTube slows to a crawl (15 s of video took 76 s). The streams are
/// fetched at full speed and cut on the Mac with the hardware encoder, to the exact frame.
struct DownloadPlan {
    var formatSpec = ""
    var videoFormat: YTFormat?
    var audioFormat: YTFormat?
    var convertVideo = false
    var convertAudio = false
    var audioKbps = 0
    var args: [String] = []
    var expectedSizes: [String: Double] = [:]
    /// Grabit runs ffmpeg itself after the download (cut and/or convert).
    var postProcess = false

    init(_ r: DownloadRequest) {
        let info = r.info
        let seg = r.segment.map { ", " + $0.stamp } ?? ""
        if r.audioOnly {
            guard let a = r.audio else { return }
            audioFormat = a.format
            audioKbps = a.kbps
            formatSpec = a.format.format_id
            if let s = info.estimatedSize(a.format) { expectedSizes[a.format.format_id] = s }
            if let s = r.segment {
                postProcess = true
                args = ["-f", formatSpec, "-o", "%(title).150B (\(s.stamp))" + downloadMarker + ".%(ext)s"]
                return
            }
            args = ["-f", formatSpec, "-x", "--embed-metadata", "-o", "%(title).150B" + downloadMarker + ".%(ext)s"]
            switch r.audioOutput {
            case .aac:
                // An AAC source is only moved into an .m4a file; anything else is converted.
                args += ["--audio-format", "m4a", "--embed-thumbnail"]
                if !a.isAAC { args += ["--audio-quality", "\(aacBitrate(for: a.kbps))K"] }
            case .mp3:
                args += ["--audio-format", "mp3", "--audio-quality", "\(mp3Bitrate(for: a.kbps))K", "--embed-thumbnail"]
            }
            return
        }

        guard let v = r.video else { return }
        let compat = r.container == .mp4Compatible
        let vf = compat ? (v.compatible ?? v.best) : v.best
        videoFormat = vf
        convertVideo = compat && !FormatAnalysis.playsEverywhere(video: vf.vcodec)
        if vf.hasAudio {
            formatSpec = vf.format_id
            convertAudio = compat && !FormatAnalysis.playsEverywhere(audio: vf.acodec)
            audioKbps = Int(vf.abr ?? 128)
        } else if let a = r.audio, !a.fromVideo {
            audioFormat = a.format
            audioKbps = a.kbps
            formatSpec = "\(vf.format_id)+\(a.format.format_id)"
            convertAudio = compat && !FormatAnalysis.playsEverywhere(audio: a.format.acodec)
        } else {
            formatSpec = vf.format_id
        }
        postProcess = r.segment != nil || convertVideo || convertAudio
        // When Grabit writes the final file, yt-dlp merges into MKV, which takes any codec.
        let merge = postProcess ? "mkv" : (r.container == .mkv ? "mkv" : "mp4")
        args = ["-f", formatSpec, "--merge-output-format", merge, "--remux-video", merge, "--embed-metadata",
                "-o", "%(title).150B (\(v.label)p\(seg))" + downloadMarker + ".%(ext)s"]
        for f in [vf, audioFormat].compactMap({ $0 }) {
            if let s = info.estimatedSize(f) { expectedSizes[f.format_id] = s }
        }
    }

    var needsConversion: Bool { convertVideo || convertAudio }
}

@MainActor @Observable
final class DownloadItem: Identifiable {
    enum State: Equatable {
        case queued
        case waiting
        case downloading
        case processing(String)          // merging, extracting audio: no percentage
        case converting(String)          // Grabit's ffmpeg step, with a percentage
        case finished(URL)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let request: DownloadRequest
    let fromQueue: Bool
    let title: String
    let detail: String
    let thumbnail: URL?
    var state: State
    var fraction: Double = 0
    var speed: String?
    var eta: String?
    var isPaused = false

    @ObservationIgnored fileprivate var process: Process?
    @ObservationIgnored fileprivate var cancelRequested = false

    init(request: DownloadRequest, fromQueue: Bool, detail: String) {
        self.request = request
        self.fromQueue = fromQueue
        self.title = request.info.title
        self.detail = detail
        self.thumbnail = request.info.thumbnail
        self.state = fromQueue ? .queued : .waiting
    }

    var isActive: Bool {
        switch state {
        case .waiting, .downloading, .processing, .converting: true
        default: false
        }
    }
    var isQueued: Bool { state == .queued }
    var isDone: Bool { !isActive && !isQueued }

    var statusText: String {
        if isPaused { return "Paused · \(Int(fraction * 100))%" }
        switch state {
        case .queued: return "Waiting in the queue"
        case .waiting: return "Starting…"
        case .downloading:
            var s = "\(Int(fraction * 100))%"
            if let speed { s += " · \(speed)" }
            if let eta { s += " · \(eta) left" }
            return s
        case .processing(let what): return what
        case .converting(let what): return "\(what) \(Int(fraction * 100))%"
        case .finished: return "Done"
        case .failed(let m): return m
        case .cancelled: return "Cancelled"
        }
    }
}

@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()
    var items: [DownloadItem] = []
    /// The queue downloads one item at a time; this stops it from starting the next one.
    var queuePaused = false {
        didSet { if !queuePaused { pump() } }
    }

    var active: [DownloadItem] { items.filter(\.isActive) }
    var queued: [DownloadItem] { items.filter(\.isQueued) }
    var done: [DownloadItem] { items.filter(\.isDone).reversed() }
    var pendingCount: Int { active.count + queued.count }

    func start(_ r: DownloadRequest) {
        let item = DownloadItem(request: r, fromQueue: false, detail: Self.describe(r))
        items.append(item)
        Task { await run(item) }
    }

    func enqueue(_ r: DownloadRequest) {
        items.append(DownloadItem(request: r, fromQueue: true, detail: Self.describe(r)))
        pump()
    }

    /// Starts the next queued item when no queued item is running.
    private func pump() {
        guard !queuePaused, !items.contains(where: { $0.fromQueue && $0.isActive }),
              let next = items.first(where: \.isQueued) else { return }
        next.state = .waiting
        Task { await run(next) }
    }

    static func describe(_ r: DownloadRequest) -> String {
        var what: String
        if r.audioOnly, let a = r.audio {
            switch r.audioOutput {
            case .aac: what = "Audio · AAC \(a.isAAC ? a.kbps : aacBitrate(for: a.kbps)) kbps"
            case .mp3: what = "Audio · MP3 \(mp3Bitrate(for: a.kbps)) kbps"
            }
        } else {
            what = "\(r.video?.label ?? 0)p · " + (r.container == .mkv ? "MKV" : "MP4")
        }
        if let s = r.segment { what += " · " + Fmt.timecode(s.start) + "–" + Fmt.timecode(s.end) }
        return what
    }

    func cancel(_ item: DownloadItem) {
        if item.isQueued { remove(item); return }
        item.cancelRequested = true
        if let p = item.process, p.isRunning {
            if item.isPaused { send(p, SIGCONT) }
            // yt-dlp starts ffmpeg for merging: stop it too.
            send(p, SIGTERM)
        }
        item.isPaused = false
        item.state = .cancelled
    }

    /// Pause freezes the running process (and the ffmpeg it started); resume lets it go on. yt-dlp
    /// retries the connection if the site dropped it in the meantime.
    func togglePause(_ item: DownloadItem) {
        guard let p = item.process, p.isRunning else { return }
        item.isPaused.toggle()
        send(p, item.isPaused ? SIGSTOP : SIGCONT)
    }

    func retry(_ item: DownloadItem) {
        remove(item)
        if item.fromQueue { enqueue(item.request) } else { start(item.request) }
    }

    func remove(_ item: DownloadItem) { items.removeAll { $0.id == item.id } }
    func clearFinished() { items.removeAll(where: \.isDone) }

    private func send(_ p: Process, _ sig: Int32) {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-\(sig)", "-P", "\(p.processIdentifier)"]
        try? k.run()
        k.waitUntilExit()
        kill(p.processIdentifier, sig)
    }

    // MARK: Running

    private func run(_ item: DownloadItem) async {
        defer {
            announce(item)
            if item.fromQueue { pump() }
        }
        let r = item.request
        let plan = DownloadPlan(r)
        try? FileManager.default.createDirectory(at: r.folder, withIntermediateDirectories: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Grabit-\(item.id.uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        // Intermediate files (streams before merging or converting) stay in a folder of their own;
        // when Grabit cuts or converts, yt-dlp's whole output stays there.
        let home = plan.postProcess ? temp.appendingPathComponent("out").path : r.folder.path
        let args = Tools.commonArgs + plan.args + [
            "--no-playlist", "--newline", "--progress", "--no-mtime",
            "--retries", "20", "--fragment-retries", "20", "--socket-timeout", "30",
            "--progress-template", "download:GBPROG %(info.format_id)s %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s",
            "--print", "after_move:GBFILE %(filepath)s",
            "-P", home, "-P", "temp:" + temp.path, r.info.webpageURL,
        ]
        var downloaded: [String: Double] = [:]
        var totals = plan.expectedSizes
        var file: URL?
        var stderrTail: [String] = []
        item.state = .downloading

        let status = await stream(Tools.ytdlp, args, item: item) { line in
            if line.hasPrefix("GBPROG ") {
                let p = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                guard p.count >= 7 else { return }
                let fid = p[1]
                if let d = Double(p[2]) { downloaded[fid] = d }
                if let t = Double(p[3]) ?? Double(p[4]) { totals[fid] = t }
                let sum = totals.values.reduce(0, +)
                if sum > 0 {
                    let got = totals.keys.reduce(0.0) { $0 + min(downloaded[$1] ?? 0, totals[$1]!) }
                    item.fraction = min(1, got / sum)
                }
                item.speed = Double(p[5]).flatMap { Fmt.bytes($0) }.map { $0 + "/s" }
                item.eta = Double(p[6]).flatMap { Fmt.duration($0) }
                if item.fraction >= 0.999 {
                    item.state = .processing(r.audioOnly ? "Saving audio…" : "Merging video and audio…")
                } else if item.state != .downloading {
                    item.state = .downloading
                }
            } else if line.hasPrefix("GBFILE ") {
                file = URL(fileURLWithPath: String(line.dropFirst(7)))
            } else if !line.isEmpty {
                stderrTail.append(line)
                if stderrTail.count > 30 { stderrTail.removeFirst() }
            }
        }
        if item.cancelRequested { item.state = .cancelled; return }
        guard status == 0, let file else {
            item.state = .failed(ToolError.from(stderr: stderrTail.joined(separator: "\n"), status: status).message)
            return
        }
        item.fraction = 1
        item.speed = nil
        item.eta = nil

        if plan.postProcess {
            await postProcess(item, file: file, plan: plan)
        } else {
            item.state = .finished(publish(file))
        }
    }

    /// Banner at the end of a download, when Grabit isn't the active app.
    private func announce(_ item: DownloadItem) {
        switch item.state {
        case .finished: Permissions.notify("Download finished", item.title)
        case .failed(let m): Permissions.notify("Download failed", "\(item.title): \(m)")
        default: break
        }
    }

    /// Cuts the segment and/or re-encodes for QuickTime (VP9/AV1 → HEVC with the Mac's hardware
    /// encoder, Opus → AAC), writing the final file in the destination folder.
    private func postProcess(_ item: DownloadItem, file: URL, plan: DownloadPlan) async {
        let r = item.request
        let seg = r.segment
        item.state = .converting(seg != nil ? "Cutting the segment…" : "Converting for QuickTime…")
        item.fraction = 0

        var args = ["-hide_banner", "-nostdin", "-y"]
        if let seg { args += ["-ss", String(format: "%.3f", seg.start)] }
        args += ["-i", file.path]
        if let seg { args += ["-t", String(format: "%.3f", seg.duration)] }
        let ext: String
        if r.audioOnly {
            args += ["-map", "0:a:0", "-vn", "-map_metadata", "0"]
            switch r.audioOutput {
            case .aac:
                ext = "m4a"
                args += r.audio?.isAAC == true ? ["-c:a", "copy"] : ["-c:a", "aac_at", "-b:a", "\(aacBitrate(for: plan.audioKbps))k"]
            case .mp3:
                ext = "mp3"
                args += ["-c:a", "libmp3lame", "-b:a", "\(mp3Bitrate(for: plan.audioKbps))k"]
            }
        } else {
            ext = r.container == .mkv ? "mkv" : "mp4"
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0"]
            if seg != nil || plan.convertVideo {
                // Cutting at any frame needs re-encoding. H.264 stays H.264; anything else becomes HEVC.
                if FormatAnalysis.isH264(plan.videoFormat?.vcodec) && !plan.convertVideo {
                    args += ["-c:v", "h264_videotoolbox", "-q:v", "65"]
                } else {
                    args += ["-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1"]
                }
            } else {
                args += ["-c:v", "copy"]
            }
            args += plan.convertAudio ? ["-c:a", "aac_at", "-b:a", "\(aacBitrate(for: plan.audioKbps))k"] : ["-c:a", "copy"]
            if ext == "mp4" { args += ["-movflags", "+faststart"] }
        }
        let base = file.deletingPathExtension().lastPathComponent
        let out = r.folder.appendingPathComponent(base).appendingPathExtension(ext)
        args += ["-progress", "pipe:1", "-nostats", out.path]

        let total = seg?.duration ?? r.info.duration
        var tail: [String] = []
        let status = await stream(Tools.ffmpeg, args, item: item) { line in
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), let d = total, d > 0 {
                item.fraction = min(1, us / 1_000_000 / d)
            } else if !line.contains("=") {
                tail.append(line); if tail.count > 20 { tail.removeFirst() }
            }
        }
        if item.cancelRequested { try? FileManager.default.removeItem(at: out); item.state = .cancelled; return }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: out)
            item.state = .failed("ffmpeg couldn’t process the file: " + (tail.last ?? "error \(status)"))
            return
        }
        item.state = .finished(publish(out))
    }

    /// Runs a tool and hands every output line (stdout and stderr) to `onLine` on the main actor.
    private func stream(_ exe: URL, _ args: [String], item: DownloadItem, onLine: @escaping @MainActor (String) -> Void) async -> Int32 {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = Tools.environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        item.process = p

        final class LineBuffer: @unchecked Sendable {
            var data = Data()
            let lock = NSLock()
            func feed(_ chunk: Data) -> [String] {
                lock.lock(); defer { lock.unlock() }
                data.append(chunk)
                var lines: [String] = []
                while let i = data.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    lines.append(String(decoding: data[data.startIndex..<i], as: UTF8.self))
                    data.removeSubrange(data.startIndex...i)
                }
                return lines
            }
            func rest() -> String? {
                lock.lock(); defer { lock.unlock() }
                let s = String(decoding: data, as: UTF8.self); data.removeAll()
                return s.isEmpty ? nil : s
            }
        }

        return await withCheckedContinuation { cont in
            let bufs = [LineBuffer(), LineBuffer()]
            let group = DispatchGroup()
            for (i, pipe) in [out, err].enumerated() {
                group.enter()
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let chunk = h.availableData
                    if chunk.isEmpty {
                        h.readabilityHandler = nil
                        let last = bufs[i].rest()
                        Task { @MainActor in if let last { onLine(last) } }
                        group.leave()
                        return
                    }
                    let lines = bufs[i].feed(chunk)
                    if !lines.isEmpty { Task { @MainActor in lines.forEach(onLine) } }
                }
            }
            p.terminationHandler = { p in
                group.notify(queue: .main) {
                    // Let the line tasks queued above run first.
                    Task { @MainActor in cont.resume(returning: p.terminationStatus) }
                }
            }
            do { try p.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: -1)
            }
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
