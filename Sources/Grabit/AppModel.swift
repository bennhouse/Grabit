import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class AppModel {
    enum Screen: Equatable {
        case home
        case loading(String)
        case results
        case video
        case error(String)
    }

    /// YouTube at every launch; a pasted link switches it for the session only.
    var platform: Platform = .youtube
    var query = ""
    var screen: Screen = .home
    var results: [SearchResult] = []
    var resultsTitle = ""
    var video: VideoInfo?
    var showQueue = true
    var focusSearch = 0          // bumped to move the keyboard focus to the search field

    static let pageSize = 24
    private(set) var resultLimit = pageSize
    private(set) var lastSearch: (Platform, String)?
    var canLoadMore: Bool { lastSearch != nil && results.count >= resultLimit && resultLimit < 120 }

    private var task: Task<Void, Never>?

    var canGoBack: Bool {
        switch screen {
        case .video, .error: return true
        case .results: return true
        case .loading: return !results.isEmpty
        case .home: return false
        }
    }

    // MARK: Actions

    func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let url = linkFromInput(text) {
            openLink(url)
        } else if platform.canSearch {
            search(text, limit: Self.pageSize)
        } else {
            screen = .error("\(platform.name) has no search Grabit can use. Paste a link to a video, or switch to YouTube, YouTube Music or SoundCloud to search.")
        }
    }

    func search(_ text: String, limit: Int) {
        let p = platform
        task?.cancel()
        if limit == Self.pageSize { results = [] }
        screen = .loading(limit == Self.pageSize ? "Searching \(p.name)…" : "Loading more results…")
        resultLimit = limit
        task = Task {
            do {
                let found = try await YTDLP.search(p, text, count: limit)
                guard !Task.isCancelled else { return }
                results = found
                resultsTitle = "Results for “\(text)” on \(p.name)"
                lastSearch = (p, text)
                screen = found.isEmpty ? .error("No results for “\(text)” on \(p.name).") : .results
            } catch {
                guard !Task.isCancelled else { return }
                screen = .error(error.localizedDescription)
            }
        }
    }

    func loadMore() {
        guard let (p, text) = lastSearch else { return }
        platform = p
        search(text, limit: resultLimit + Self.pageSize)
    }

    func openLink(_ url: URL) {
        let detected = Platform.detect(url)
        if detected != .other { withAnimation(.smooth(duration: 0.35)) { platform = detected } }
        open(url.absoluteString, fromList: false)
    }

    func open(_ result: SearchResult) { open(result.url, fromList: true) }

    private func open(_ url: String, fromList: Bool) {
        task?.cancel()
        if !fromList { results = []; lastSearch = nil }
        screen = .loading("Reading the video…")
        task = Task {
            do {
                switch try await YTDLP.lookup(url) {
                case .video(let info):
                    guard !Task.isCancelled else { return }
                    video = info
                    screen = .video
                case .list(let title, let entries):
                    guard !Task.isCancelled else { return }
                    results = entries
                    resultsTitle = title
                    lastSearch = nil
                    screen = entries.isEmpty ? .error("This playlist is empty.") : .results
                }
            } catch {
                guard !Task.isCancelled else { return }
                screen = .error(error.localizedDescription)
            }
        }
    }

    func back() {
        task?.cancel()
        switch screen {
        case .video, .error, .loading:
            screen = results.isEmpty ? .home : .results
        case .results:
            screen = .home
        case .home:
            break
        }
    }

    func goHome() {
        task?.cancel()
        screen = .home
        query = ""
        focusSearch += 1
    }
}

/// Default choices on the download screen, shared with the command-line test mode.
enum Defaults {
    static func audio(_ info: VideoInfo, preferAAC: Bool) -> AudioOption? {
        let list = info.audioOptions
        let stereo = list.filter { $0.channels <= 2 && !$0.codec.hasPrefix("HE-") }
        let pool = stereo.isEmpty ? list : stereo
        // Original language: the language preference of the first option.
        let lang = pool.first?.format.language_preference
        let main = pool.filter { $0.format.language_preference == lang }
        if preferAAC, let aac = main.filter(\.isAAC).max(by: { $0.kbps < $1.kbps }) { return aac }
        // Highest bitrate; on a tie, AAC (plays everywhere).
        return main.max { a, b in a.kbps != b.kbps ? a.kbps < b.kbps : (!a.isAAC && b.isAAC) }
    }

    static var downloadFolder: URL {
        if let p = UserDefaults.standard.string(forKey: "downloadFolder") { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}
