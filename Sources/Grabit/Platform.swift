import AppKit
import Foundation

/// A site in the platform menu. Only some have a keyword search that yt-dlp can use; the others
/// take a link. A pasted link always works, whatever is selected: yt-dlp recognises the site itself.
enum Platform: String, CaseIterable, Identifiable {
    case youtube, youtubeMusic, soundcloud
    case vimeo, tiktok, instagram, x, facebook, twitch, reddit, dailymotion, bilibili
    case other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .youtube: "YouTube"
        case .youtubeMusic: "YouTube Music"
        case .soundcloud: "SoundCloud"
        case .vimeo: "Vimeo"
        case .tiktok: "TikTok"
        case .instagram: "Instagram"
        case .x: "X (Twitter)"
        case .facebook: "Facebook"
        case .twitch: "Twitch"
        case .reddit: "Reddit"
        case .dailymotion: "Dailymotion"
        case .bilibili: "Bilibili"
        case .other: "Any Website"
        }
    }

    /// File name of the service's own logo in Resources/icons (Simple Icons, CC0).
    var brandIcon: String? {
        switch self {
        case .youtube: "youtube"
        case .youtubeMusic: "youtubemusic"
        case .soundcloud: "soundcloud"
        case .vimeo: "vimeo"
        case .tiktok: "tiktok"
        case .instagram: "instagram"
        case .x: "x"
        case .facebook: "facebook"
        case .twitch: "twitch"
        case .reddit: "reddit"
        case .dailymotion: "dailymotion"
        case .bilibili: "bilibili"
        case .other: nil
        }
    }

    /// Brand colour; nil for the black logos, drawn in the text colour so they show in Dark Mode.
    var brandColor: NSColor? {
        func hex(_ v: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
        switch self {
        case .youtube, .youtubeMusic: return hex(0xFF0000)
        case .soundcloud: return hex(0xFF5500)
        case .vimeo: return hex(0x1AB7EA)
        case .instagram: return hex(0xFF0069)
        case .facebook: return hex(0x0866FF)
        case .twitch: return hex(0x9146FF)
        case .reddit: return hex(0xFF4500)
        case .bilibili: return hex(0x00A1D6)
        case .tiktok, .x, .dailymotion, .other: return nil
        }
    }

    var symbol: String {
        switch self {
        case .youtube: "play.rectangle.fill"
        case .youtubeMusic: "music.note"
        case .soundcloud: "waveform"
        case .vimeo: "v.circle.fill"
        case .tiktok: "music.note.tv"
        case .instagram: "camera"
        case .x: "at"
        case .facebook: "f.cursive.circle.fill"
        case .twitch: "gamecontroller.fill"
        case .reddit: "bubble.left.and.bubble.right.fill"
        case .dailymotion: "d.circle.fill"
        case .bilibili: "tv"
        case .other: "globe"
        }
    }

    /// Host suffixes, used to show which site a pasted link belongs to.
    var hosts: [String] {
        switch self {
        case .youtube: ["youtube.com", "youtu.be", "youtube-nocookie.com"]
        case .youtubeMusic: ["music.youtube.com"]
        case .soundcloud: ["soundcloud.com"]
        case .vimeo: ["vimeo.com"]
        case .tiktok: ["tiktok.com"]
        case .instagram: ["instagram.com"]
        case .x: ["x.com", "twitter.com"]
        case .facebook: ["facebook.com", "fb.watch"]
        case .twitch: ["twitch.tv"]
        case .reddit: ["reddit.com", "redd.it"]
        case .dailymotion: ["dailymotion.com", "dai.ly"]
        case .bilibili: ["bilibili.com", "b23.tv"]
        case .other: []
        }
    }

    var canSearch: Bool { [.youtube, .youtubeMusic, .soundcloud].contains(self) }
    /// SoundCloud and YouTube Music results are music: open them in audio-only mode.
    var prefersAudio: Bool { self == .soundcloud || self == .youtubeMusic }

    /// The argument that makes yt-dlp list search results.
    func searchTarget(_ query: String, count: Int) -> String {
        switch self {
        case .youtubeMusic:
            var c = URLComponents(string: "https://music.youtube.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: query)]
            return c.url!.absoluteString + "#songs"
        case .soundcloud: return "scsearch\(count):\(query)"
        default: return "ytsearch\(count):\(query)"
        }
    }

    var searchPrompt: String {
        canSearch ? "Search \(name) or paste a link" : (self == .other ? "Paste a link to a video" : "Paste \(self == .instagram ? "an" : "a") \(name) link")
    }

    static func detect(_ url: URL) -> Platform {
        guard let host = url.host()?.lowercased() else { return .other }
        // music.youtube.com first: it also ends in youtube.com.
        for p in [Platform.youtubeMusic] + allCases.filter({ $0 != .youtubeMusic }) {
            if p.hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return p }
        }
        return .other
    }
}

/// Returns a URL when the text typed in the search field is a link rather than keywords.
func linkFromInput(_ text: String) -> URL? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, !t.contains(" ") else { return nil }
    if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") {
        return URL(string: t)
    }
    // "youtu.be/abc", "www.tiktok.com/@x/video/1": a dot in the host part and a path.
    let hostPart = t.split(separator: "/").first.map(String.init) ?? t
    if hostPart.contains("."), t.contains("/"), hostPart.range(of: #"^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil {
        return URL(string: "https://" + t)
    }
    return nil
}
