import AppKit

/// Development aid: with GRABIT_SNAPSHOT=<folder> in the environment, Grabit writes a PNG of each of
/// its windows (toolbar included) every second, so the layout can be checked without screen
/// recording permission. Does nothing otherwise.
@MainActor
enum Snapshots {
    private static var timer: Timer?

    static func startIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["GRABIT_SNAPSHOT"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let frameView = w.contentView?.superview else { continue }
                    let b = frameView.bounds
                    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: b) else { continue }
                    frameView.cacheDisplay(in: b, to: rep)
                    let name = w.title.isEmpty ? "window\(i)" : w.title.replacingOccurrences(of: " ", with: "-")
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                }
            }
        }
    }
}
