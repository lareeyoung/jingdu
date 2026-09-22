import SwiftUI
import AppKit

private enum TimelineLayout {
    static let ruler: CGFloat = 22
    static let mediaY: CGFloat = 22
    static let shotsY: CGFloat = 46
    static let originalY: CGFloat = 94
    static let musicY: CGFloat = 124
    static let subtitlesY: CGFloat = 156
    static let notesY: CGFloat = 192
    static let noteHeight: CGFloat = 26
    static let canvasHeight: CGFloat = 296
    static let viewportHeight: CGFloat = 310
    static let maximumZoom: Double = 40
}

struct TimelinePanel: View {
    @EnvironmentObject var model: StudioModel
    @JingduState<Bool> private var showSettings = false
    private let labelWidth: CGFloat = 74

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("镜头时间轴").font(.system(size: 13, weight: .semibold))
                Text("\(model.shots.count) 镜头").font(.system(size: 11)).foregroundStyle(Color.mutedText)
                Spacer(minLength: 5)
                StudioButton(title: "识别切镜", icon: "sparkle.magnifyingglass", compact: true) { model.detectCuts() }.disabled(model.busy || !model.mediaAvailable)
                IconButton(icon: "slider.horizontal.3", help: "切镜识别设置") { showSettings.toggle() }
                    .popover(isPresented: $showSettings) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("切镜识别灵敏度").font(.headline)
                            HStack { Text("更多候选"); Slider(value: $model.sensitivity, in: 0.15...0.65); Text("更少候选") }.font(.caption)
                            Text("通过本地画面变化寻找硬切。快速运动、闪光和 AI 变形可能误报；叠化和极短镜头可能漏检。完成后由你确认。").font(.system(size: 12)).foregroundStyle(Color.mutedText)
                        }.padding(20).frame(width: 355)
                    }
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 18)
                IconButton(icon: "scissors", help: "在当前帧拆分镜头 B") { model.split() }
                IconButton(icon: "arrow.left.to.line", help: "与前一镜头合并") { model.mergePrevious() }.disabled(model.selectedShotIndex == 0)
                IconButton(icon: "bookmark.badge.plus", help: "添加标记 M") { model.addNote(track: model.activeTrack) }
                IconButton(icon: "square.stack.3d.up", help: "收集片段到灵感空间") { model.requestCapture() }.disabled(!model.mediaAvailable)
                IconButton(icon: "music.note.list", help: "导入音乐或声音文件") { model.importMusic() }.disabled(model.project == nil)
                IconButton(icon: "arrow.uturn.backward", help: "撤销 ⌘Z") { model.undo() }.disabled(!model.canUndo)
                HStack(spacing: 4) {
                    Image(systemName: "minus.magnifyingglass")
                    Slider(value: $model.timelineZoom, in: 1...TimelineLayout.maximumZoom).frame(width: 78)
                    Image(systemName: "plus.magnifyingglass")
                    Text(String(format: "%.1f×", model.timelineZoom)).monospacedDigit().frame(width: 35, alignment: .trailing)
                }.font(.system(size: 10)).foregroundStyle(Color.mutedText)
                    .help("双指捏合缩放时间轴；双指左右滑动浏览")
            }.padding(.horizontal, 18).frame(height: 46)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: TimelineLayout.ruler)
                    label("素材", color: Color.accent, icon: "rectangle.stack", height: 24)
                    label("镜头", color: Color.accent, icon: "film", height: 48)
                    label("原声", color: .cyan, icon: "waveform", height: 30)
                    label("音乐", color: .mint, icon: "music.note", height: 32)
                    Button { model.dismissTextFocus(); model.showSubtitleReader = true } label: {
                        label("字幕", color: .teal, icon: "captions.bubble", height: 36)
                            .background(model.showSubtitleReader ? Color.teal.opacity(0.1) : .clear)
                    }.buttonStyle(.plain).help("独立字幕轨：生成、编辑和导出多语言字幕")
                    ForEach(NoteTrack.allCases) { track in
                        Button { model.dismissTextFocus(); model.activeTrack = track } label: {
                            label(shortTitle(track), color: track.color, icon: track.symbol, height: TimelineLayout.noteHeight)
                                .background(model.activeTrack == track ? track.color.opacity(0.09) : Color.clear)
                        }.buttonStyle(.plain).help("选择\(track.title)轨，按 M 添加标记")
                    }
                    Spacer(minLength: 0)
                }.frame(width: labelWidth, height: TimelineLayout.viewportHeight)
                TimelineViewport(model: model).frame(height: TimelineLayout.viewportHeight)
            }.frame(height: TimelineLayout.viewportHeight)
        }.background(Color.panel)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.09)).frame(height: 1) }
    }

    private func label(_ title: String, color: Color, icon: String, height: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
            Text(title).font(.system(size: 11))
            Spacer(minLength: 0)
        }.padding(.leading, 12).frame(height: height).foregroundStyle(Color.mutedText)
    }
}

