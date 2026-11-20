import AVFoundation
import AppKit
import Observation
import SwiftUI

/// Plays the preview stream and keeps the In and Out marks, like the source viewer of an editor.
@MainActor @Observable
final class PlayerController {
    let player = AVPlayer()
    var duration: Double
    var time: Double = 0
    var isPlaying = false
    var isReady = false
    var failed = false
    var inPoint: Double?
    var outPoint: Double?
    let fps: Double
    let available: Bool

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var scrubStop: Task<Void, Never>?
    @ObservationIgnored private var dragging = false
    @ObservationIgnored private var playingBeforeDrag = false

    init(info: VideoInfo) {
        duration = info.duration ?? 0
        fps = info.fps
        available = info.previewURL != nil
        guard let url = info.previewURL else { return }
        var options: [String: Any] = [:]
        if !info.previewHeaders.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = info.previewHeaders }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isReady = item.status == .readyToPlay
                self.failed = item.status == .failed
                if self.duration <= 0, item.duration.isNumeric { self.duration = item.duration.seconds }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.dragging else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    func stop() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
    }

    // MARK: Transport

    func togglePlay() {
        guard available else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if duration > 0, time >= duration - 0.05 { seek(0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func pause() { player.pause(); isPlaying = false }
    func play() { player.play(); isPlaying = true }

    func seek(_ t: Double) {
        let t = min(max(0, t), max(duration, 0))
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// One frame forward or back (several with `count`), on the frames of the preview stream.
    func step(_ count: Int) {
        guard available else { return }
        pause()
        if let item = player.currentItem, count > 0 ? item.canStepForward : item.canStepBackward {
            item.step(byCount: count)
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                let t = player.currentTime().seconds
                if t.isFinite { time = t }
            }
        } else {
            seek(time + Double(count) / fps)
        }
    }

    func jump(_ seconds: Double) { seek(time + seconds) }

    // MARK: Scrubbing (with sound)

    func beginScrub() {
        guard !dragging else { return }
        dragging = true
        playingBeforeDrag = player.rate != 0
        player.pause()
    }

    /// While dragging, every move seeks and plays a short burst of sound, like an editor's scrub.
    func scrub(to t: Double) {
        let t = min(max(0, t), max(duration, 0))
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        scrubStop?.cancel()
        scrubStop = Task {
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled, dragging else { return }
            player.pause()
        }
    }

    func endScrub() {
        dragging = false
        scrubStop?.cancel()
        player.pause()
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if playingBeforeDrag { player.play() }
        isPlaying = player.rate != 0
    }

    // MARK: In and Out

    func markIn() {
        inPoint = time
        if let o = outPoint, o <= time + 0.04 { outPoint = nil }
    }

    func markOut() {
        outPoint = time
        if let i = inPoint, i >= time - 0.04 { inPoint = nil }
    }

    func clearMarks() { inPoint = nil; outPoint = nil }
    func goToIn() { seek(inPoint ?? 0) }
    func goToOut() { seek(outPoint ?? duration) }

    /// The part between the marks. Out alone means "from the start"; In alone means "to the end".
    var segment: Segment? {
        guard inPoint != nil || outPoint != nil, duration > 0 else { return nil }
        let s = Segment(start: inPoint ?? 0, end: outPoint ?? duration)
        return s.duration > 0.05 ? s : nil
    }
}

/// The video picture alone (no system controls, so the editor keys reach Grabit).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        v.layer = layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Scrub bar with the played part, the playhead and the In/Out marks.
struct Timeline: View {
    @Bindable var controller: PlayerController
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(controller.duration, 0.001)
            let x = { (t: Double) in CGFloat(t / d) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 6)
                Capsule().fill(Color.primary.opacity(0.28)).frame(width: max(0, x(controller.time)), height: 6)
                if let seg = controller.segment {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.45))
                        .frame(width: max(2, x(seg.end) - x(seg.start)), height: 10)
                        .offset(x: x(seg.start))
                }
                if let i = controller.inPoint { marker(x(i), label: "I") }
                if let o = controller.outPoint { marker(x(o), label: "O") }
                if let hoverX {
                    Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1, height: 16).offset(x: hoverX)
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 22)
                    .offset(x: min(max(0, x(controller.time) - 1), w - 2))
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        controller.beginScrub()
                        controller.scrub(to: Double(min(max(0, g.location.x), w) / w) * d)
                    }
                    .onEnded { _ in controller.endScrub() }
            )
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
            }
        }
        .frame(height: 30)
        .disabled(!controller.available)
        .accessibilityLabel("Timeline")
        .accessibilityValue(Fmt.timecode(controller.time))
    }

    private func marker(_ x: CGFloat, label: String) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 8, weight: .heavy)).foregroundStyle(Color.accentColor)
            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
        }
        .offset(x: x - 4, y: -6)
    }
}
