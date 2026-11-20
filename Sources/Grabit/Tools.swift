import Foundation

/// The command-line tools inside the app (Contents/Resources/bin), copied there by build-app.sh.
/// A yt-dlp update installed from the app menu lives in Application Support and wins over the bundled one.
enum Tools {
    static var bundled: URL {
        if let dir = ProcessInfo.processInfo.environment["GRABIT_TOOLS"] { return URL(fileURLWithPath: dir) }
        return Bundle.main.resourceURL!.appendingPathComponent("bin")
    }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Grabit")
    }

    /// Folder of an updated yt-dlp, if one was installed and still works.
    static var updatedYTDLP: URL? {
        let f = supportDir.appendingPathComponent("yt-dlp/yt-dlp_macos")
        return FileManager.default.isExecutableFile(atPath: f.path) ? f : nil
    }

    static var ytdlp: URL { updatedYTDLP ?? bundled.appendingPathComponent("yt-dlp/yt-dlp_macos") }
    static var ffmpeg: URL { bundled.appendingPathComponent("ffmpeg") }
    static var deno: URL { bundled.appendingPathComponent("deno") }

    static var missing: [String] {
        [("yt-dlp", ytdlp), ("ffmpeg", ffmpeg), ("deno", deno)]
            .filter { !FileManager.default.isExecutableFile(atPath: $0.1.path) }.map(\.0)
    }

    /// Options every yt-dlp call gets: no user config file, bundled ffmpeg and JavaScript runtime.
    static var commonArgs: [String] {
        ["--ignore-config", "--no-warnings", "--ffmpeg-location", ffmpeg.path, "--js-runtimes", "deno:" + deno.path]
    }

    /// An app started from Finder has a bare environment: give the tools a UTF-8 locale (titles
    /// with accents or emoji in file names) and a PATH with the bundled tools.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["PYTHONIOENCODING"] = "utf-8"
        // The static ffmpeg has its own OpenSSL, which doesn't know where macOS keeps the root certificates.
        env["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        env["PATH"] = bundled.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
}

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// The useful part of yt-dlp's error output: its last "ERROR:" line without the extractor prefix.
    static func from(stderr: String, status: Int32) -> ToolError {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        guard var line = lines.last(where: { $0.hasPrefix("ERROR:") }) ?? lines.last else {
            return ToolError(message: "The download tool stopped with code \(status).")
        }
        line = line.replacingOccurrences(of: "ERROR: ", with: "")
        // "[youtube] abc123: Video unavailable" → "Video unavailable"
        if let r = line.range(of: #"^\[[^\]]+\] [^:]+: "#, options: .regularExpression) { line.removeSubrange(r) }
        if line.contains("Unsupported URL") { line = "This link isn’t supported. Check that it points to a video." }
        if line.contains("Sign in to confirm your age") { line = "This video is age-restricted and needs a signed-in account." }
        if line.contains("Private video") { line = "This video is private." }
        return ToolError(message: line)
    }
}

/// Runs a tool to completion and collects its output.
func runTool(_ exe: URL, _ args: [String]) async throws -> (status: Int32, stdout: Data, stderr: String) {
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    p.environment = Tools.environment
    p.standardInput = FileHandle.nullDevice
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cont in
            do { try p.run() } catch { cont.resume(throwing: error); return }
            // Read both pipes on their own threads so a large JSON can't fill a pipe and stall the tool.
            DispatchQueue.global().async {
                let group = DispatchGroup()
                var o = Data(), e = Data()
                group.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, o, String(decoding: e, as: UTF8.self)))
            }
        }
    } onCancel: {
        if p.isRunning { p.terminate() }
    }
}

enum YTDLP {
    static func json(_ args: [String]) async throws -> YTItem {
        let r = try await runTool(Tools.ytdlp, Tools.commonArgs + args)
        guard r.status == 0, !r.stdout.isEmpty else { throw ToolError.from(stderr: r.stderr, status: r.status) }
        do {
            return try JSONDecoder().decode(YTItem.self, from: r.stdout)
        } catch {
            throw ToolError(message: "Couldn’t read the video details (\(error.localizedDescription)).")
        }
    }

    static func search(_ platform: Platform, _ query: String, count: Int) async throws -> [SearchResult] {
        let item = try await json(["--flat-playlist", "-J", "--playlist-end", "\(count)", platform.searchTarget(query, count: count)])
        return dedupe((item.entries ?? []).compactMap { $0.flatMap(SearchResult.init) })
    }

    enum Lookup {
        case video(VideoInfo)
        case list(title: String, [SearchResult])
    }

    /// A pasted link: a single video, or a playlist / channel shown as a list.
    static func lookup(_ url: String) async throws -> Lookup {
        let item = try await json(["-J", "--flat-playlist", "--no-playlist", "--playlist-end", "60", url])
        if item._type == "playlist" || (item.formats == nil && item.entries != nil) {
            let entries = dedupe((item.entries ?? []).compactMap { $0.flatMap(SearchResult.init) })
            // A playlist with a single video (some sites wrap every video like that): open it directly.
            if entries.count == 1, let only = entries.first { return try await lookup(only.url) }
            return .list(title: item.title ?? "Playlist", entries)
        }
        let info = FormatAnalysis.makeInfo(item, requestedURL: url)
        if info.videoOptions.isEmpty && info.audioOptions.isEmpty {
            throw ToolError(message: info.isLive ? "This is a live stream: it can be downloaded once it has ended." : "No downloadable formats found for this link.")
        }
        return .video(info)
    }

    static func version() async -> String? {
        guard let r = try? await runTool(Tools.ytdlp, ["--version"]), r.status == 0 else { return nil }
        return String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dedupe(_ list: [SearchResult]) -> [SearchResult] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.url).inserted }
    }
}
