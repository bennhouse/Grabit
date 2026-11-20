import Foundation

// MARK: - yt-dlp JSON (only the fields Grabit reads)

struct YTThumbnail: Decodable {
    let url: String?
    let width: Double?
    let height: Double?
}

struct YTFormat: Decodable {
    let format_id: String
    let ext: String?
    let vcodec: String?
    let acodec: String?
    let width: Double?
    let height: Double?
    let fps: Double?
    let tbr: Double?
    let abr: Double?
    let vbr: Double?
    let audio_channels: Double?
    let filesize: Double?
    let filesize_approx: Double?
    let proto: String?
    let url: String?
    let format_note: String?
    let language: String?
    let language_preference: Double?
    let http_headers: [String: String]?
    let dynamic_range: String?

    enum CodingKeys: String, CodingKey {
        case format_id, ext, vcodec, acodec, width, height, fps, tbr, abr, vbr, audio_channels, filesize,
             filesize_approx, url, format_note, language, language_preference, http_headers, dynamic_range
        case proto = "protocol"
    }

    var hasVideo: Bool { (vcodec ?? "none") != "none" && vcodec != nil || (vcodec == nil && height != nil) }
    var hasAudio: Bool {
        if let a = acodec { return a != "none" }
        return vcodec == nil && height == nil   // unknown codecs and no picture: assume audio
    }
    var isStoryboard: Bool { proto == "mhtml" || (format_note ?? "").contains("storyboard") }
}

struct YTItem: Decodable {
    let _type: String?
    let id: String?
    let ie_key: String?
    let title: String?
    let url: String?
    let webpage_url: String?
    let original_url: String?
    let channel: String?
    let uploader: String?
    let duration: Double?
    let view_count: Double?
    let live_status: String?
    let thumbnail: String?
    let thumbnails: [YTThumbnail]?
    let width: Double?
    let height: Double?
    let formats: [YTFormat]?
    let entries: [YTItem?]?
    let extractor_key: String?
}

// MARK: - Search results

struct SearchResult: Identifiable, Hashable {
    let id: String
    let title: String
    let url: String
    let channel: String?
    let duration: Double?
    let views: Double?
    let isLive: Bool
    let thumbnail: URL?

    init?(_ e: YTItem) {
        guard let url = e.url ?? e.webpage_url, let title = e.title else { return nil }
        // YouTube searches also return channels and playlists: keep videos only.
        if let key = e.ie_key, key.hasPrefix("YoutubeTab") || key == "YoutubePlaylist" { return nil }
        self.id = (e.id ?? url) + "|" + url
        self.title = title
        self.url = url
        self.channel = e.channel ?? e.uploader
        self.duration = e.duration
        self.views = e.view_count
        self.isLive = e.live_status == "is_live"
        self.thumbnail = SearchResult.pickThumbnail(e)
    }

    static func pickThumbnail(_ e: YTItem) -> URL? {
        let thumbs = (e.thumbnails ?? []).filter { $0.url != nil }
        // The largest one that is still reasonable for a card.
        let sized = thumbs.filter { ($0.width ?? 0) > 0 && ($0.width ?? 0) <= 1280 }
        if let best = sized.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }), let u = best.url { return URL(string: u) }
        if let u = thumbs.last?.url ?? e.thumbnail { return URL(string: u) }
        // YouTube Music search entries come without thumbnails.
        if let id = e.id, (e.ie_key ?? "").hasPrefix("Youtube"), id.count == 11 {
            return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }
        return nil
    }
}

// MARK: - A video, ready for the download screen

struct VideoOption: Identifiable {
    /// Standard label: 2160, 1440, 1080, 720… It refers to the long side of the frame, as in 16:9
    /// (1920×1080 and 1080×1920 are both 1080p), so letterboxed and vertical videos get the usual names.
    let label: Int
    var id: Int { label }
    let width: Int
    let height: Int
    let fps: Int
    /// yt-dlp sorts formats from worst to best: the last one at this size.
    let best: YTFormat
    /// Best H.264 format at this size, if any: plays everywhere without converting.
    let compatible: YTFormat?

    var title: String { "\(label)p" }
    var badge: String? {
        switch label {
        case 4320...: "8K"
        case 2160...: "4K"
        case 1440...: "QHD"
        case 1080...: "Full HD"
        case 720...: "HD"
        default: nil
        }
    }
}

struct AudioOption: Identifiable {
    let format: YTFormat
    var id: String { format.format_id }
    let codec: String       // "AAC", "Opus"…
    let kbps: Int
    let channels: Int
    let language: String?
    /// The audio is inside a video+audio format (sites without separate audio streams).
    let fromVideo: Bool

    var isAAC: Bool { codec.hasSuffix("AAC") }   // AAC and HE-AAC
    var title: String { kbps > 0 ? "\(kbps) kbps" : "Original audio" }
    var detail: String {
        var parts = [codec]
        if channels > 2 { parts.append(channels == 6 ? "5.1" : "\(channels) ch") }
        if let language { parts.append(language) }
        return parts.joined(separator: " · ")
    }
    /// Extension of the file when the audio is saved as it is.
    var originalExt: String {
        switch codec {
        case "AAC", "HE-AAC": "m4a"
        case "Opus": "opus"
        case "MP3": "mp3"
        case "Vorbis": "ogg"
        case "FLAC": "flac"
        default: format.ext ?? "m4a"
        }
    }
}