private func shortTitle(_ track: NoteTrack) -> String {
    switch track {
    case .story: return "叙事"
    case .camera: return "镜头"
    case .sound: return "声音"
    case .learning: return "心得"
    }
}

// The document supplies scrollable space only. Its hosting view is kept at the
// visible origin, so even 40× zoom allocates and paints just one viewport.
private struct TimelineViewport: NSViewRepresentable {
    @ObservedObject var model: StudioModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> TimelineNativeScrollView {
        let scroll = TimelineNativeScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.attach(scroll)
        return scroll
    }

    func updateNSView(_ nsView: TimelineNativeScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.layout()
    }

    static func dismantleNSView(_ nsView: TimelineNativeScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor final class Coordinator {
        var model: StudioModel
        private weak var scroll: TimelineNativeScrollView?
        private let document = TimelineDocumentView()
        private var host: TimelineHostingView?
        private var observation: NSObjectProtocol?
        private var contentWidth: CGFloat = 0
        private var previousViewport: CGFloat = 0
        private var previousZoom: Double = 1
        private var projectID: UUID?
        private var anchor: (fraction: CGFloat, viewportX: CGFloat)?
        private var layingOut = false
        private var previousPlaybackTime: Double?
        private var wasFollowing = false
        private var magnifying = false

        init(model: StudioModel) { self.model = model }

        func attach(_ scroll: TimelineNativeScrollView) {
            self.scroll = scroll
            scroll.documentView = document
            let hosting = TimelineHostingView(rootView: AnyView(Color.clear))
            hosting.frame = .zero
            document.addSubview(hosting)
            host = hosting
            scroll.onResize = { [weak self] in self?.layout() }
            scroll.onMagnify = { [weak self] event in self?.magnify(event) }
            hosting.onMagnify = { [weak self] event in self?.magnify(event) }
            observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
            layout()
        }

        func detach() {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            scroll?.onResize = nil
            scroll?.onMagnify = nil
            host?.onMagnify = nil
        }

        func layout() {
            guard !layingOut, let scroll, let host else { return }
            let viewport = scroll.contentView.bounds.width
            guard viewport > 1 else { return }
            layingOut = true
            defer {
                previousPlaybackTime = model.currentTime
                wasFollowing = (model.scriptPlaybackFollow || model.subtitlePlaybackFollow)
                layingOut = false
            }
            let zoom = min(TimelineLayout.maximumZoom, max(1, model.timelineZoom))
            let newWidth = viewport * zoom
            let oldOrigin = scroll.contentView.bounds.minX
            let projectChanged = projectID != model.project?.id
            let geometryChanged = contentWidth > 0 &&
                (abs(viewport - previousViewport) > 0.1 || abs(zoom - previousZoom) > 0.0001)
            var newOrigin = oldOrigin
            if projectChanged {
                newOrigin = 0
                anchor = nil
                projectID = model.project?.id
            } else if abs(newWidth - contentWidth) > 0.1, contentWidth > 0 {
                if let anchor {
                    newOrigin = anchor.fraction * newWidth - anchor.viewportX
                } else {
                    let duration = model.project?.duration ?? 0
                    let playhead = duration > 0 ? CGFloat(model.currentTime / duration) * contentWidth - oldOrigin : -1
                    let anchorX = playhead >= 0 && playhead <= previousViewport ? playhead : previousViewport / 2
                    let fraction = (oldOrigin + anchorX) / contentWidth
                    let resizedAnchorX = abs(zoom - previousZoom) < 0.0001 ? anchorX * viewport / max(1, previousViewport) : anchorX
                    newOrigin = fraction * newWidth - resizedAnchorX
                }
            }
            contentWidth = newWidth
            previousViewport = viewport
            previousZoom = zoom
            anchor = nil
            document.frame = CGRect(x: 0, y: 0, width: newWidth, height: max(TimelineLayout.canvasHeight, scroll.contentView.bounds.height))
            newOrigin = min(max(0, newOrigin), max(0, newWidth - viewport))
            if let followOrigin = TimelineFollow.targetOrigin(
                currentTime: model.currentTime, duration: model.project?.duration ?? 0,
                currentOrigin: Double(newOrigin), contentWidth: Double(newWidth),
                viewportWidth: Double(viewport), enabled: (model.scriptPlaybackFollow || model.subtitlePlaybackFollow),
                timeChanged: projectChanged || previousPlaybackTime != model.currentTime,
                becameEnabled: (model.scriptPlaybackFollow || model.subtitlePlaybackFollow) && !wasFollowing,
                geometryChanged: geometryChanged, magnifying: magnifying
            ) {
                newOrigin = CGFloat(followOrigin)
            }
            if abs(scroll.contentView.bounds.minX - newOrigin) > 0.1 {
                scroll.contentView.scroll(to: CGPoint(x: newOrigin, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            host.frame = CGRect(x: newOrigin, y: 0, width: viewport, height: TimelineLayout.canvasHeight)
            render()
        }

        private func magnify(_ event: NSEvent) {
            guard let scroll, contentWidth > 0 else { return }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                magnifying = false
            } else if event.phase.contains(.began) || event.phase.contains(.changed) {
                magnifying = true
            }
            let local = scroll.convert(event.locationInWindow, from: nil)
            let pointerX = min(max(0, local.x - scroll.contentView.frame.minX), scroll.contentView.bounds.width)
            let oldZoom = min(TimelineLayout.maximumZoom, max(1, model.timelineZoom))
            let newZoom = min(TimelineLayout.maximumZoom, max(1, oldZoom * (1 + event.magnification)))
            guard abs(newZoom - oldZoom) > 0.00001 else { return }
            anchor = ((scroll.contentView.bounds.minX + pointerX) / contentWidth, pointerX)
            model.timelineZoom = newZoom
            layout()
        }

        private func render() {
            guard let scroll, let host, contentWidth > 0 else { return }
            let width = scroll.contentView.bounds.width
            let origin = min(max(0, scroll.contentView.bounds.minX), max(0, contentWidth - width))
            host.frame = CGRect(x: origin, y: 0, width: width, height: TimelineLayout.canvasHeight)
            host.rootView = AnyView(TimelineCanvas(origin: origin, contentWidth: contentWidth).environmentObject(model))
        }
    }
}

private final class TimelineDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class TimelineNativeScrollView: NSScrollView {
    var onResize: (() -> Void)?
    var onMagnify: ((NSEvent) -> Void)?
    override func layout() { super.layout(); onResize?() }
    override func magnify(with event: NSEvent) { onMagnify?(event) }
}

private final class TimelineHostingView: NSHostingView<AnyView> {
    var onMagnify: ((NSEvent) -> Void)?
    override func magnify(with event: NSEvent) { onMagnify?(event) }
}

private struct TimelineCanvas: View {
    @EnvironmentObject var model: StudioModel
    let origin: CGFloat
    let contentWidth: CGFloat
    @JingduState<TimelineInteraction?> private var interaction: TimelineInteraction?
    @JingduState<(id: UUID, start: Double)?> private var musicPreview: (id: UUID, start: Double)?

    private enum TimelineInteraction {
        case scrub
        case selection
        case music(id: UUID, start: Double)
    }

    var body: some View {
        Canvas { context, size in
            guard let project = model.project, project.duration.isFinite, project.duration > 0 else { return }
            let scale = contentWidth / project.duration
            drawRuler(context: &context, size: size, duration: project.duration, scale: scale)
            drawMedia(context: &context, size: size, project: project, scale: scale)
            drawShots(context: &context, size: size, project: project, scale: scale)
            drawWaveform(context: &context, samples: model.waveform, sourceDuration: project.duration,
                         sourceIn: 0, timelineStart: 0, duration: project.duration, volume: 1,
                         scale: scale, viewportWidth: size.width, centerY: 109, halfHeight: 11, color: .cyan)
            drawMusic(context: &context, size: size, project: project, scale: scale)
            drawSubtitles(context: &context, size: size, project: project, scale: scale)
            drawNotes(context: &context, size: size, project: project, scale: scale)
            if let point = model.pendingIn {
                let start = min(point, model.currentTime) * scale - origin
                let end = max(point, model.currentTime) * scale - origin
                context.fill(Path(CGRect(x: start, y: 22, width: max(1, end - start), height: size.height - 22)), with: .color(Color.accent.opacity(0.09)))
                context.draw(Text("IN").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accent), at: CGPoint(x: point * scale - origin + 3, y: 15), anchor: .leading)
            }
            let x = CGFloat(model.currentTime) * scale - origin
            if x >= -5, x <= size.width + 5 {
                var line = Path(); line.move(to: CGPoint(x: x, y: 17)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.white.opacity(0.94)), lineWidth: 1)
                var head = Path(); head.move(to: CGPoint(x: x - 5, y: 1)); head.addLine(to: CGPoint(x: x + 5, y: 1)); head.addLine(to: CGPoint(x: x + 5, y: 12)); head.addLine(to: CGPoint(x: x, y: 18)); head.addLine(to: CGPoint(x: x - 5, y: 12)); head.closeSubpath()
                context.fill(head, with: .color(Color.accent))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged(handleDrag).onEnded(endDrag))
        .contextMenu {
            Button("在当前帧拆分音乐") { model.dismissTextFocus(); model.splitSelectedMusic() }.disabled(model.selectedMusicID == nil)
            Button("移除选中的音乐", role: .destructive) { model.dismissTextFocus(); model.removeSelectedMusic() }.disabled(model.selectedMusicID == nil)
            Divider()
            Button("导入音乐或声音文件…") { model.dismissTextFocus(); model.importMusic() }
        }
        .help("点击定位；点击标记编辑笔记；拖动音乐片段调整位置；双指捏合缩放，左右滑动浏览")
        .accessibilityLabel("视频时间轴：素材、镜头、原声、音乐、独立字幕和四类学习笔记")
    }

    private func drawRuler(context: inout GraphicsContext, size: CGSize, duration: Double, scale: CGFloat) {
        let desiredStep = 85 / scale
        let steps: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let step = steps.first(where: { $0 >= desiredStep }) ?? 3600
        let first = max(0, floor(origin / scale / step) * step)
        let last = min(duration, (origin + size.width) / scale)
        guard first <= last else { return }
        for time in stride(from: first, through: last, by: step) {
            let x = time * scale - origin
            var line = Path(); line.move(to: CGPoint(x: x, y: 18)); line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.white.opacity(0.055)), lineWidth: 1)
            context.draw(Text(rulerTime(time)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.mutedText), at: CGPoint(x: x + 4, y: 8), anchor: .leading)
        }
    }

