import SwiftUI

struct BatchImportSheet: View {
    @EnvironmentObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 6) { Text("这 \(model.importURLs.count) 段视频，如何整理？").font(.system(size: 22, weight: .semibold)); Text("可以调整下方顺序，再选择导入方式。").font(.system(size: 13)).foregroundStyle(Color.mutedText) }; Spacer(); Button("取消") { model.showImportOptions = false; model.importURLs = [] }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(Array(model.importURLs.enumerated()), id: \.offset) { index, url in
                        HStack(spacing: 10) { Text(String(format: "%02d", index + 1)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.accent); Text(url.lastPathComponent).font(.system(size: 13)).lineLimit(1); Spacer(); IconButton(icon: "arrow.up", help: "将素材前移") { model.importURLs.swapAt(index, index - 1) }.disabled(index == 0); IconButton(icon: "arrow.down", help: "将素材后移") { model.importURLs.swapAt(index, index + 1) }.disabled(index == model.importURLs.count - 1) }.padding(7).background(Color.elevated, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }.frame(maxHeight: 220)
            choice("合并到同一新项目", description: "按上方顺序连接，使用一条视频时间轴进行拉片。", icon: "rectangle.split.3x1", mode: .combined)
            choice("分别创建独立项目", description: "每段视频一个项目，单独保存镜头与笔记。", icon: "square.stack", mode: .separate)
            if let project = model.project { choice("追加到「\(project.title)」", description: "把这批素材接在当前时间轴末尾，已有标记保留。", icon: "plus.rectangle.on.rectangle", mode: .append) }
        }.padding(28).frame(width: 585).background(Color.panel)
    }
    private func choice(_ title: String, description: String, icon: String, mode: BatchImportMode) -> some View {
        Button { model.performImport(mode) } label: { HStack(spacing: 16) { Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Color.accent).frame(width: 28); VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1); Text(description).font(.system(size: 12)).foregroundStyle(Color.mutedText) }; Spacer(); Image(systemName: "arrow.right").foregroundStyle(Color.mutedText) }.padding(17).background(Color.elevated, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
    }
}
struct RenameProjectSheet: View {
    @EnvironmentObject var model: StudioModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重命名项目").font(.system(size: 22, weight: .semibold))
            TextField("项目名称", text: $model.renameDraft).textFieldStyle(.roundedBorder).font(.system(size: 15)).focused($focused).onSubmit { if valid { model.applyRename() } }
            Text("名称只用于镜读作品库，原视频文件名保持不变。").font(.system(size: 12)).foregroundStyle(Color.mutedText)
            HStack { Button("取消") { model.showRename = false }.keyboardShortcut(.cancelAction); Spacer(); StudioButton(title: "保存名称", icon: "checkmark", accent: true) { model.applyRename() }.disabled(!valid) }
        }.padding(28).frame(width: 460).background(Color.panel).onAppear { focused = true }
    }
    private var valid: Bool { !model.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.renameDraft.count <= 500 }
}
struct CaptureSheet: View {
    @EnvironmentObject var model: StudioModel
    @JingduState<NSImage?> private var preview: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("收集到灵感空间").font(.system(size: 22, weight: .semibold)); Spacer(); Button("取消") { model.showCapture = false }.keyboardShortcut(.cancelAction) }
            HStack(alignment: .top, spacing: 20) {
                ZStack { Color.studioBG; if let preview { Image(nsImage: preview).resizable().scaledToFit() } else { Image(systemName: "film").foregroundStyle(Color.mutedText) } }.frame(width: 210, height: 128).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 14) {
                    TextField("片段名称", text: $model.captureTitle).textFieldStyle(.roundedBorder)
                    HStack { NumericInput(title: "项目起点（秒）", value: $model.captureStart); NumericInput(title: "项目终点（秒）", value: $model.captureEnd) }
                    Text("选中 \(String(format: "%.2f", max(0, model.captureEnd - model.captureStart))) 秒 · 将保留片段的源项目与原视频位置").font(.system(size: 11)).foregroundStyle(Color.mutedText)
                }
            }
            Picker("放到哪里", selection: $model.captureTargetID) {
                Text("创建全新的灵感空间").tag(Optional<UUID>.none)
                ForEach(model.remixSpaces.filter {$0.id != model.selectedID}) { space in Text(space.title).tag(Optional(space.id)) }
            }
            if model.captureTargetID == nil { TextField("新空间名称", text: $model.newSpaceTitle).textFieldStyle(.roundedBorder) }
            Text("在灵感空间中可排列不同项目的片段、裁剪起终点、添加音乐，并导出混剪视频。原项目也会出现对应的收集标记。").font(.system(size: 13)).foregroundStyle(Color.mutedText).lineSpacing(5)
            HStack { Spacer(); StudioButton(title: "收集并打开空间", icon: "square.stack.3d.up", accent: true) { model.captureToSpace() }.disabled(!valid) }
        }.padding(28).frame(width: 640).background(Color.panel)
        .task(id: model.captureStart) { if let project = model.project { preview = await model.sourceFrame(project, at: model.captureStart) } }
    }
    private var valid: Bool { model.captureStart.isFinite && model.captureEnd.isFinite && model.captureStart >= 0 && model.captureEnd > model.captureStart && model.captureEnd <= (model.project?.duration ?? 0) && (model.captureTargetID != nil || !model.newSpaceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && model.newSpaceTitle.count <= 500 }
}
struct NotePreviewCard: View {
    @EnvironmentObject var model: StudioModel
    let note: StudyNote
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Color.studioBG
                if let image = model.notePreview { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: "film").font(.system(size: 24)).foregroundStyle(Color.mutedText).frame(maxWidth: .infinity, maxHeight: .infinity) }
                Text(timecode(note.start, frameRate: model.project?.frameRate ?? 30)).font(.system(size: 10, design: .monospaced)).padding(5).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(6)
            }.frame(height: 122).clipShape(RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 6) { Image(systemName: note.hasContent ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(note.track.color); Text(note.hasContent ? "已记录 · 自动保存" : "标记已创建 · 添加观察内容").foregroundStyle(Color.mutedText) }.font(.system(size: 11))
            Text(note.displayTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(note.track.color).lineLimit(2)
        }
    }
}
struct NumericInput: View {
    let title: String
    @Binding var value: Double
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 11)).foregroundStyle(Color.mutedText); TextField(title, value: $value, format: .number.precision(.fractionLength(3))).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced)) } }
}
struct VideoClipInspector: View {
    @EnvironmentObject var model: StudioModel
    let clip: VideoClip
    @JingduState<Double> private var sourceIn = 0.0
    @JingduState<Double> private var sourceOut = 0.0
    @JingduState<Double> private var originalVolume = 1.0
    @JingduState<NSImage?> private var preview: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            ZStack { Color.studioBG; if let preview { Image(nsImage: preview).resizable().scaledToFit() } }.frame(height: 135).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(clip.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let source = clip.sourceProjectTitle { Label("来自：\(source)", systemImage: "arrow.turn.down.right").font(.system(size: 12)).foregroundStyle(Color.accent).fixedSize(horizontal: false, vertical: true) }
            Text(URL(fileURLWithPath: clip.sourcePath).lastPathComponent).font(.system(size: 11)).foregroundStyle(Color.mutedText).lineLimit(2)
            Text("原视频 \(String(format: "%.2f", clip.sourceDuration)) 秒 · 当前片段 \(String(format: "%.2f", clip.duration)) 秒").font(.system(size: 11)).foregroundStyle(Color.mutedText)
            HStack { NumericInput(title: "源入点（秒）", value: $sourceIn); NumericInput(title: "源出点（秒）", value: $sourceOut) }
            StudioButton(title: "应用片段裁剪", icon: "crop", compact: true) { model.trimVideoClip(clip.id, sourceIn: sourceIn, sourceOut: sourceOut) }.disabled(!valid)
            Text("镜头与笔记会跟随其原画面调整，原视频文件不会改写。").font(.system(size: 11)).foregroundStyle(Color.mutedText).lineSpacing(4)
            HStack { StudioButton(title: "前移", icon: "arrow.left", compact: true) { model.moveVideoClip(clip.id, delta: -1) }.disabled(model.project?.videoClips.first?.id == clip.id); StudioButton(title: "后移", icon: "arrow.right", compact: true) { model.moveVideoClip(clip.id, delta: 1) }.disabled(model.project?.videoClips.last?.id == clip.id) }
            Divider()
            HStack { Text("项目原声音量").font(.system(size: 12)); Spacer(); Text("\(Int(originalVolume * 100))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.mutedText) }
            Slider(value: $originalVolume, in: 0...1) { editing in if !editing { model.setOriginalVolume(originalVolume) } }.tint(Color.accent)
            StudioButton(title: "重新定位原视频", icon: "folder", compact: true) { model.relink() }
            Button(role: .destructive) { model.removeVideoClip(clip.id) } label: { Label("移除此片段", systemImage: "trash").font(.system(size: 12)) }.buttonStyle(.plain).disabled((model.project?.videoClips.count ?? 0) <= 1)
        }.onAppear { sync() }.onChange(of: clip) { _, _ in sync() }
        .task(id: clip.sourcePath + String(clip.sourceIn)) { preview = await MediaAnalyzer.thumbnail(URL(fileURLWithPath: clip.sourcePath), at: clip.sourceIn, width: 360) }
    }
    private var valid: Bool { sourceIn.isFinite && sourceOut.isFinite && sourceIn >= 0 && sourceOut > sourceIn && sourceOut <= clip.sourceDuration }
    private func sync() { sourceIn = clip.sourceIn; sourceOut = clip.sourceOut; originalVolume = model.project?.originalVolume ?? 1 }
}
struct MusicInspector: View {
    @EnvironmentObject var model: StudioModel
    let music: MusicClip
    @JingduState<Double> private var sourceIn = 0.0
    @JingduState<Double> private var sourceOut = 0.0
    @JingduState<Double> private var timelineStart = 0.0
    @JingduState<Double> private var volume = 0.8
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack { RoundedRectangle(cornerRadius: 9).fill(NoteTrack.sound.color.opacity(0.08)); Image(systemName: "waveform").font(.system(size: 44, weight: .light)).foregroundStyle(NoteTrack.sound.color) }.frame(height: 83)
            Text(music.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text("原音频 \(String(format: "%.2f", music.sourceDuration)) 秒 · 已选 \(String(format: "%.2f", music.duration)) 秒").font(.system(size: 11)).foregroundStyle(Color.mutedText)
            HStack { NumericInput(title: "源入点（秒）", value: $sourceIn); NumericInput(title: "源出点（秒）", value: $sourceOut) }
            NumericInput(title: "放在时间轴（秒）", value: $timelineStart)
            HStack { Text("音乐音量").font(.system(size: 12)); Spacer(); Text("\(Int(volume * 100))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.mutedText) }
            Slider(value: $volume, in: 0...1).tint(NoteTrack.sound.color)
            StudioButton(title: "应用音乐剪辑", icon: "checkmark", accent: true, compact: true) { model.editMusic(music.id, sourceIn: sourceIn, sourceOut: sourceOut, timelineStart: timelineStart, volume: volume) }.disabled(!valid)
            Text(valid ? "音乐会与视频同步播放和导出。也可以在音乐轨直接拖动片段位置。" : "起终点需要在源音频内，片段放置后不能超出项目时长。").font(.system(size: 11)).foregroundStyle(valid ? Color.mutedText : Color.orange).lineSpacing(4)
            Divider()
            StudioButton(title: "在播放头拆分音乐", icon: "scissors", compact: true) { model.splitSelectedMusic() }
            Button(role: .destructive) { model.removeSelectedMusic() } label: { Label("移除这段音乐", systemImage: "trash").font(.system(size: 12)) }.buttonStyle(.plain)
        }.onAppear { sync() }.onChange(of: music) { _, _ in sync() }
    }
    private var valid: Bool { sourceIn.isFinite && sourceOut.isFinite && timelineStart.isFinite && sourceIn >= 0 && sourceOut > sourceIn && sourceOut <= music.sourceDuration && timelineStart >= 0 && timelineStart + sourceOut - sourceIn <= (model.project?.duration ?? 0) + 0.000001 }
    private func sync() { sourceIn = music.sourceIn; sourceOut = music.sourceOut; timelineStart = music.timelineStart; volume = music.volume }
}