struct VideoInfo: Identifiable {
    let id: String
    let title: String
    let webpageURL: String
    let channel: String?
    let duration: Double?
    let views: Double?
    let platform: Platform
    let thumbnail: URL?
    /// Frame size of the best video format: decides between a vertical and a horizontal preview.
    let width: Int
    let height: Int
    let videoOptions: [VideoOption]      // best first
    let audioOptions: [AudioOption]      // best first
    let previewURL: URL?
    let previewHeaders: [String: String]
    let isLive: Bool
    let fps: Double
    /// Separate video and audio streams (YouTube, Vimeo DASH…) rather than one combined file.
    var hasSeparateAudio: Bool { audioOptions.contains { !$0.fromVideo } }

    var aspect: CGFloat { width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : 16.0 / 9.0 }
    var isVertical: Bool { height > width }

    func estimatedSize(_ f: YTFormat) -> Double? {
        if let s = f.filesize ?? f.filesize_approx { return s }
        if let tbr = f.tbr, let d = duration { return tbr * 1000 / 8 * d }
        return nil
    }
}

// MARK: - Building the options from the format list

enum FormatAnalysis {
    static let standard: [(label: Int, long: Double)] = [
        (4320, 7680), (2160, 3840), (1440, 2560), (1080, 1920), (720, 1280), (480, 854), (360, 640), (240, 426), (144, 256),
    ]

    static func label(width: Double, height: Double) -> Int {
        let long = max(width, height)
        for s in standard where long >= s.long * 0.9 { return s.label }
        return Int(min(width, height))
    }

    static func codecName(_ acodec: String?) -> String {
        let a = (acodec ?? "").lowercased()
        if a.hasPrefix("mp4a.40.5") || a.hasPrefix("mp4a.40.29") { return "HE-AAC" }
        if a.hasPrefix("mp4a") || a == "aac" { return "AAC" }
        if a.hasPrefix("opus") { return "Opus" }
        if a == "ac-3" || a == "ac3" { return "Dolby Digital" }
        if a == "ec-3" || a == "eac3" { return "Dolby Digital Plus" }
        if a.hasPrefix("mp3") { return "MP3" }
        if a.hasPrefix("vorbis") { return "Vorbis" }
        if a.hasPrefix("flac") { return "FLAC" }
        if a.isEmpty || a == "none" { return "Audio" }
        return a.uppercased()
    }

    static func isH264(_ v: String?) -> Bool { let c = (v ?? "").lowercased(); return c.hasPrefix("avc") || c.hasPrefix("h264") }
    static func isHEVC(_ v: String?) -> Bool { let c = (v ?? "").lowercased(); return c.hasPrefix("hvc") || c.hasPrefix("hev") || c.hasPrefix("h265") }
    /// QuickTime, Photos, iMovie and Final Cut open these without converting.
    static func playsEverywhere(video v: String?) -> Bool { isH264(v) || isHEVC(v) }
    static func playsEverywhere(audio a: String?) -> Bool {
        let c = (a ?? "").lowercased(); return c.hasPrefix("mp4a") || c == "aac" || c.hasPrefix("mp3") || c == "alac"
    }

