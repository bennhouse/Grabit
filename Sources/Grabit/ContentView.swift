import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @AppStorage("queueWidth") private var queueWidth: Double = 280

    var body: some View {
        @Bindable var model = model
        // The page and the queue sidebar are laid out together, so opening and closing the queue is
        // one movement: the page narrows as the sidebar slides in. (SwiftUI's inspector slid its
        // column over the page first and moved the page afterwards.)
        HStack(spacing: 0) {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Lower by what the window still lacks while it grows for the queue (see MainWindow).
                .frame(minWidth: 600 - model.queueRoomShortfall, minHeight: 460)
                .background { TopBarBackground(material: .titlebar, blending: .withinWindow) }
                .onGeometryChange(for: Double.self) { $0.size.width } action: { model.pageWidth = $0 }
            QueueColumn(width: queueWidth, open: model.showQueue, shown: model.queueReveal.map { $0 * queueWidth })
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(WindowSetup())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.scheme?.hasPrefix("http") == true }) else { return false }
            model.query = url.absoluteString
            model.openLink(url)
            return true
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.back() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .help("Back (⌘[)")
            }
            // Centred over the page: it slides along as the queue sidebar opens and closes.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    PlatformMenu()
                    SearchField(focused: $searchFocused)
                }
                // Room on the right as wide as the queue, rather than an offset: the toolbar keeps the
                // item (and so its clickable area) where it is drawn. With an offset the site menu
                // was drawn over the page but clicked where it used to be, so it didn't open.
                .padding(.trailing, model.queueReveal.map { $0 * queueWidth } ?? (model.showQueue ? queueWidth : 0))
            }
            // Over the queue: Stop, Pause and Play for the queue, then the button that shows it.
            ToolbarItemGroup(placement: .primaryAction) {
                QueueControls()
                QueueToggle()
            }
        }
        .navigationTitle("")
        .onAppear {
            searchFocused = true
            Snapshots.attach(model)
        }
        .onChange(of: model.focusSearch) { searchFocused = true }
        .onChange(of: model.showQueue) { MainWindow.updateMinSize(queueWidth: model.showQueue ? queueWidth : nil) }
        .onChange(of: queueWidth) { MainWindow.updateMinSize(queueWidth: model.showQueue ? queueWidth : nil) }
    }

    @ViewBuilder private var page: some View {
        ZStack {
            switch model.screen {
            case .home:
                HomeView()
            case .loading(let text):
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(text).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .results:
                ResultsView()
            case .video:
                if let info = model.video { VideoView(info: info).id(info.id) }
            case .error(let message):
                ContentUnavailableView {
                    Label("Something went wrong", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button("Back") { model.back() }
                }
            }
        }
    }
}

// MARK: - Top bar

/// The window's top bar is drawn by the views under it (the system's own bar background is
/// hidden), so the page and the queue can each have their own: the page keeps the usual title bar
/// grey, the queue its translucent sidebar material from top to bottom.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// The line under the top bar, the same over the page and over the queue. It copies the one macOS
/// draws under a toolbar (which it can't draw here, the bar's background being the views' own): one
/// device pixel of line and one of soft shadow under it.
struct BarLine: View {
    static let line = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : NSColor(white: 0, alpha: 0.18)
    })
    static let shadow = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0, alpha: 0.25) : NSColor(white: 0, alpha: 0.06)
    })
    @Environment(\.displayScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Self.line).frame(height: 1 / scale)
            Rectangle().fill(Self.shadow).frame(height: 1 / scale)
        }
        .allowsHitTesting(false)
    }
}

/// The bar material under the toolbar and the line under it, above a view that sits below the
/// toolbar.
struct TopBarBackground: View {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    var body: some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                VisualEffect(material: material, blending: blending).frame(height: g.safeAreaInsets.top)
                BarLine()
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
        }
    }
}

