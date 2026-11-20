import AppKit
import CryptoKit
import Foundation

/// Sites change often and yt-dlp follows within days. The app ships with a known-good yt-dlp and
/// can install a newer release in Application Support (checked against the published SHA-256).
/// The app bundle itself is never modified, so its signature stays valid.
@MainActor
enum Updater {
    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let assets: [Asset]
    }

    static func checkForUpdate() async {
        let current = await YTDLP.version() ?? "unknown"
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            let release = try JSONDecoder().decode(Release.self, from: data)
            // Versions are dates (2026.10.26): they compare as strings.
            guard release.tag_name > current else {
                alert("yt-dlp is up to date", "Version \(current) is the latest release.")
                return
            }
            guard confirm("yt-dlp \(release.tag_name) is available",
                          "You have \(current). Download the update from github.com/yt-dlp (about 55 MB)?") else { return }
            guard let zip = release.assets.first(where: { $0.name == "yt-dlp_macos.zip" }),
                  let sums = release.assets.first(where: { $0.name == "SHA2-256SUMS" }) else {
                throw ToolError(message: "The release has no macOS build.")
            }
            let (sumData, _) = try await URLSession.shared.data(from: URL(string: sums.browser_download_url)!)
            let expected = String(decoding: sumData, as: UTF8.self).split(separator: "\n")
                .first { $0.hasSuffix(" yt-dlp_macos.zip") }?.split(separator: " ").first.map(String.init)
            let (tmpZip, _) = try await URLSession.shared.download(from: URL(string: zip.browser_download_url)!)
            let digest = SHA256.hash(data: try Data(contentsOf: tmpZip)).map { String(format: "%02x", $0) }.joined()
            guard let expected, digest == expected else { throw ToolError(message: "The download didn’t match its checksum.") }

            let fm = FileManager.default
            let staging = Tools.supportDir.appendingPathComponent("yt-dlp.new")
            let final = Tools.supportDir.appendingPathComponent("yt-dlp")
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: Tools.supportDir, withIntermediateDirectories: true)
            let unzip = try await runTool(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", tmpZip.path, staging.path])
            guard unzip.status == 0 else { throw ToolError(message: "Couldn’t unpack the update.") }
            let exe = staging.appendingPathComponent("yt-dlp_macos")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            let test = try await runTool(exe, ["--version"])
            guard test.status == 0 else { throw ToolError(message: "The new version doesn’t start on this Mac.") }
            try? fm.removeItem(at: final)
            try fm.moveItem(at: staging, to: final)
            alert("yt-dlp updated", "Grabit now uses yt-dlp \(release.tag_name).")
        } catch {
            alert("Couldn’t update yt-dlp", error.localizedDescription)
        }
    }

    /// Goes back to the yt-dlp inside the app.
    static func revertToBundled() {
        try? FileManager.default.removeItem(at: Tools.supportDir.appendingPathComponent("yt-dlp"))
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private static func confirm(_ title: String, _ text: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "Update")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}