    static func makeInfo(_ item: YTItem, requestedURL: String) -> VideoInfo {
        let formats = (item.formats ?? []).filter { !$0.isStoryboard }
        let duration = item.duration

        // Video: group by standard size. HDR formats are left out: their colours look wrong once
        // merged or converted, and every HDR size also exists in SDR.
        let video = formats.filter { $0.hasVideo && ($0.height ?? 0) > 0 && ($0.dynamic_range ?? "SDR") == "SDR" }
        let separateVideo = video.filter { !$0.hasAudio }
        let pool = separateVideo.isEmpty ? video : separateVideo
        var groups: [Int: [YTFormat]] = [:]
        for f in pool { groups[label(width: f.width ?? f.height!, height: f.height!), default: []].append(f) }
        let videoOptions: [VideoOption] = groups.keys.sorted(by: >).map { l in
            let fs = groups[l]!
            let best = fs.last!
            return VideoOption(label: l, width: Int(best.width ?? 0), height: Int(best.height ?? 0),
                               fps: Int((fs.compactMap(\.fps).max() ?? 0).rounded()), best: best,
                               compatible: fs.last { isH264($0.vcodec) })
        }

        // Audio: separate streams when the site has them, otherwise the audio inside the videos.
        var audio: [AudioOption] = []
        var seen = Set<String>()
        let audioOnly = formats.filter { $0.hasAudio && !$0.hasVideo }
        let allIDs = Set(formats.map(\.format_id))
        var source = audioOnly.isEmpty ? formats.filter { $0.hasAudio && $0.hasVideo } : audioOnly
        // Streams with an unknown codec (YouTube's immersive IAMF audio) can't be merged or converted reliably.
        if source.contains(where: { $0.acodec != nil }) { source = source.filter { $0.acodec != nil } }
        let languages = Set(source.compactMap(\.language))
        // Separate audio: best first. Audio inside videos: smallest video first, so "audio only"
        // fetches the lightest stream (on these sites every size usually carries the same audio).
        for f in (audioOnly.isEmpty ? source : source.reversed()) {
            // "-drc" streams are the same audio with compressed dynamics: keep the normal one.
            if f.format_id.hasSuffix("-drc"), allIDs.contains(String(f.format_id.dropLast(4))) { continue }
            let kbps = Int((f.abr ?? (audioOnly.isEmpty ? 0 : f.tbr) ?? 0).rounded())
            let codec = codecName(f.acodec)
            let ch = Int(f.audio_channels ?? 2)
            let lang = languages.count > 1 ? f.language.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 } : nil
            let key = "\(codec)|\(kbps)|\(ch)|\(lang ?? "")"
            if seen.contains(key) { continue }
            seen.insert(key)
            audio.append(AudioOption(format: f, codec: codec, kbps: kbps, channels: ch, language: lang, fromVideo: audioOnly.isEmpty))
        }
        // Only AAC and MP3 are offered, as the user asked: other codecs (Opus, Dolby…) only when
        // the site has nothing else, and then they are converted.
        let common = audio.filter { $0.isAAC || $0.codec == "MP3" }
        if !common.isEmpty { audio = common }
        // Original language first (yt-dlp ranks it higher), then by bitrate.
        audio.sort { a, b in
            let la = a.format.language_preference ?? 0, lb = b.format.language_preference ?? 0
            if la != lb { return la > lb }
            return a.kbps > b.kbps
        }

        // Preview: a combined video+audio stream AVPlayer can open, as sharp as possible up to 720p.
        let combined = formats.filter { $0.hasVideo && $0.hasAudio && $0.url != nil }
        let playable = combined.filter {
            let p = $0.proto ?? "https"
            return (p.hasPrefix("http") && ["mp4", "mov", "m4v"].contains($0.ext ?? "")) || p.hasPrefix("m3u8")
        }
        var preview = playable.filter { ($0.height ?? 0) <= 720 }.last ?? playable.first
        // Music without video (SoundCloud): the player plays the audio stream, under the cover art.
        if preview == nil, video.isEmpty {
            preview = formats.filter { $0.hasAudio && $0.url != nil && (($0.proto ?? "").hasPrefix("m3u8") || ["m4a", "mp3", "mp4"].contains($0.ext ?? "")) }.last
        }

        let top = videoOptions.first
        // No video at all (SoundCloud): the preview is the square cover art.
        let w = top?.width ?? Int(item.width ?? 1), h = top?.height ?? Int(item.height ?? 1)
        let page = item.webpage_url ?? requestedURL
        return VideoInfo(
            id: item.id ?? page, title: item.title ?? "Untitled", webpageURL: page,
            channel: item.channel ?? item.uploader, duration: duration, views: item.view_count,
            platform: Platform.detect(URL(string: page) ?? URL(string: "https://example.com")!),
            thumbnail: bestThumbnail(item), width: w, height: h,
            videoOptions: videoOptions, audioOptions: audio,
            previewURL: preview?.url.flatMap(URL.init(string:)), previewHeaders: preview?.http_headers ?? [:],
            isLive: item.live_status == "is_live",
            fps: videoOptions.first.map { Double(max($0.fps, 1)) } ?? 30)
    }

    static func bestThumbnail(_ item: YTItem) -> URL? {
        let thumbs = (item.thumbnails ?? []).filter { $0.url != nil && !($0.url!.hasSuffix(".webp")) }
        if let t = thumbs.max(by: { ($0.width ?? 0) * ($0.height ?? 0) < ($1.width ?? 0) * ($1.height ?? 0) }),
           (t.width ?? 0) > 0, let u = t.url { return URL(string: u) }
        return (item.thumbnail ?? thumbs.last?.url).flatMap(URL.init(string:))
    }
}

// MARK: - Formatting

enum Fmt {
    static func duration(_ s: Double?) -> String? {
        guard let s, s > 0 else { return nil }
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func views(_ v: Double?) -> String? {
        guard let v else { return nil }
        let n = v.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
        return "\(n) views"
    }

    /// Player time with hundredths: "1:05.20", "1:02:05.20".
    static func timecode(_ t: Double) -> String {
        let t = max(0, t)
        let whole = Int(t), cs = Int(((t - Double(whole)) * 100).rounded(.down))
        if whole >= 3600 { return String(format: "%d:%02d:%02d.%02d", whole / 3600, whole / 60 % 60, whole % 60, cs) }
        return String(format: "%d:%02d.%02d", whole / 60, whole % 60, cs)
    }

    static func bytes(_ b: Double?) -> String? {
        guard let b, b > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
}
