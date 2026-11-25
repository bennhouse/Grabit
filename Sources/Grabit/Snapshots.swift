import AppKit
import QuartzCore
import SwiftUI

/// Development aid: with GRABIT_SNAPSHOT=<folder> in the environment, Grabit writes a PNG of each of
/// its windows (toolbar included) every second, so the layout can be checked without screen
/// recording permission: `<name>.png` (drawn by the views, no materials) and `<name>-screen.png`
/// (the real composited pixels, materials included). Does nothing otherwise.
///
/// With it:
///   GRABIT_DEMO=1           fake downloads in the queue (running, queued, finished, failed)
///   GRABIT_QUEUE=open       the queue sidebar open at launch
///   GRABIT_OPEN=<url>       opens that link at launch
///   GRABIT_TOGGLE=<s>       opens/closes the queue every <s> seconds, like its button, and records
///                           each movement: <folder>/burst/<n>-<ms>.png and <folder>/frames.log
///                           (display frames: time and gap, to find hitches)
///   GRABIT_FAKE_DOWNLOAD=<s> the video screen's Download button starts a fake download of <s> seconds
///   GRABIT_AUTODOWNLOAD=<s>  the video screen presses Download <s> seconds after it opens
///   GRABIT_SERIES=1          keeps every still (<name>-screen-<n>.png), every half second
///   GRABIT_APPEARANCE=light|dark
///   GRABIT_AXDUMP=1          accessibility tree and view classes in <folder>/ax.txt
@MainActor
enum Snapshots {
    private static var timer: Timer?
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var dir: String? { env["GRABIT_SNAPSHOT"] }
    /// GRABIT_AUTODOWNLOAD=<s>: the video screen presses Download that many seconds after it opens.
    static var autoDownload: Double? { dir == nil ? nil : env["GRABIT_AUTODOWNLOAD"].flatMap(Double.init) }
    static var fakeDownload: Double? { dir == nil ? nil : env["GRABIT_FAKE_DOWNLOAD"].flatMap(Double.init) }