    private func drawMedia(context: inout GraphicsContext, size: CGSize, project: FilmProject, scale: CGFloat) {
        for placement in project.clipPlacements {
            let x = placement.start * scale - origin
            let width = max(1, (placement.end - placement.start) * scale - 2)
            guard x + width >= 0, x <= size.width else { continue }
            let rect = CGRect(x: x + 1, y: TimelineLayout.mediaY + 2, width: width, height: 20)
            let selected = model.selectedClipID == placement.id
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.accent.opacity(selected ? 0.25 : 0.10)))
            context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3), with: .color(Color.accent.opacity(selected ? 0.9 : 0.25)), lineWidth: selected ? 1.5 : 0.7)
            drawText(placement.clip.title, context: &context, rect: rect, color: selected ? .white : Color.accent, weight: .medium)
        }
    }

    private func drawShots(context: inout GraphicsContext, size: CGSize, project: FilmProject, scale: CGFloat) {
        for shot in project.shots {
            let x = shot.start * scale - origin
            let width = max(1, shot.duration * scale - 2)
            guard x + width >= 0, x <= size.width else { continue }
            let rect = CGRect(x: x + 1, y: TimelineLayout.shotsY + 2, width: width, height: 44)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(path, with: .color(Color.elevated))
            if let image = model.thumbnails[shot.index], image.size.height > 0, image.size.width > 0 {
                var clipped = context; clipped.clip(to: path)
                let thumbWidth = max(1, image.size.width * 44 / image.size.height)
                let first = max(0, Int(floor((max(0, rect.minX) - rect.minX) / thumbWidth)))
                let last = max(first, Int(ceil((min(size.width, rect.maxX) - rect.minX) / thumbWidth)))
                for index in first...last {
                    clipped.draw(Image(nsImage: image), in: CGRect(x: rect.minX + CGFloat(index) * thumbWidth, y: rect.minY, width: thumbWidth, height: 44))
                }
                context.fill(path, with: .color(.black.opacity(0.25)))
            }
            if shot.index == model.selectedShotIndex {
                context.stroke(Path(roundedRect: rect.insetBy(dx: 0.8, dy: 0.8), cornerRadius: 3), with: .color(Color.accent), lineWidth: 1.5)
            }
            if width > 24 {
                var clipped = context; clipped.clip(to: path)
                clipped.draw(Text(String(format: "%02d", shot.index + 1)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white), at: CGPoint(x: max(7, x + 7), y: rect.minY + 11), anchor: .leading)
            }
        }
    }

    private func drawMusic(context: inout GraphicsContext, size: CGSize, project: FilmProject, scale: CGFloat) {
        if project.music.isEmpty {
            context.draw(Text("导入音乐后，可拖动片段调整位置").font(.system(size: 10)).foregroundStyle(Color.mutedText.opacity(0.5)), at: CGPoint(x: 9, y: TimelineLayout.musicY + 16), anchor: .leading)
        }
        for clip in project.music {
            let start = musicPreview?.id == clip.id ? musicPreview!.start : clip.timelineStart
            let x = start * scale - origin
            let width = max(2, clip.duration * scale)
            guard x + width >= 0, x <= size.width else { continue }
            let selected = model.selectedMusicID == clip.id
            let rect = CGRect(x: x, y: TimelineLayout.musicY + 2, width: width, height: 28)
            let path = Path(roundedRect: rect, cornerRadius: 4)
            context.fill(path, with: .color(Color.mint.opacity(selected ? 0.17 : 0.08)))
            context.stroke(path, with: .color(Color.mint.opacity(selected ? 0.9 : 0.3)), lineWidth: selected ? 1.5 : 0.6)
            var clipped = context; clipped.clip(to: path)
            drawWaveform(context: &clipped, samples: model.musicWaveforms[clip.id] ?? [], sourceDuration: clip.sourceDuration,
                         sourceIn: clip.sourceIn, timelineStart: start, duration: clip.duration, volume: clip.volume,
                         scale: scale, viewportWidth: size.width, centerY: rect.maxY - 6, halfHeight: 5, color: .mint)
            drawText(clip.title, context: &context, rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 14), color: selected ? .white : .mint, weight: .medium)
        }
    }

    private func drawSubtitles(context: inout GraphicsContext, size: CGSize, project: FilmProject, scale: CGFloat) {
        let y = TimelineLayout.subtitlesY
        context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 35)), with: .color(Color.teal.opacity(0.035)))
        guard let track = model.currentSubtitleTrack else {
            context.draw(Text(project.subtitleTrack == nil ? "生成多语言字幕 · 原文 / 中文" : "素材已调整，重新生成字幕")
                .font(.system(size: 10)).foregroundStyle(Color.mutedText.opacity(0.7)), at: CGPoint(x: 9, y: y + 18), anchor: .leading)
            return
        }
        for cue in track.cues {
            let x = cue.start * scale - origin
            let width = max(1, (cue.end - cue.start) * scale - 1)
            guard x + width >= 0, x <= size.width else { continue }
            let rect = CGRect(x: x, y: y + 3, width: width, height: 29)
            let active = model.currentTime >= cue.start && model.currentTime < cue.end
            let selected = model.selectedSubtitleID == cue.id
            let path = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(path, with: .color(Color.teal.opacity(active ? 0.5 : selected ? 0.28 : 0.16)))
            context.stroke(path, with: .color(active ? Color.accent : Color.teal.opacity(0.55)), lineWidth: active ? 1.5 : 0.7)
            if width > 15 { drawText(cue.text, context: &context, rect: rect, color: active ? .white : .teal) }
        }
    }

    private func drawNotes(context: inout GraphicsContext, size: CGSize, project: FilmProject, scale: CGFloat) {
        for (index, track) in NoteTrack.allCases.enumerated() {
            let y = TimelineLayout.notesY + CGFloat(index) * TimelineLayout.noteHeight
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: TimelineLayout.noteHeight - 1)), with: .color(track.color.opacity(model.activeTrack == track ? 0.045 : 0.02)))
            let notes = project.notes.filter { $0.track == track }.sorted {
                if ($0.id == model.selectedNoteID) != ($1.id == model.selectedNoteID) { return $1.id == model.selectedNoteID }
                return $0.start < $1.start
            }
            for note in notes {
                let x = note.start * scale - origin
                let span = max(0, (note.end - note.start) * scale)
                let rect = noteRect(note, scale: scale, y: y + 3)
                let cardIsVisible = rect.maxX >= 0 && rect.minX <= size.width
                let spanIsVisible = span > 0 && x + span >= 0 && x <= size.width
                guard cardIsVisible || spanIsVisible else { continue }
                if span > 2 {
                    context.fill(Path(CGRect(x: x, y: y + 22, width: span, height: 2)), with: .color(track.color.opacity(0.5)))
                }
                let path = Path(roundedRect: rect, cornerRadius: 4)
                let selected = model.selectedNoteID == note.id
                context.fill(path, with: .color(selected ? track.color.opacity(0.38) : (note.hasContent ? track.color.opacity(0.18) : Color.panel)))
                context.stroke(path, with: .color(selected ? .white.opacity(0.94) : track.color.opacity(note.hasContent ? 0.45 : 0.28)), style: StrokeStyle(lineWidth: selected ? 1.5 : 0.8, dash: note.hasContent || selected ? [] : [3, 2]))
                let dot = Path(ellipseIn: CGRect(x: rect.minX + 5, y: y + 10, width: 5, height: 5))
                if note.hasContent { context.fill(dot, with: .color(track.color)) }
                else { context.stroke(dot, with: .color(track.color.opacity(0.7)), lineWidth: 1) }
                // A label near the film end floats to the left; this small tick
                // still shows its true time, including a point exactly at duration.
                if rect.minX < x - 0.5 {
                    let anchorX = min(contentWidth - 1, note.start * scale) - origin
                    context.fill(Path(CGRect(x: anchorX - 1, y: y + 21, width: 2, height: 4)), with: .color(track.color))
                }
                let title = note.hasContent ? note.displayTitle : "\(shortTitle(track)) · \(rulerTime(note.start))"
                drawText(title, context: &context, rect: CGRect(x: rect.minX + 8, y: rect.minY, width: rect.width - 8, height: rect.height), color: selected ? .white : (note.hasContent ? track.color : Color.mutedText))
            }
        }
    }

    // Inputs are RMS time buckets. The outer silhouette is their maximum and
    // the inner silhouette is a time-weighted RMS, not a claimed PCM peak meter.
    private func drawWaveform(context: inout GraphicsContext, samples: [Double], sourceDuration: Double,
                              sourceIn: Double, timelineStart: Double, duration: Double, volume: Double,
                              scale: CGFloat, viewportWidth: CGFloat, centerY: CGFloat, halfHeight: CGFloat, color: Color) {
        guard !samples.isEmpty, sourceDuration.isFinite, sourceDuration > 0, duration > 0, volume.isFinite, volume > 0, scale > 0 else { return }
        let left = max(0, timelineStart * scale - origin)
        let right = min(viewportWidth, (timelineStart + duration) * scale - origin)
        guard right > left else { return }
        let binWidth: CGFloat = 2
        let count = Int(ceil((right - left) / binWidth))
        let sampleScale = Double(samples.count) / sourceDuration
        var peaks = Path()
        var average = Path()
        for bin in 0..<count {
            let x = left + CGFloat(bin) * binWidth
            let endX = min(right, x + binWidth)
            let startTime = (x + origin) / scale - timelineStart + sourceIn
            let endTime = (endX + origin) / scale - timelineStart + sourceIn
            let sampleStart = min(Double(samples.count), max(0, startTime * sampleScale))
            let sampleEnd = min(Double(samples.count), max(0, endTime * sampleScale))
            guard sampleEnd > sampleStart else { continue }
            let first = max(0, min(samples.count - 1, Int(floor(sampleStart))))
            let last = max(first, min(samples.count - 1, Int(ceil(sampleEnd)) - 1))
            var peak = 0.0
            var squares = 0.0
            var weight = 0.0
            for index in first...last {
                let value = samples[index].isFinite ? max(0, samples[index]) : 0
                let overlap = max(0, min(sampleEnd, Double(index + 1)) - max(sampleStart, Double(index)))
                peak = max(peak, value)
                squares += value * value * overlap
                weight += overlap
            }
            let rms = weight > 0 ? sqrt(squares / weight) : 0
            let peakHeight = waveformHeight(peak * volume, maximum: halfHeight)
            let rmsHeight = waveformHeight(rms * volume, maximum: halfHeight)
            if peakHeight > 0 { peaks.addRect(CGRect(x: x, y: centerY - peakHeight, width: max(0.5, endX - x - 0.5), height: peakHeight * 2)) }
            if rmsHeight > 0 { average.addRect(CGRect(x: x, y: centerY - rmsHeight, width: max(0.5, endX - x - 0.5), height: rmsHeight * 2)) }
        }
        context.fill(peaks, with: .color(color.opacity(0.26)))
        context.fill(average, with: .color(color.opacity(0.7)))
    }

    private func waveformHeight(_ value: Double, maximum: CGFloat) -> CGFloat {
        guard value > 0, value.isFinite else { return 0 }
        // A fixed display curve preserves level differences; exact silence stays blank.
        return min(maximum, max(0.45, pow(min(1, value * 2), 0.45) * maximum))
    }

    private func drawText(_ text: String, context: inout GraphicsContext, rect: CGRect, color: Color, weight: Font.Weight = .regular) {
        guard rect.width > 18 else { return }
        var clipped = context
        clipped.clip(to: Path(rect.insetBy(dx: 4, dy: 0)))
        clipped.draw(Text(text).font(.system(size: 10, weight: weight)).foregroundStyle(color), at: CGPoint(x: max(6, rect.minX + 6), y: rect.midY), anchor: .leading)
    }

    private func noteWidth(_ note: StudyNote, scale: CGFloat) -> CGFloat {
        min(190, max(note.hasContent ? 94 : 110, (note.end - note.start) * scale))
    }

    private func noteRect(_ note: StudyNote, scale: CGFloat, y: CGFloat) -> CGRect {
        let width = min(contentWidth, noteWidth(note, scale: scale))
        let documentX = min(max(0, note.start * scale), max(0, contentWidth - width))
        return CGRect(x: documentX - origin, y: y, width: width, height: 20)
    }

    private func handleDrag(_ value: DragGesture.Value) {
        guard let project = model.project, project.duration > 0, contentWidth > 0 else { return }
        let scale = contentWidth / project.duration
        let time = min(project.duration, max(0, (value.location.x + origin) / scale))
        if interaction == nil {
            model.dismissTextFocus()
            let startTime = min(project.duration, max(0, (value.startLocation.x + origin) / scale))
            let y = value.startLocation.y
            if y >= TimelineLayout.musicY, y < TimelineLayout.subtitlesY,
               let clip = project.music.last(where: { startTime >= $0.timelineStart && startTime <= $0.timelineStart + $0.duration }) {
                model.selectMusic(clip.id)
                interaction = .music(id: clip.id, start: clip.timelineStart)
            } else if y >= TimelineLayout.subtitlesY, y < TimelineLayout.notesY {
                model.showSubtitleReader = true
                if let cue = model.currentSubtitleTrack?.activeCue(at: startTime) {
                    model.selectSubtitle(cue); interaction = .selection
                } else { interaction = .scrub }
            } else if y >= TimelineLayout.mediaY, y < TimelineLayout.shotsY,
                      let placement = project.clipPlacements.last(where: { startTime >= $0.start && startTime <= $0.end }) {
                model.selectVideoClip(placement.id)
                interaction = .selection
            } else if y >= TimelineLayout.notesY, y < TimelineLayout.canvasHeight {
                let index = Int((y - TimelineLayout.notesY) / TimelineLayout.noteHeight)
                if NoteTrack.allCases.indices.contains(index) {
                    let track = NoteTrack.allCases[index]
                    model.activeTrack = track
                    let hits = project.notes.filter { note in
                        let rect = noteRect(note, scale: scale, y: 0)
                        return note.track == track && value.startLocation.x >= rect.minX && value.startLocation.x <= rect.maxX
                    }
                    if let note = hits.first(where: { $0.id == model.selectedNoteID }) ?? hits.sorted(by: { $0.start < $1.start }).last {
                        model.selectNote(note)
                        interaction = .selection
                    } else { interaction = .scrub }
                } else { interaction = .scrub }
            } else { interaction = .scrub }
        }
        switch interaction {
        case .scrub: model.seek(time)
        case .music(let id, let start):
            if abs(value.translation.width) >= 3 {
                let clipDuration = project.music.first(where: { $0.id == id })?.duration ?? 0
                let upperBound = max(0, project.duration - clipDuration)
                musicPreview = (id, min(upperBound, max(0, start + value.translation.width / scale)))
            }
        case .selection, .none: break
        }
    }

    private func endDrag(_ value: DragGesture.Value) {
        if case .music(let id, _) = interaction, let preview = musicPreview, preview.id == id {
            model.moveMusic(id, to: preview.start)
        }
        interaction = nil
        musicPreview = nil
    }

    private func rulerTime(_ time: Double) -> String {
        if time < 60 { return String(format: "%g s", (time * 100).rounded() / 100) }
        if time < 3600 { return String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60) }
        return String(format: "%02d:%02d:%02d", Int(time) / 3600, Int(time) / 60 % 60, Int(time) % 60)
    }
}

