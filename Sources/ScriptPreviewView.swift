import SwiftUI
import AVKit

/// Coordinates in the reader always stay in project time, including analyses
/// that begin in the middle of a source clip or span multiple source clips.
enum ScriptPreviewRange {
    static func bounds(start: Double, end: Double) -> ClosedRange<Double>? {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        return start...end
    }

    static func clipped(_ range: ClosedRange<Double>?, to bounds: ClosedRange<Double>) -> ClosedRange<Double>? {
        guard let range, range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
        let start = max(range.lowerBound, bounds.lowerBound)
        let end = min(range.upperBound, bounds.upperBound)
        return end > start ? start...end : nil
    }

    static func fraction(_ time: Double, in bounds: ClosedRange<Double>) -> Double {
        guard time.isFinite, bounds.upperBound > bounds.lowerBound else { return 0 }
        return min(1, max(0, (time - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)))
    }

    static func time(at position: Double, width: Double, in bounds: ClosedRange<Double>) -> Double {
        guard position.isFinite, width.isFinite, width > 0 else { return bounds.lowerBound }
        return bounds.lowerBound + min(1, max(0, position / width)) * (bounds.upperBound - bounds.lowerBound)
    }
}

@MainActor private final class ScriptPreviewPlaybackState: ObservableObject {
    @Published var ready = false
    @Published var failed = false
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private var playerObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?

    func attach(_ player: AVPlayer) {
        guard self.player !== player else { return }
        self.player = player
        watch(player.currentItem)
        playerObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in self?.watch(player.currentItem) }
        }
    }

    private func watch(_ item: AVPlayerItem?) {
        self.item = item
        ready = item?.status == .readyToPlay
        failed = item?.status == .failed
        itemObservation = item?.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, self.item === item else { return }
                self.ready = item?.status == .readyToPlay
                self.failed = item?.status == .failed
            }
        }
    }

    func detach() {
        playerObservation = nil; itemObservation = nil
        player = nil; item = nil; ready = false; failed = false
    }
}

@MainActor struct ScriptPreviewPanel: View {
    @EnvironmentObject var studio: StudioModel
    let analysis: ScriptAnalysis
    let selectedRange: ClosedRange<Double>?
    let linked: Bool
    let isCurrent: Bool
    let onSeek: (Double) -> Void
    @StateObject private var playback = ScriptPreviewPlaybackState()

