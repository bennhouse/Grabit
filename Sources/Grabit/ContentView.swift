import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 600, minHeight: 460)
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
            }
        }
        .inspector(isPresented: $model.showQueue) {
            QueueSidebar()
                .inspectorColumnWidth(min: 250, ideal: 280, max: 380)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { QueueToggle() }
                }
        }
        .navigationTitle("")
        .onAppear { searchFocused = true }
        .onChange(of: model.focusSearch) { searchFocused = true }
    }
}

// MARK: - Top bar

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
            .frame(width: 320)
    }
}

struct QueueToggle: View {
    @Environment(AppModel.self) private var model
    private var manager = DownloadManager.shared

    var body: some View {
        Button { withAnimation(.smooth(duration: 0.3)) { model.showQueue.toggle() } } label: {
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
