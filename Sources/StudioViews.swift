import SwiftUI
import AVKit
import UniformTypeIdentifiers

extension Color {
    static let studioBG = Color(red: 0.055, green: 0.063, blue: 0.077)
    static let panel = Color(red: 0.082, green: 0.094, blue: 0.109)
    static let elevated = Color(red: 0.12, green: 0.135, blue: 0.155)
    static let accent = Color(red: 0.79, green: 0.94, blue: 0.40)
    static let mutedText = Color(red: 0.57, green: 0.61, blue: 0.66)
}
extension NoteTrack {
    var color: Color { switch self { case .story: return Color(red: 0.75, green: 0.63, blue: 0.98); case .camera: return .accent; case .sound: return Color(red: 0.35, green: 0.73, blue: 0.91); case .learning: return Color(red: 0.96, green: 0.66, blue: 0.36) } }
    var question: String { switch self {
    case .story: return "下一镜新增了什么信息？为什么在这里切？"
    case .camera: return "景别、机位、构图或运动，如何引导注意力？"
    case .sound: return "先听音轨：声音从何时进入，又把注意力带向哪里？"
    case .learning: return "换一个角色和场景，这个方法还能怎样使用？"
    } }
}
struct StudioButton: View {
    let title: String; let icon: String; var accent = false; var compact = false; let action: () -> Void
    var body: some View {
        Button { NSApp?.keyWindow?.makeFirstResponder(nil); action() } label: { Label(title, systemImage: icon).font(.system(size: compact ? 12 : 13, weight: .medium)).padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 7 : 9).foregroundStyle(accent ? Color.studioBG : Color.white.opacity(0.88)).background(accent ? Color.accent : Color.elevated, in: RoundedRectangle(cornerRadius: 7)) }
            .buttonStyle(.plain)
    }
}
struct IconButton: View {
    let icon: String; let help: String; var active = false; let action: () -> Void
    var body: some View { Button { NSApp?.keyWindow?.makeFirstResponder(nil); action() } label: { Image(systemName: icon).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 30).foregroundStyle(active ? Color.accent : Color.white.opacity(0.8)).background(active ? Color.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain).help(help).accessibilityLabel(help) }
}
struct StudioRoot: View {
    @EnvironmentObject var model: StudioModel
    @EnvironmentObject var scripts: ScriptWorkspaceModel
    @EnvironmentObject var subtitles: SubtitleWorkspaceModel
    @AppStorage("studyWorkspaceLayout") private var workspaceLayout = StudyWorkspaceLayout.picture
    @AppStorage("workspaceLibraryVisible") private var showLibrary = true
    @JingduState private var showNotes = false
    var body: some View {
        HStack(spacing: 0) {
            if showLibrary {
                LibrarySidebar().frame(width: 206)
                Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            }
            VStack(spacing: 0) {
                topBar
                if model.project != nil {
                    ReadingWorkspace(layout: workspaceLayout, showsReader: scripts.showReader || model.showSubtitleReader, showsNotes: showNotes,
                                     onClose: { scripts.showReader = false; model.showSubtitleReader = false })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    TimelinePanel().frame(height: 356)
                } else { EmptyWorkspace() }
                statusBar
            }
        }
        .background(Color.studioBG).foregroundStyle(.white).preferredColorScheme(.dark)
        .frame(minWidth: 1180, minHeight: 810)
        .onAppear { model.installShortcuts(); scripts.projectDidOpen(studio: model) }
        .onChange(of: model.selectedID) { _, _ in scripts.projectDidOpen(studio: model); showNotes = false; model.selectedSubtitleID = nil }
        .onChange(of: model.showSubtitleReader) { _, value in if value { scripts.showReader = false; showNotes = false } }
        .onChange(of: model.mediaAvailable) { _, _ in scripts.resumeAutomaticGeneration(studio: model) }
        .onChange(of: model.busy) { _, _ in scripts.resumeAutomaticGeneration(studio: model) }
        .onChange(of: scripts.isRunning) { _, _ in scripts.resumeAutomaticGeneration(studio: model) }
        .onChange(of: scripts.isFetchingModels) { _, _ in scripts.resumeAutomaticGeneration(studio: model) }
        .onChange(of: scripts.showWorkspace) { _, _ in scripts.resumeAutomaticGeneration(studio: model) }
        .onChange(of: scripts.autoGenerateOnOpen) { _, _ in scripts.automaticGenerationPreferenceChanged(studio: model) }
        .onChange(of: model.selectedNoteID) { _, id in if id != nil { scripts.showReader = false; model.showSubtitleReader = false; showNotes = true } }
        .onChange(of: model.selectedClipID) { _, id in if id != nil { scripts.showReader = false; model.showSubtitleReader = false; showNotes = true } }
        .onChange(of: model.selectedMusicID) { _, id in if id != nil { scripts.showReader = false; model.showSubtitleReader = false; showNotes = true } }
        .onChange(of: scripts.outputFocusID) { _, id in if id != nil {
            if model.showSubtitleReader { scripts.showReader = false }
            else { scripts.showReader = true; showNotes = false }
        } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in subtitles.cancel(); model.flush() }
        .sheet(isPresented: $model.showHelp) { HelpSheet() }
        .sheet(isPresented: $model.showAnalysis) { AnalysisSheet() }
        .sheet(isPresented: $model.showImportOptions) { BatchImportSheet() }
        .sheet(isPresented: $model.showRename) { RenameProjectSheet() }
        .sheet(isPresented: $model.showCapture) { CaptureSheet() }
        .sheet(isPresented: $scripts.showWorkspace) { ScriptWorkspaceSheet() }
        .sheet(isPresented: $subtitles.showGeneration) { SubtitleGenerationSheet() }
        .alert("字幕导出未完成", isPresented: Binding(get: { subtitles.exportError != nil }, set: { if !$0 { subtitles.exportError = nil } })) {
            Button("知道了") { subtitles.exportError = nil }
        } message: { Text(subtitles.exportError ?? "") }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
        .alert("移出作品库？", isPresented: $model.showDeleteProject) { Button("取消", role: .cancel) {}; Button("移出", role: .destructive) { model.deleteProject() } } message: { Text("原视频不会删除。该作品的镜头和笔记会从作品库移除，建议先导出项目备份。") }
    }
    private var topBar: some View {
        HStack(spacing: 12) {
            IconButton(icon: "sidebar.left", help: "显示或收起作品库", active: showLibrary) { showLibrary.toggle() }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) { Text(model.project?.title ?? "拉片工作台").font(.system(size: 16, weight: .semibold)).lineLimit(1); if model.project != nil { IconButton(icon: "pencil", help: "重命名项目，不修改原视频") { model.requestRename() } } }
                if let item = model.project { Text("\(item.width) × \(item.height)   ·   \(String(format: "%.2f", item.frameRate)) fps   ·   \(timecode(item.duration, frameRate: item.frameRate))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.mutedText) }
                else { Text("收藏好作品，拆开看懂它").font(.system(size: 12)).foregroundStyle(Color.mutedText) }
            }
            Spacer(minLength: 10)
            if model.project != nil {
                Button { model.dismissTextFocus(); model.showSubtitleReader = false; scripts.showReader.toggle(); showNotes = false } label: {
                    Label("脚本", systemImage: "doc.text").font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                        .foregroundStyle(scripts.showReader ? Color.accent : Color.white.opacity(0.8))
                        .background(scripts.showReader ? Color.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help("展开或收起脚本预览区 ⌘J")
                Button { model.dismissTextFocus(); model.showSubtitleReader.toggle(); showNotes = false } label: {
                    Label("字幕", systemImage: "captions.bubble").font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                        .foregroundStyle(model.showSubtitleReader ? Color.accent : Color.white.opacity(0.8))
                        .background(model.showSubtitleReader ? Color.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help("展开或收起独立字幕预览区")
                Menu {
                    ForEach(StudyWorkspaceLayout.allCases) { layout in
                        Button { workspaceLayout = layout; if !model.showSubtitleReader { scripts.showReader = true }; showNotes = false } label: {
                            Label(layout.title, systemImage: workspaceLayout == layout ? "checkmark" : layout.icon)
                        }
                    }
                    Divider()
                    Toggle("相邻镜头对照", isOn: $model.showContact)
                } label: { Label(workspaceLayout.title, systemImage: workspaceLayout.icon).font(.system(size: 12)) }
                    .menuStyle(.borderlessButton).fixedSize().help("选择工作区布局")
                IconButton(icon: "square.and.pencil", help: "显示或收起镜头笔记", active: showNotes && !scripts.showReader) {
                    showNotes = !showNotes || scripts.showReader || model.showSubtitleReader; scripts.showReader = false; model.showSubtitleReader = false
                }
                IconButton(icon: "square.stack.3d.up", help: "收集片段到灵感空间") { model.requestCapture() }
                Menu { Button("追加视频到当前时间轴…") { model.appendVideos() }; Button("导入音乐或音效…") { model.importMusic() } } label: { Label("添加", systemImage: "plus.circle").font(.system(size: 13)) }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                Menu { Button("导出混剪视频（含音乐）…") { model.exportMovie() }; Divider(); Button("导出拉片笔记（Markdown）") { model.export("md") }; Button("导出项目备份（JSON）") { model.export("json") }; Button("导出模型分析提问") { model.export("prompt") }; Divider(); Button("保存当前关键帧") { model.saveFrame() } } label: { Label("导出", systemImage: "square.and.arrow.up").font(.system(size: 13)).padding(8) }.menuStyle(.borderlessButton).fixedSize()
            }
            StudioButton(title: "导入视频", icon: "plus", accent: true) { model.openVideo() }.disabled(model.busy)
        }.padding(.horizontal, 22).padding(.vertical, 16).background(Color.panel)
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(model.busy ? Color.orange : Color.accent).frame(width: 5, height: 5)
            Text(model.toast ?? (model.busy ? model.busyLabel : "本地工作区 · 笔记自动保存")).font(.system(size: 11)).foregroundStyle(Color.mutedText).lineLimit(1)
            Spacer()
            Text("空格 播放   C 镜头反馈   S 声音反馈   Esc 退出输入").font(.system(size: 11)).foregroundStyle(Color.mutedText)
            Button { model.showHelp = true } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.plain).help("快捷键与拉片方法")
        }.padding(.horizontal, 18).frame(height: 29).background(Color.panel)
    }
}
struct LibrarySidebar: View {
    @EnvironmentObject var model: StudioModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack { RoundedRectangle(cornerRadius: 8).fill(Color.accent).frame(width: 32, height: 32); Image(systemName: "viewfinder").font(.system(size: 21, weight: .semibold)).foregroundStyle(Color.studioBG) }
                VStack(alignment: .leading, spacing: 2) { Text("镜读").font(.system(size: 21, weight: .bold)); Text("FRAME STUDY").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.6).foregroundStyle(Color.mutedText) }
            }.padding(22).padding(.bottom, 5)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.mutedText)
                TextField("查找作品", text: $model.searchText).textFieldStyle(.plain).focused($searchFocused).onSubmit { searchFocused = false; model.dismissTextFocus() }.onExitCommand { searchFocused = false; model.dismissTextFocus() }
                if !model.searchText.isEmpty { Button { model.searchText = ""; searchFocused = false; model.dismissTextFocus() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.mutedText) }.buttonStyle(.plain).help("清空搜索并退出输入") }
            }.font(.system(size: 12)).padding(9).background(Color.elevated, in: RoundedRectangle(cornerRadius: 6)).padding(14)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    section("作品库", icon: "square.stack", kind: .study)
                    section("灵感空间", icon: "square.stack.3d.up", kind: .remix)
                    if model.visibleProjects.isEmpty && !model.searchText.isEmpty { Text("没有找到作品").font(.system(size: 12)).foregroundStyle(Color.mutedText).padding(14) }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 14) {
                Button { model.importProject() } label: { Label("导入项目备份", systemImage: "square.and.arrow.down").font(.system(size: 12)) }.buttonStyle(.plain)
                Button { model.dismissTextFocus(); model.showHelp = true } label: { Label("拉片方法与快捷键", systemImage: "book.closed").font(.system(size: 12)) }.buttonStyle(.plain)
                HStack { Image(systemName: "internaldrive"); Text("视频与笔记留在本机") }.font(.system(size: 11)).foregroundStyle(Color.mutedText).padding(.top, 7)
            }.foregroundStyle(.white.opacity(0.72)).padding(18)
        }.background(Color.panel).onChange(of: model.focusReset) { _, _ in searchFocused = false }
    }
    private func section(_ title: String, icon: String, kind: ProjectKind) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)); Spacer(); Text("\(model.projects.filter {$0.kind == kind}.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.mutedText) }.padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 7)
            ForEach(model.visibleProjects.filter {$0.kind == kind}) { project in
                Button { searchFocused = false; model.select(project.id) } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top, spacing: 9) { Image(systemName: kind == .remix ? "square.stack.3d.up" : "film").font(.system(size: 14)).foregroundStyle(model.selectedID == project.id ? Color.accent : Color.mutedText); Text(project.title).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading); Spacer(minLength: 0) }
                        Text(kind == .remix ? "\(project.videoClips.count) 片段 · \(project.music.count) 段音乐" : "\(project.shots.count) 镜头 · \(project.notes.count) 标记").font(.system(size: 11)).foregroundStyle(Color.mutedText).padding(.leading, 23)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(model.selectedID == project.id ? Color.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(model.selectedID == project.id ? Color.accent.opacity(0.25) : Color.clear, lineWidth: 1))
                }.buttonStyle(.plain).contextMenu { Button("打开") { model.select(project.id) }; Button("重命名项目…") { model.requestRename(project.id) }; Button("在 Finder 中显示原视频") { NSWorkspace.shared.activateFileViewerSelecting(project.videoClips.map {URL(fileURLWithPath: $0.sourcePath)}) }; Divider(); Button("移出作品库", role: .destructive) { model.select(project.id); model.showDeleteProject = true } }
            }
            if !model.projects.contains(where: {$0.kind == kind}) {
                Text(kind == .remix ? "在作品中点击“收集片段”\n把不同项目的灵感放到一起" : "导入一段或多段收藏视频").font(.system(size: 11)).lineSpacing(5).foregroundStyle(Color.mutedText).padding(.horizontal, 8).padding(.bottom, 14)
            }
        }
    }
}
struct EmptyWorkspace: View {
    @EnvironmentObject var model: StudioModel
    @JingduState<Bool> private var isTargeted = false
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            HStack(spacing: 5) { ForEach(0..<9) { n in RoundedRectangle(cornerRadius: 3).fill(n == 4 ? Color.accent : Color.white.opacity(0.12)).frame(width: n == 4 ? 68 : 30, height: 6) } }
            VStack(spacing: 12) { Text("好作品，值得逐帧读。").font(.system(size: 30, weight: .semibold)); Text("从一个镜头的停顿，到一段声音的先入。\n把看见的细节，变成下次创作能用的方法。").font(.system(size: 15)).lineSpacing(6).foregroundStyle(Color.mutedText).multilineTextAlignment(.center) }
            VStack(spacing: 15) {
                Image(systemName: "film.stack").font(.system(size: 32, weight: .light)).foregroundStyle(Color.accent)
                Text("将视频拖到这里").font(.system(size: 16, weight: .medium))
                Text("支持系统可播放的 MP4、MOV 等视频").font(.system(size: 12)).foregroundStyle(Color.mutedText)
                StudioButton(title: "选择本地视频", icon: "plus", accent: true) { model.openVideo() }
            }.frame(width: 460, height: 225).background(isTargeted ? Color.accent.opacity(0.07) : Color.panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accent.opacity(isTargeted ? 0.7 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard !providers.isEmpty else { return false }
                Task {
                    var urls: [URL] = []
                    for provider in providers {
                        let url: URL? = await withCheckedContinuation { continuation in
                            _ = provider.loadObject(ofClass: URL.self) { value, _ in continuation.resume(returning: value) }
                        }
                        if let url { urls.append(url) }
                    }
                    model.acceptDroppedVideos(urls)
                }
                return true
            }
            HStack(spacing: 32) { Label("逐帧查看", systemImage: "forward.frame"); Label("多轨标记", systemImage: "bookmark"); Label("镜头对照", systemImage: "rectangle.split.3x1") }.font(.system(size: 12)).foregroundStyle(Color.mutedText)
            Spacer(); Text("无需上传视频，无需模型密钥").font(.system(size: 11)).foregroundStyle(Color.mutedText).padding(.bottom, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
final class FocusPlayerView: AVPlayerView {
    var clearFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) { clearFocus?(); super.mouseDown(with: event) }
}
struct NativePlayer: NSViewRepresentable {
    @EnvironmentObject var model: StudioModel
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let view = FocusPlayerView(); view.clearFocus = { model.dismissTextFocus() }; view.player = player; view.controlsStyle = .none; view.videoGravity = .resizeAspect; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}
struct PlayerWorkspace: View {
    @EnvironmentObject var model: StudioModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.project?.kind == .remix ? "混剪预览" : "视频预览").font(.system(size: 12, weight: .semibold)); Text("/  TIMELINE").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.mutedText)
                Spacer()
                if let shot = model.selectedShot { Text(String(format: "SHOT %02d", shot.index + 1)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color.accent).padding(.horizontal, 9).padding(.vertical, 5).background(Color.accent.opacity(0.09), in: Capsule()) }
            }.padding(.horizontal, 22).padding(.vertical, 14)
            ZStack {
                Color.black
                if model.mediaAvailable { NativePlayer(player: model.player) }
                else if model.playbackLoading { ProgressView("正在准备视频与音乐…").tint(Color.accent) }
                else { VStack(spacing: 14) { Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 30)).foregroundStyle(Color.mutedText); Text("原视频已移动或暂时不可用").font(.system(size: 14)); StudioButton(title: "重新定位视频", icon: "folder") { model.relink() } } }
                if model.busy { VStack(spacing: 12) { ProgressView(value: model.progress).tint(Color.accent).frame(width: 220); Text(model.busyLabel).font(.system(size: 13)); Button("取消") { model.cancelAnalysis() }.buttonStyle(.plain).foregroundStyle(Color.mutedText) }.padding(24).background(Color.panel.opacity(0.97), in: RoundedRectangle(cornerRadius: 12)) }
            }.overlay(alignment: .bottom) { SubtitleOverlay() }.clipShape(RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 20).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 5) {
                IconButton(icon: "backward.end", help: "上一个镜头 ⇧←") { model.jumpShot(-1) }
                IconButton(icon: "backward.frame", help: "上一帧 ←") { model.step(-1) }
                Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 17)).foregroundStyle(Color.studioBG).frame(width: 42, height: 34).background(Color.accent, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).help("播放 / 暂停 空格")
                IconButton(icon: "forward.frame", help: "下一帧 →") { model.step(1) }
                IconButton(icon: "forward.end", help: "下一个镜头 ⇧→") { model.jumpShot(1) }
                Text(timecode(model.currentTime, frameRate: model.project?.frameRate ?? 30)).font(.system(size: 13, weight: .medium, design: .monospaced)).padding(.leading, 7)
                Spacer(minLength: 2)
                Menu { ForEach([Float(0.25), 0.5, 0.75, 1, 1.5, 2], id: \.self) { rate in Button("\(String(format: "%g", rate))×") { model.rate = rate; if model.isPlaying { model.player.playImmediately(atRate: rate) } } } } label: { Text("\(String(format: "%g", model.rate))×").font(.system(size: 12, design: .monospaced)) }.menuStyle(.borderlessButton).frame(width: 44)
                IconButton(icon: "repeat.1", help: "循环当前镜头 L", active: model.loopShot) { model.loopShot.toggle(); if model.loopShot, let shot = model.selectedShot { model.seek(shot.start, follow: false) } }
                IconButton(icon: model.muted ? "speaker.slash" : "speaker.wave.2", help: "静音", active: model.muted) { model.muted.toggle(); model.player.isMuted = model.muted }
                IconButton(icon: "camera", help: "保存当前关键帧") { model.saveFrame() }
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }
    }
}
struct ContextStrip: View {
    @EnvironmentObject var model: StudioModel
    var body: some View {
        HStack(spacing: 10) {
            ForEach([-1, 0, 1], id: \.self) { offset in
                let i = model.selectedShotIndex + offset
                if model.shots.indices.contains(i) { let shot = model.shots[i]
                    Button { model.chooseShot(i) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            // Clipping crops the image visually, but does not constrain hit testing.
                            // Keep oversized thumbnails from intercepting the transport controls above.
                            ZStack { Color.elevated; if let image = model.thumbnails[i] { Image(nsImage: image).resizable().scaledToFill() } }.frame(height: 67).clipped().clipShape(RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
                            HStack { Text(offset == -1 ? "前一镜" : offset == 0 ? "当前镜头" : "后一镜"); Spacer(); Text(String(format: "%.2fs", shot.duration)).monospacedDigit() }.font(.system(size: 10)).foregroundStyle(offset == 0 ? Color.accent : Color.mutedText)
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else { Color.clear.frame(maxWidth: .infinity).frame(height: 90) }
            }
        }.padding(.horizontal, 20).padding(.bottom, 13)
    }
}
struct InspectorPanel: View {
    @EnvironmentObject var model: StudioModel
    @FocusState private var focusBody: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(model.selectedMusic != nil ? "音乐剪辑" : model.selectedClip != nil ? "素材详情" : model.selectedNote != nil ? "编辑标记" : "镜头笔记").font(.system(size: 14, weight: .semibold)); Spacer(); if model.selectedNote != nil || model.selectedClip != nil || model.selectedMusic != nil { IconButton(icon: "xmark", help: "返回镜头笔记") { model.selectedNoteID = nil; model.selectedClipID = nil; model.selectedMusicID = nil } } }.padding(.horizontal, 18).frame(height: 48)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if let music = model.selectedMusic { MusicInspector(music: music).id(music.id) }
                    else if let clip = model.selectedClip { VideoClipInspector(clip: clip).id(clip.id) }
                    else if let note = model.selectedNote { noteEditor(note) }
                    else { shotOverview }
                }.padding(18).padding(.top, 0)
            }
        }.background(Color.panel)
        .onChange(of: model.newNoteFocusID) { _, id in if id == model.selectedNoteID { Task { await Task.yield(); focusBody = true } } }
        .onChange(of: model.focusReset) { _, _ in focusBody = false }
    }
    private var shotOverview: some View {
        VStack(alignment: .leading, spacing: 17) {
            if let shot = model.selectedShot {
                HStack(alignment: .firstTextBaseline) { Text(String(format: "%02d", shot.index + 1)).font(.system(size: 40, weight: .light, design: .monospaced)); Spacer(); Text(String(format: "%.2f 秒", shot.duration)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.mutedText) }
                Text("\(timecode(shot.start, frameRate: model.project?.frameRate ?? 30))  →  \(timecode(shot.end, frameRate: model.project?.frameRate ?? 30))").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.mutedText)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                Text("从一个问题开始").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mutedText)
                ForEach(NoteTrack.allCases) { track in
                    Button { model.addNote(track: track, start: shot.start, end: shot.end) } label: {
                        VStack(alignment: .leading, spacing: 8) { HStack { Image(systemName: track.symbol); Text(track.title).fontWeight(.medium); Spacer(); Image(systemName: "plus").font(.system(size: 11)) }.font(.system(size: 12)).foregroundStyle(track.color); Text(track.question).font(.system(size: 12)).lineSpacing(4).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true) }.padding(12).background(track.color.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                let notes = model.project?.notes.filter { $0.start < shot.end && ($0.end > shot.start || $0.start >= shot.start) } ?? []
                if !notes.isEmpty {
                    HStack { Text("此镜头的标记"); Spacer(); Text("\(notes.count)") }.font(.system(size: 12)).foregroundStyle(Color.mutedText).padding(.top, 6)
                    ForEach(notes.sorted(by: {$0.start < $1.start})) { note in
                        Button { model.selectNote(note) } label: { HStack(alignment: .top, spacing: 8) { Circle().fill(note.track.color).frame(width: 5, height: 5).padding(.top, 5); VStack(alignment: .leading, spacing: 4) { Text(note.displayTitle).font(.system(size: 12)).lineLimit(2); Text(timecode(note.start)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.mutedText) }; Spacer() }.padding(.vertical, 5) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private func noteEditor(_ note: StudyNote) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            NotePreviewCard(note: note)
            Picker("标记轨道", selection: Binding(get: { model.selectedNote?.track ?? .camera }, set: { value in model.editNote { $0.track = value }; model.activeTrack = value })) { ForEach(NoteTrack.allCases) { track in Text(track.title).tag(track) } }.labelsHidden()
            TextField("给这个发现起个名字", text: Binding(get: { model.selectedNote?.title ?? "" }, set: { value in model.editNote {$0.title = value} })).textFieldStyle(.plain).font(.system(size: 17, weight: .semibold)).padding(.vertical, 6)
            HStack { timeField("起点", value: note.start, isStart: true); Image(systemName: "arrow.right").foregroundStyle(Color.mutedText); timeField("终点", value: note.end, isStart: false) }
            HStack { Button("起点设为当前帧") { model.editNote { $0.start = min(model.currentTime, $0.end) } }; Spacer(); Button("终点设为当前帧") { model.editNote { $0.end = max(model.currentTime, $0.start) } } }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(note.track.color)
            editor(label: "我观察到的", placeholder: "记下画面或听到的声音，以及前后变化…", value: Binding(get: { model.selectedNote?.body ?? "" }, set: { value in model.editNote {$0.body = value} }), height: 115, autofocus: true)
            editor(label: "原理与可复用方法", placeholder: "为什么有效？下次在什么情况下可以用？", value: Binding(get: { model.selectedNote?.takeaway ?? "" }, set: { value in model.editNote {$0.takeaway = value} }), height: 100)
            Text("把观察与解释分开。声音设计需要实际聆听，画面和波形不能代替听感。").font(.system(size: 11)).lineSpacing(4).foregroundStyle(Color.mutedText)
            StudioButton(title: "提取到灵感空间", icon: "square.stack.3d.up", compact: true) { model.requestCapture() }
            HStack { StudioButton(title: "回看这一段", icon: "play", compact: true) { model.playNote(note) }; Spacer(); IconButton(icon: "trash", help: "删除标记，可撤销") { model.removeNote() } }
        }
    }
    private func timeField(_ label: String, value: Double, isStart: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label + "（秒）").font(.system(size: 10)).foregroundStyle(Color.mutedText); TextField(label, value: Binding(get: { isStart ? (model.selectedNote?.start ?? 0) : (model.selectedNote?.end ?? 0) }, set: { input in guard input.isFinite else { return }; let duration = model.project?.duration ?? 0; model.editNote { if isStart { $0.start = min(max(0, input), $0.end) } else { $0.end = min(duration, max(input, $0.start)) } } }), format: .number.precision(.fractionLength(3))).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)) }
    }
    private func editor(label: String, placeholder: String, value: Binding<String>, height: CGFloat, autofocus: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mutedText); ZStack(alignment: .topLeading) { if value.wrappedValue.isEmpty { Text(placeholder).font(.system(size: 12)).foregroundStyle(Color.mutedText.opacity(0.65)).padding(9).allowsHitTesting(false) }; Group { if autofocus { TextEditor(text: value).focused($focusBody) } else { TextEditor(text: value) } }.font(.system(size: 13)).scrollContentBackground(.hidden).padding(4) }.frame(height: height).background(Color.studioBG, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.06))) }
    }
}
