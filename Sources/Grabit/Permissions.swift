import AppKit
import SwiftUI
import UserNotifications

/// The permissions Grabit uses, asked for together on the first launch after installation.
/// - Download folder (required): macOS protects Downloads, Desktop and Documents; Grabit (and the
///   yt-dlp and ffmpeg it runs) must be allowed to write there.
/// - Notifications (optional): a banner when a download finishes or fails while you're elsewhere.
/// Network access needs no permission.
enum Permissions {
    static let welcomeKey = "welcomeDone"
    static let folderAskedKey = "folderAsked"

    enum State { case granted, denied, notAsked }

    static var folder: URL { Defaults.downloadFolder }

    /// Reading the folder is what triggers the macOS prompt, so it is only tried once asked.
    static var folderAccess: State {
        guard UserDefaults.standard.bool(forKey: folderAskedKey) else { return .notAsked }
        return canWrite(folder) ? .granted : .denied
    }

    static func canWrite(_ dir: URL) -> Bool {
        guard (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) != nil else { return false }
        let probe = dir.appendingPathComponent(".grabit-write-test-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    /// Shows the macOS prompt for the folder the first time; after a refusal, opens System Settings.
    static func requestFolder() {
        let first = !UserDefaults.standard.bool(forKey: folderAskedKey)
        UserDefaults.standard.set(true, forKey: folderAskedKey)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !canWrite(folder) && !first { openSettings("Privacy_FilesAndFolders") }
    }

    static func notificationState() async -> State {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional: return .granted
        case .denied: return .denied
        default: return .notAsked
        }
    }

    static func requestNotifications() async {
        if await notificationState() == .denied {
            openSettings("Notifications")
            return
        }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func openSettings(_ pane: String) {
        let url = pane == "Notifications"
            ? "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
            : "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        NSWorkspace.shared.open(URL(string: url)!)
    }

    /// A banner when a download ends, if allowed. Not shown while Grabit is the active app.
    @MainActor
    static func notify(_ title: String, _ body: String) {
        // No application object in the command-line test modes.
        let app: NSApplication? = NSApp
        guard Bundle.main.bundleIdentifier != nil, let app, !app.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

@MainActor
final class WelcomeWindow {
    static let shared = WelcomeWindow()
    private var window: NSWindow?

    /// On the first launch after installation (and from the menu, Permissions…).
    func show() {
        if window == nil {
            let host = NSHostingController(rootView: WelcomeView { [weak self] in self?.window?.close() })
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "Welcome to Grabit"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            // Closing it in any way (button, ⌘W, red dot) counts as seen: it's shown once.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                UserDefaults.standard.set(true, forKey: Permissions.welcomeKey)
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Welcome screen: the permissions, what each is for, and a button to ask for all of them.
struct WelcomeView: View {
    let onDone: () -> Void

    @State private var folder = Permissions.folderAccess
    @State private var notifications = Permissions.State.notAsked
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Grabit").font(.title3.weight(.semibold))
                    Text("Grabit downloads videos and music from YouTube and other sites. Allow these permissions now so it’s ready when you need it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                row("folder", "\(FileManager.default.displayName(atPath: Permissions.folder.path)) Folder",
                    folder == .denied
                        ? "Turn on Grabit in System Settings › Privacy & Security › Files & Folders."
                        : "Save the files you download. Required.",
                    folder) {
                    Permissions.requestFolder()
                    folder = Permissions.folderAccess
                }
                Divider()
                row("bell.badge", "Notifications",
                    "Tell you when a download finishes while you’re in another app. Optional.",
                    notifications) {
                    Task { await Permissions.requestNotifications(); await refreshNotifications() }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))

            Text("Grabit only connects to the sites you search or paste, and to GitHub when you check for a yt-dlp update. You can open this window again from the Grabit menu (Permissions…).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(allGranted ? "Done" : "Not Now") { finish() }
                    .keyboardShortcut(allGranted ? .defaultAction : .cancelAction)
                if !allGranted {
                    Button("Allow All") { allowAll() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 440)
        .task { await refreshNotifications() }
        .onReceive(timer) { _ in
            if folder != .notAsked { folder = Permissions.folderAccess }
            Task { await refreshNotifications() }
        }
    }

    private var allGranted: Bool { folder == .granted && notifications == .granted }

    @ViewBuilder
    private func row(_ symbol: String, _ title: String, _ detail: String, _ state: Permissions.State,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .granted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 16))
                    .transition(.scale.combined(with: .opacity))
            case .denied:
                Button("Open Settings", action: action).controlSize(.small)
            case .notAsked:
                Button("Allow", action: action).controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    private func refreshNotifications() async {
        notifications = await Permissions.notificationState()
    }

    /// The folder first (its prompt is immediate), then notifications.
    private func allowAll() {
        if folder != .granted {
            Permissions.requestFolder()
            folder = Permissions.folderAccess
        }
        guard notifications != .granted else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            await Permissions.requestNotifications()
            await refreshNotifications()
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Permissions.welcomeKey)
        onDone()
    }
}
