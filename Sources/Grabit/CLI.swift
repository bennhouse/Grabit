import Foundation

/// Command-line test modes: the same code paths as the window, without the window.
@MainActor
enum CLI {
    static func run(_ a: [String]) async {
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil } }
        do {
            switch a[0] {
            case "--search":
                let p = Platform(rawValue: a[1]) ?? .youtube
                let t0 = Date()
                let r = try await YTDLP.search(p, a[2], count: 10)
                print("\(r.count) results in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                for x in r { print("- \(x.title) | \(x.channel ?? "-") | \(Fmt.duration(x.duration) ?? "-") | \(x.url) | thumb: \(x.thumbnail != nil)") }

            case "--info":
                guard case .video(let info) = try await YTDLP.lookup(a[1]) else { print("(a list)"); return }
                printInfo(info)

            case "--download":
                guard case .video(let info) = try await YTDLP.lookup(a[1]) else { print("(a list)"); return }
                printInfo(info)
                let audioOnly = a.contains("--audio-only") || info.videoOptions.isEmpty
                let container = value("--container").flatMap(VideoContainer.init(rawValue:)) ?? .mp4Compatible
                let video = value("--res").flatMap { r in info.videoOptions.first { $0.label == Int(r) } } ?? info.videoOptions.first
                let audio = value("--audio").flatMap { id in info.audioOptions.first { $0.id == id } }
                    ?? Defaults.audio(info, preferAAC: !audioOnly && container == .mp4Compatible)
                let req = DownloadRequest(info: info, audioOnly: audioOnly, video: video, audio: audio, container: container,
                                          audioOutput: value("--audio-format").flatMap(AudioOutput.init(rawValue:)) ?? .aac,
                                          folder: URL(fileURLWithPath: value("--out") ?? FileManager.default.currentDirectoryPath))
                var request = req
                if let s = value("--section")?.split(separator: "-").compactMap({ Double($0) }), s.count == 2 {
                    request.segment = Segment(start: s[0], end: s[1])
                }
                let plan = DownloadPlan(request)
                print("plan: -f \(plan.formatSpec) convertVideo=\(plan.convertVideo) convertAudio=\(plan.convertAudio) args=\(plan.args)")
                let m = DownloadManager.shared
                m.start(request)
                let item = m.items.last!
                var last = ""
                while item.isActive {
                    try await Task.sleep(for: .milliseconds(500))
                    if item.statusText != last { last = item.statusText; print("  \(last)") }
                }
                switch item.state {
                case .finished(let url): print("FINISHED \(url.path)")
                default: print("ENDED \(item.statusText)")
                }
            case "--queue-test":
                // Two items through the queue (one at a time), the first paused for 4 s while downloading.
                let out = URL(fileURLWithPath: value("--out") ?? FileManager.default.currentDirectoryPath)
                let m = DownloadManager.shared
                for url in a.dropFirst().filter({ $0.hasPrefix("http") }) {
                    guard case .video(let info) = try await YTDLP.lookup(url) else { continue }
                    m.enqueue(DownloadRequest(info: info, audioOnly: false, video: info.videoOptions.first { $0.label == 720 } ?? info.videoOptions.first,
                                              audio: Defaults.audio(info, preferAAC: true), container: .mp4Compatible, audioOutput: .aac, folder: out))
                }
                var paused = false
                var last = ""
                while m.items.contains(where: { !$0.isDone }) {
                    try await Task.sleep(for: .milliseconds(250))
                    let line = m.items.map { "[\($0.title.prefix(12)): \($0.statusText)]" }.joined(separator: " ")
                    if line != last { last = line; print(line) }
                    if !paused, let first = m.items.first, first.state == .downloading, first.fraction > 0.05 {
                        paused = true
                        m.togglePause(first); print(">> paused")
                        try await Task.sleep(for: .seconds(4))
                        print(">> still \(first.statusText); resuming")
                        m.togglePause(first)
                    }
                }
                for i in m.items { print("END \(i.title.prefix(20)): \(i.statusText)") }
            default: break
            }
        } catch {
            print("ERROR: \(error.localizedDescription)")
        }
    }

    static func printInfo(_ info: VideoInfo) {
        print("\(info.title) — \(info.channel ?? "-") — \(Fmt.duration(info.duration) ?? "-") — \(info.platform.name)")
        print("frame \(info.width)×\(info.height) vertical=\(info.isVertical) preview=\(info.previewURL != nil) thumb=\(info.thumbnail?.absoluteString ?? "-")")
        for v in info.videoOptions {
            print("  V \(v.title) \(v.badge ?? "") \(v.width)×\(v.height) \(v.fps)fps best=\(v.best.format_id)/\(v.best.vcodec ?? "?") compat=\(v.compatible?.format_id ?? "-") ~\(Fmt.bytes(info.estimatedSize(v.best)) ?? "?")")
        }
        for x in info.audioOptions {
            print("  A \(x.id) \(x.title) \(x.detail) fromVideo=\(x.fromVideo) ~\(Fmt.bytes(info.estimatedSize(x.format)) ?? "?")")
        }
    }
}