/// The main window, for the queue to widen it when there's no room.
@MainActor enum MainWindow {
    weak static var window: NSWindow?

    /// The window's minimum size: the page's 600 × 460 pt, plus the queue while it is open. Set
    /// here rather than measured by SwiftUI (see the window's resizability in main.swift).
    static func updateMinSize(queueWidth: Double?) {
        window?.contentMinSize = NSSize(width: 600 + (queueWidth.map { $0 + 1 } ?? 0), height: 460)
    }

    /// How much wider the window must get for the page (600 pt) and a queue this wide.
    static func shortfall(for queueWidth: Double) -> Double {
        guard let w = window else { return 0 }
        return max(0, (600 + queueWidth + 1 - w.contentLayoutRect.width).rounded(.up))
    }

    /// Widens the window frame by frame along the queue's own curve (ease in-out), so the page keeps
    /// its width while the queue slides in. An AppKit window animation would block SwiftUI's
    /// animation until it ends, and the jump to the new minimum size was a hitch.
    /// `step` gets the eased progress (0…1) on every frame, in the same pass as the window size.
    static func grow(by amount: Double, duration: Double, step: @escaping (Double) -> Void, done: @escaping () -> Void) {
        guard let w = window, amount > 0 else { step(1); done(); return }
        WindowGrower(window: w, amount: amount, duration: duration, step: step, done: done).start()
    }
}

@MainActor
private final class WindowGrower: NSObject {
    private static var running: WindowGrower?
    private let window: NSWindow
    private let start0: NSRect
    private let amount: Double
    private let duration: Double
    private let step: (Double) -> Void
    private let done: () -> Void
    private var link: CADisplayLink?
    private var t0: CFTimeInterval = 0

    init(window: NSWindow, amount: Double, duration: Double, step: @escaping (Double) -> Void, done: @escaping () -> Void) {
        self.window = window
        self.step = step
        self.start0 = window.frame
        self.amount = amount
        self.duration = duration
        self.done = done
    }

    func start() {
        Self.running?.finish()
        Self.running = self
        t0 = CACurrentMediaTime()
        link = window.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    /// The curve of SwiftUI's easeInOut: cubic Bézier (0.42, 0, 0.58, 1).
    private static func ease(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 {   // solve bezier x(t) = x
            let bx = 3 * (1 - t) * (1 - t) * t * 0.42 + 3 * (1 - t) * t * t * 0.58 + t * t * t
            let dx = 3 * (1 - t) * (1 - t) * 0.42 + 6 * (1 - t) * t * (0.58 - 0.42) + 3 * t * t * (1 - 0.58)
            if abs(dx) < 1e-6 { break }
            t -= (bx - x) / dx
            t = min(max(t, 0), 1)
        }
        return 3 * (1 - t) * t * t + t * t * t
    }

    @objc private func tick() {
        let p = min(1, (CACurrentMediaTime() - t0) / duration)
        let e = Self.ease(p)
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { step(e) }
        var f = start0
        f.size.width = start0.width + (amount * e).rounded()
        if let screen = window.screen?.visibleFrame, f.maxX > screen.maxX { f.origin.x = max(screen.minX, screen.maxX - f.width) }
        window.setFrame(f, display: true)
        if p >= 1 { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        if Self.running === self { Self.running = nil }
        done()
    }
}

/// Window settings SwiftUI has no modifier for: no system line under the top bar (the views draw
/// their own).
struct WindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.titlebarSeparatorStyle = .none
            MainWindow.window = v.window
            MainWindow.updateMinSize(queueWidth: nil)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// The queue sidebar at the right of the window. It stays in the view tree when closed (zero
/// wide), so opening it creates nothing and starts at once; its contents keep their width and slide
/// in with the column's edge.
struct QueueColumn: View {
    let width: Double
    let open: Bool
    /// Set while the window grows for the queue: the visible width, frame by frame.
    var shown: Double? = nil
    @AppStorage("queueWidth") private var storedWidth: Double = 280
    @State private var dragStart: Double?

    var body: some View {
        QueueSidebar()
            .frame(width: width)
            .overlay(alignment: .top) { BarLine() }
            .padding(.leading, 1)
            .frame(width: shown.map { $0 + 1 } ?? (open ? width + 1 : 0), alignment: .leading)
            .clipped()
            // Under the content and under the toolbar: the line between the page and the queue,
            // and the queue's material, the same from the top of the window to the bottom.
            .background {
                HStack(spacing: 0) {
                    SideLine()
                    VisualEffect(material: .sidebar, blending: .behindWindow)
                }
                .ignoresSafeArea()
            }
            // The line is also the handle to make the queue wider.
            .overlay(alignment: .leading) {
                Color.clear.frame(width: 7).contentShape(Rectangle())
                    .offset(x: -3)
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            let start = dragStart ?? storedWidth
                            dragStart = start
                            storedWidth = min(380, max(250, start - g.translation.width))
                        }
                        .onEnded { _ in dragStart = nil })
                    .ignoresSafeArea()
            }
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
    }
}

