import SwiftUI

struct ResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.resultsTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 22) {
                    ForEach(model.results) { r in
                        ResultCard(result: r)
                    }
                }
                if model.canLoadMore {
                    HStack {
                        Spacer()
                        Button("Show More Results") { model.loadMore() }
                            .controlSize(.large)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(22)
        }
    }
}

struct ResultCard: View {
    @Environment(AppModel.self) private var model
    let result: SearchResult
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.black.opacity(0.15)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    AsyncImage(url: result.thumbnail) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            Image(systemName: model.platform.prefersAudio ? "music.note" : "film")
                                .font(.largeTitle).foregroundStyle(.tertiary)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    if result.isLive {
                        tag("LIVE", .red)
                    } else if let d = Fmt.duration(result.duration) {
                        tag(d, .black.opacity(0.75))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: hover ? 2.5 : 0)
                }
                .scaleEffect(hover ? 1.015 : 1)
                .shadow(color: .black.opacity(hover ? 0.18 : 0.08), radius: hover ? 8 : 3, y: 2)

            Text(result.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text([result.channel, Fmt.views(result.views)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { model.open(result) }
        .help(result.title)
    }

    private func tag(_ text: String, _ bg: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
    }
}
