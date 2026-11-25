import AppKit
import SwiftUI

struct GrabitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Grabit", id: "main") {
            ContentView()
                .environment(model)
                // No scroll bars anywhere: with "Always show" they took space and lists changed width.
                .scrollIndicators(.never)
        }
        .defaultSize(width: 980, height: 600)
        .windowToolbarStyle(.unified(showsTitle: false))
        // The minimum size is set on the window itself (MainWindow.updateMinSize): with
        // .contentMinSize SwiftUI measured the whole window again after every change of state, 30
        // times a second while the preview played.
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Permissions…") { WelcomeWindow.shared.show() }
                Button("Check for yt-dlp Update…") { Task { await Updater.checkForUpdate() } }
                if Tools.updatedYTDLP != nil {
                    Button("Use the yt-dlp Inside the App") { Updater.revertToBundled() }
                }
            }
            CommandMenu("Go") {
                Button("Search") { model.focusSearch += 1 }.keyboardShortcut("l")
                Button("Back") { model.back() }.keyboardShortcut("[").disabled(!model.canGoBack)
                Button("Home") { model.goHome() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("Download Queue") { model.toggleQueue() }.keyboardShortcut("j", modifiers: [.command, .option])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if !UserDefaults.standard.bool(forKey: Permissions.welcomeKey) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { WelcomeWindow.shared.show() }
            }
            Snapshots.startIfRequested()
            PreviewDownload.removeLeftovers()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { PreviewDownload.removeLeftovers() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated { DownloadManager.shared.active.count }
        guard running > 0 else { return .terminateNow }
        let a = NSAlert()
        a.messageText = running == 1 ? "A download is in progress" : "\(running) downloads are in progress"
        a.informativeText = "Quitting stops them."
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        MainActor.assumeIsolated { DownloadManager.shared.items.filter(\.isActive).forEach { DownloadManager.shared.cancel($0) } }
        return .terminateNow
    }
}

// Command-line test modes (the tools are found through GRABIT_TOOLS when not running from the app bundle):
//   Grabit --search youtube "query"
//   Grabit --info URL
//   Grabit --download URL [--audio-only] [--res 1080] [--container mp4Compatible|mp4|mkv]
//                              [--audio-format aac|mp3] [--audio ID] [--section 65.5-80.25] [--out DIR]
let args = CommandLine.arguments
if args.count > 2, ["--search", "--info", "--download", "--queue-test", "--queue-controls"].contains(args[1]) {
    Task { @MainActor in
        await CLI.run(Array(args.dropFirst()))
        exit(0)
    }
    RunLoop.main.run()
} else {
    GrabitApp.main()
}