/// The vertical line between the page and the queue: the same colour as the bar lines.
struct SideLine: View {
    var body: some View {
        Rectangle().fill(BarLine.line).frame(width: 1)
    }
}

struct PlatformMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Section("Search") {
                ForEach(Platform.allCases.filter(\.canSearch)) { item($0) }
            }
            Section("Links only") {
                ForEach(Platform.allCases.filter { !$0.canSearch }) { item($0) }
            }
        } label: {
            HStack(spacing: 6) {
                PlatformIcon(platform: model.platform, size: 16)
                Text(model.platform.name)
            }
        }
        .fixedSize()
        .help("Where to search. Links from any site work whatever is selected.")
    }

    private func item(_ p: Platform) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.35)) { model.platform = p }
            model.focusSearch += 1
        } label: {
            Label {
                Text(p.name)
            } icon: {
                Image(nsImage: BrandIcon.image(p, size: 16))
            }
        }
    }
}

struct SearchField: View {
    @Environment(AppModel.self) private var model
    var focused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
        TextField(model.platform.searchPrompt, text: $model.query)
            .textFieldStyle(.roundedBorder)
            .focused(focused)
            .onSubmit { model.submit() }
            // Narrower in a narrow window, so the bar's buttons stay out of the overflow menu.
            // (Narrower still while the queue is open: its room is part of the toolbar item.)
            .frame(width: min(320, max(150, model.pageWidth - (model.showQueue ? 450 : 360))))
    }
}

struct QueueToggle: View {
    @Environment(AppModel.self) private var model
    private var manager = DownloadManager.shared

    var body: some View {
        Button { model.toggleQueue() } label: {
            Label("Downloads", systemImage: "sidebar.right")
        }
        .badge(manager.pendingCount)
        .help(model.showQueue ? "Hide the download queue" : "Show the download queue")
    }
}

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The whole block cross-fades when the site changes (a plain fade, no movement).
        ZStack {
            content
                .id(model.platform)
                .transition(.opacity)
        }
        .animation(.smooth(duration: 0.35), value: model.platform)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(alignment: .center, spacing: 14) {
            PlatformIcon(platform: model.platform, size: 52, style: .secondary)
                .frame(maxWidth: .infinity)
            Text(model.platform.canSearch ? "Search \(model.platform.name) or paste a link" : model.platform.searchPrompt)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text(model.platform.canSearch
                 ? "Type a title in the field above, or paste the address of a video. You can also drop a link on this window."
                 : "\(model.platform.name) can’t be searched from here: paste the address of a video, or drop a link on this window.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            if !Tools.missing.isEmpty {
                Label("Missing tools: \(Tools.missing.joined(separator: ", ")). Rebuild the app with scripts/build-app.sh.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
    }
}