    static func startIfRequested() {
        guard let dir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // While recording movements, no stills: drawing them blocks the main thread for ~130 ms.
        guard env["GRABIT_TOGGLE"] == nil else { return }
        // GRABIT_SERIES=1: every still is kept (<name>-screen-<n>.png), every half second.
        let series = env["GRABIT_SERIES"] != nil
        var tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: series ? 0.5 : 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                tick += 1
                for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let frameView = w.contentView?.superview else { continue }
                    let b = frameView.bounds
                    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: b) else { continue }
                    frameView.cacheDisplay(in: b, to: rep)
                    let name = w.title.isEmpty ? "window\(i)" : w.title.replacingOccurrences(of: " ", with: "-")
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                    if let img = WindowCapture.image(w.windowNumber) {
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: series ? String(format: "%@/%@-screen-%03d.png", dir, name, tick) : "\(dir)/\(name)-screen.png"))
                    }
                }
            }
        }
    }

    /// GRABIT_AXDUMP=1: the window's accessibility tree and view classes in <folder>/ax.txt, 3 s after launch.
    static func dumpAX(_ dir: String) {
        var out = ""
        func walk(_ e: Any, _ depth: Int) {
            guard depth < 40, let o = e as? NSAccessibilityProtocol & NSObject else { return }
            let role = o.accessibilityRole()?.rawValue ?? "-"
            let sub = o.accessibilitySubrole()?.rawValue ?? ""
            let label = o.accessibilityLabel() ?? ""
            let title = (o.accessibilityTitle() ?? "")
            out += String(repeating: " ", count: depth) + "\(role) \(sub) [\(label)] [\(title)] \(type(of: o))\n"
            for c in o.accessibilityChildren() ?? [] { walk(c, depth + 1) }
        }
        for w in NSApp.windows where w.isVisible { walk(w, 0) }
        out += "\n--- views\n"
        func views(_ v: NSView, _ depth: Int) {
            var extra = ""
            if let b = v as? NSButton { extra = " bezel=\(b.bezelStyle.rawValue) title=\(b.title) hidden=\(b.isHidden) alpha=\(b.alphaValue)" }
            if let o = v as? NSOutlineView {
                extra = " rows=\(o.numberOfRows)"
                for r in 0..<o.numberOfRows { let it = o.item(atRow: r); extra += " [r\(r) outlineCell=\(o.delegate?.outlineView?(o, shouldShowOutlineCellForItem: it as Any) ?? true) group=\(o.delegate?.outlineView?(o, isGroupItem: it as Any) ?? false)]" }
            }
            out += String(repeating: " ", count: depth) + "\(type(of: v)) \(Int(v.frame.width))x\(Int(v.frame.height))\(extra)\n"
            for c in v.subviews { views(c, depth + 1) }
        }
        for w in NSApp.windows where w.isVisible { if let f = w.contentView?.superview { views(f, 0) } }
        try? out.write(toFile: dir + "/ax.txt", atomically: true, encoding: .utf8)
    }

    /// Called by the main view once it is on screen.
    static func attach(_ model: AppModel) {
        guard let dir else { return }
        // The window can appear before the app has finished launching (and made the folder).
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if env["GRABIT_DEMO"] != nil { Demo.fill() }
        if env["GRABIT_AXDUMP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { dumpAX(dir) }
        }
        // GRABIT_APPEARANCE=light|dark
        if let a = env["GRABIT_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua) }
        if env["GRABIT_QUEUE"] == "open" { model.showQueue = true }
        // GRABIT_WIDTH=<pt>: the window this wide (narrow-layout checks). GRABIT_MARKS=<in>,<out>: In and Out on the video screen.
        // GRABIT_WIDTH=<w> or <w>x<h>
        if let size = env["GRABIT_WIDTH"]?.split(separator: "x").compactMap({ Double($0) }), let w = size.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView?.frame.width ?? 0 > 500 }) {
                    var f = win.frame; f.size.width = w
                    if size.count > 1 { f.origin.y += f.height - size[1]; f.size.height = size[1] }
                    win.setFrame(f, display: true)
                }
            }
        }
        if let s = env["GRABIT_OPEN"], let url = URL(string: s) { model.query = s; model.openLink(url) }
        // GRABIT_MARKTEST=1: presses I and O alternately every second (after 6 s), with the frame log.
        // GRABIT_MARKTEST=fast: marks and clears In every 50 ms (to profile the cost of a mark change).
        if env["GRABIT_MARKTEST"] == "fast" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                    MainActor.assumeIsolated { NotificationCenter.default.post(name: .grabitTestMark, object: "toggle") }
                }
            }
        } else if env["GRABIT_MARKTEST"] != nil {
            FrameLog.start(dir)
            var n = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        n += 1
                        FrameLog.mark("press \(n % 2 == 1 ? "I" : "O")")
                        NotificationCenter.default.post(name: .grabitTestMark, object: n % 2 == 1 ? "i" : "o")
                    }
                }
            }
        }
        // GRABIT_PLAY=<s>: presses play on the video screen that many seconds after launch.
        if let s = env["GRABIT_PLAY"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { NotificationCenter.default.post(name: .grabitTestPlay, object: nil) }
        }
        if let s = env["GRABIT_TOGGLE"].flatMap(Double.init) {
            try? FileManager.default.createDirectory(atPath: dir + "/burst", withIntermediateDirectories: true)
            FrameLog.start(dir)
            var n = 0
            Timer.scheduledTimer(withTimeInterval: s, repeats: true) { _ in
                MainActor.assumeIsolated {
                    n += 1
                    FrameLog.mark("toggle \(n) → \(model.showQueue ? "close" : "open")")
                    if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView?.frame.width ?? 0 > 500 }) {
                        Burst.record(window: w.windowNumber, to: dir + "/burst", prefix: n)
                    }
                    model.toggleQueue()
                }
            }
        }
    }
}