    private var bounds: ClosedRange<Double> { ScriptPreviewRange.bounds(start: analysis.rangeStart, end: analysis.rangeEnd) ?? 0...0 }
    private var selection: ClosedRange<Double>? { ScriptPreviewRange.clipped(selectedRange, to: bounds) }
    private var canPlay: Bool { isCurrent && bounds.upperBound > bounds.lowerBound && studio.mediaAvailable && !studio.playbackLoading && playback.ready }
    private var frameRate: Double { max(1, studio.project?.frameRate ?? 30) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            picture
            controls
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("脚本时间轴").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("点击或拖动定位").font(.system(size: 10)).foregroundStyle(Color.mutedText)
                }
                timeline
            }
            if let selection {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("所选文字对应画面").font(.system(size: 11)).foregroundStyle(Color.mutedText)
                        Text("\(stamp(selection.lowerBound)) – \(stamp(selection.upperBound))")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    Spacer(minLength: 2)
                    Button { play(selection) } label: {
                        Label("回看", systemImage: "play.fill").font(.system(size: 12, weight: .medium))
                    }.disabled(!canPlay).help("只播放所选文字对应的时间区间")
                }
                .padding(12).background(Color.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.panel)
        .onAppear {
            playback.attach(studio.player)
            if isCurrent && !bounds.contains(studio.currentTime) { pause(); onSeek(bounds.lowerBound) }
        }
        .onDisappear { pause(); playback.detach() }
        .onChange(of: studio.currentTime) { _, value in enforceBounds(value) }
        .onChange(of: isCurrent) { _, current in if !current { pause() } }
        .onChange(of: analysis.id) { _, _ in
            pause()
            if isCurrent && !bounds.contains(studio.currentTime) { onSeek(bounds.lowerBound) }
        }
        .onChange(of: playback.failed) { _, failed in if failed { pause() } }
    }

    private var picture: some View {
        ZStack {
            Color.black
            if !isCurrent {
                unavailable("素材已调整", detail: "当前脚本与素材不再对应，请重新反解后对照画面。", icon: "clock.arrow.circlepath")
            } else if playback.failed {
                unavailable("视频无法播放", detail: "请回到项目检查原素材，或重新定位视频后再试。", icon: "exclamationmark.triangle")
            } else if studio.playbackLoading || (studio.mediaAvailable && !playback.ready) {
                ProgressView("正在准备画面…").font(.system(size: 12)).tint(Color.accent)
            } else if studio.mediaAvailable {
                NativePlayer(player: studio.player)
            } else {
                unavailable("原视频暂时不可用", detail: "请回到项目重新定位原视频，再打开脚本。", icon: "externaldrive.badge.questionmark")
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func unavailable(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(Color.mutedText)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(Color.mutedText)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(20)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            IconButton(icon: "backward.frame", help: "上一帧") { step(-1) }.disabled(!canPlay)
            Button {
                if studio.isPlaying { pause() }
                else {
                    let start = bounds.contains(studio.currentTime) && studio.currentTime < bounds.upperBound - 0.02 ? studio.currentTime : bounds.lowerBound
                    play(start...bounds.upperBound)
                }
            } label: {
                Image(systemName: studio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14)).foregroundStyle(Color.studioBG)
                    .frame(width: 36, height: 30).background(Color.accent, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).disabled(!canPlay).accessibilityLabel(studio.isPlaying ? "暂停画面对照" : "播放画面对照")
            IconButton(icon: "forward.frame", help: "下一帧") { step(1) }.disabled(!canPlay)
            Spacer(minLength: 2)
            Text(stamp(studio.currentTime)).font(.system(size: 11, weight: .medium, design: .monospaced))
            IconButton(icon: studio.muted ? "speaker.slash" : "speaker.wave.2", help: studio.muted ? "取消静音" : "静音", active: studio.muted) {
                studio.muted.toggle(); studio.player.isMuted = studio.muted
            }.disabled(!canPlay)
        }
    }

    private var timeline: some View {
        VStack(spacing: 5) {
            HStack {
                Text(stamp(bounds.lowerBound))
                Spacer()
                Text(stamp(bounds.upperBound))
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.mutedText)
            Canvas { context, size in
                let width = size.width
                context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: 60), cornerRadius: 5), with: .color(.black.opacity(0.28)))
                for (index, segment) in analysis.segments.enumerated() {
                    let start = ScriptPreviewRange.fraction(segment.start, in: bounds) * width
                    let end = ScriptPreviewRange.fraction(segment.end, in: bounds) * width
                    guard end > start else { continue }
                    let rect = CGRect(x: start + 1, y: 4, width: max(1, end - start - 2), height: 28)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.accent.opacity(index.isMultiple(of: 2) ? 0.25 : 0.16)))
                    if rect.width > 20 {
                        context.draw(Text(String(format: "%02d", index + 1)).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(.white.opacity(0.8)), at: CGPoint(x: rect.midX, y: 18))
                    }
                }
                for cue in ScriptReading.cues(in: analysis) {
                    let start = ScriptPreviewRange.fraction(cue.start, in: bounds) * width
                    let end = ScriptPreviewRange.fraction(cue.end, in: bounds) * width
                    guard end > start else { continue }
                    let rect = CGRect(x: start + 1, y: 39, width: max(2, end - start - 2), height: 12)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Color.cyan.opacity(cue.isParagraphFallback ? 0.25 : 0.6)))
                }
                if let selection {
                    let x = ScriptPreviewRange.fraction(selection.lowerBound, in: bounds) * width
                    let end = ScriptPreviewRange.fraction(selection.upperBound, in: bounds) * width
                    let rect = CGRect(x: x + 0.5, y: 1, width: max(1, end - x - 1), height: 57)
                    context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color.accent), lineWidth: 1.5)
                }
                if bounds.contains(studio.currentTime) {
                    let x = min(width - 1, max(1, ScriptPreviewRange.fraction(studio.currentTime, in: bounds) * width))
                    var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: 60))
                    context.stroke(path, with: .color(.white), lineWidth: 2)
                }
            }
            .frame(height: 60)
            .overlay {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            seek(ScriptPreviewRange.time(at: value.location.x, width: geometry.size.width, in: bounds))
                        }
                    )
                }
            }
            .opacity(canPlay ? 1 : 0.45)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("脚本时间轴，点击定位画面")
            .accessibilityValue(stamp(studio.currentTime))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: seek(studio.currentTime + 1 / frameRate)
                case .decrement: seek(studio.currentTime - 1 / frameRate)
                @unknown default: break
                }
            }
            HStack(spacing: 12) {
                legend("脚本分段", color: .accent)
                legend("台词", color: .cyan)
                Spacer()
                Text("项目时间").font(.system(size: 10)).foregroundStyle(Color.mutedText)
            }
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.7)).frame(width: 9, height: 5); Text(title) }
            .font(.system(size: 10)).foregroundStyle(Color.mutedText)
    }

    private func stamp(_ time: Double) -> String { timecode(time, frameRate: frameRate) }
    private func pause() { studio.player.pause(); studio.isPlaying = false }
    private func seek(_ time: Double) {
        guard canPlay, time.isFinite else { return }
        pause(); onSeek(min(bounds.upperBound, max(bounds.lowerBound, time)))
    }
    private func play(_ range: ClosedRange<Double>) {
        guard canPlay, let range = ScriptPreviewRange.clipped(range, to: bounds) else { return }
        studio.playNote(StudyNote(start: range.lowerBound, end: range.upperBound, track: .story, title: "脚本回看", body: "", takeaway: ""))
    }
    private func step(_ direction: Double) {
        guard canPlay else { return }
        pause()
        if !bounds.contains(studio.currentTime) { onSeek(bounds.lowerBound); return }
        let target = studio.currentTime + direction / frameRate
        if target <= bounds.lowerBound || target >= bounds.upperBound { seek(target); return }
        studio.step(direction)
    }
    private func enforceBounds(_ time: Double) {
        guard isCurrent, time.isFinite else { return }
        if time < bounds.lowerBound || time > bounds.upperBound {
            pause(); studio.seek(min(bounds.upperBound, max(bounds.lowerBound, time)))
        } else if studio.isPlaying && time >= bounds.upperBound {
            pause()
        }
    }
}