struct AnalysisSheet: View {
    @EnvironmentObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Color.accent); Text("切镜候选已准备好").font(.system(size: 20, weight: .semibold)) }
            Text("找到 \(model.candidateCuts?.count ?? 0) 个候选切点，预计拆成 \((model.candidateCuts?.count ?? 0) + 1) 个镜头。").font(.system(size: 14))
            Text("这是本地画面变化检测，不是模型理解。快速运动、闪光和 AI 变形可能产生误报，渐变转场也可能漏检。应用后可以逐帧修正，原有笔记会保留。").font(.system(size: 13)).foregroundStyle(Color.mutedText).lineSpacing(5)
            if !(model.candidateCuts ?? []).isEmpty {
                ScrollView { Text((model.candidateCuts ?? []).map {timecode($0, frameRate: model.project?.frameRate ?? 30)}.joined(separator: "    ")).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.accent).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100).padding(12).background(Color.studioBG, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack { Button("取消") { model.showAnalysis = false; model.candidateCuts = nil }.keyboardShortcut(.cancelAction); Spacer(); if !(model.project?.cuts.isEmpty ?? true) { Button("替换全部切点") { model.applyCuts(replace: true) } }; StudioButton(title: model.project?.cuts.isEmpty ?? true ? "应用候选切点" : "加入现有镜头", icon: "checkmark", accent: true) { model.applyCuts(replace: false) } }
        }.padding(28).frame(width: 520).background(Color.panel)
    }
}