/// Real pixels of a window, materials included (CGWindowListCreateImage, looked up at run time:
/// the macOS 15 SDK marks it unavailable).
enum WindowCapture {
    private typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let fn: Fn? = {
        guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func image(_ windowNumber: Int, nominal: Bool = false) -> CGImage? {
        // includingWindow = 1 << 3; boundsIgnoreFraming = 1, bestResolution = 1 << 3, nominal = 1 << 4
        fn?(.null, 1 << 3, UInt32(windowNumber), 1 | (nominal ? 1 << 4 : 1 << 3))?.takeRetainedValue()
    }
}

/// Captures a window every ~16 ms for 0.6 s on a background thread.
enum Burst {
    static func record(window: Int, to dir: String, prefix: Int) {
        Thread.detachNewThread {
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 0.6 {
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if let img = WindowCapture.image(window, nominal: true) {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: String(format: "%@/%02d-%04d.png", dir, prefix, ms)))
                }
                Thread.sleep(forTimeInterval: 0.012)
            }
        }
    }
}

/// Every display frame the main thread gets to: time and the gap since the previous one.
@MainActor
final class FrameLog: NSObject {
    private static var shared: FrameLog?
    private var link: CADisplayLink?
    private var handle: FileHandle?
    private var last: CFTimeInterval = 0
    private let start = CACurrentMediaTime()

    static func start(_ dir: String) {
        let path = dir + "/frames.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        let f = FrameLog()
        f.handle = FileHandle(forWritingAtPath: path)
        f.link = NSScreen.main?.displayLink(target: f, selector: #selector(tick(_:)))
        f.link?.add(to: .main, forMode: .common)
        shared = f
    }

    static func mark(_ s: String) { shared?.write("# \(s)") }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if last > 0 { write(String(format: "%.3f %.1f", now - start, (now - last) * 1000)) }
        last = now
    }

    private func write(_ s: String) { handle?.write(Data((s + "\n").utf8)) }
}

/// Fake downloads for the screenshots.
@MainActor
enum Demo {
    static func info(_ title: String, _ id: String) -> VideoInfo {
        VideoInfo(id: id, title: title, webpageURL: "https://example.com/\(id)", channel: "Demo", duration: 200, views: nil,
                  platform: .youtube, thumbnail: nil, width: 1920, height: 1080, videoOptions: [], audioOptions: [],
                  previewURL: nil, previewHeaders: [:], isLive: false, fps: 30)
    }

    static func request(_ title: String, _ id: String) -> DownloadRequest {
        DownloadRequest(info: info(title, id), audioOnly: true, video: nil, audio: nil, container: .mp4Compatible,
                        audioOutput: .aac, folder: Defaults.downloadFolder)
    }

    static func fill() {
        let m = DownloadManager.shared
        m.enqueue(request("A long video title that takes two lines in the queue", "a"))
        m.enqueue(request("Second video in the queue", "b"))
        m.enqueue(request("Third video", "c"))
        let running = DownloadItem(request: request("Downloading video", "f"), fromQueue: false, detail: "1080p · MP4")
        running.state = .downloading
        running.fraction = 0.42
        let done = DownloadItem(request: request("Finished video", "d"), fromQueue: false, detail: "1080p · MP4")
        done.state = .finished(Defaults.downloadFolder)
        let failed = DownloadItem(request: request("Failed video", "e"), fromQueue: false, detail: "720p · MP4")
        failed.state = .failed("The site refused the connection.")
        m.items += [done, failed]
        if Snapshots.env["GRABIT_DEMO"] == "running" { m.items.insert(running, at: 0) }
    }
}

extension Notification.Name {
    static let grabitTestPlay = Notification.Name("grabitTestPlay")
    static let grabitTestMark = Notification.Name("grabitTestMark")
}
