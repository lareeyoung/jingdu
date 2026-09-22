import SwiftUI

struct SubtitleSidebarPanel: View {
    @EnvironmentObject var studio: StudioModel
    @EnvironmentObject var subtitles: SubtitleWorkspaceModel
    @EnvironmentObject var scripts: ScriptWorkspaceModel
    @AppStorage("subtitleReaderLinked") private var linked = true
    @AppStorage("subtitleOverlayVisible") private var overlayVisible = true
    @JingduState private var editingCue: SubtitleCue?
    @JingduState private var showSource = false
    let onClose: () -> Void
    private var track: SubtitleTrack? { studio.currentSubtitleTrack }
    private var currentID: UUID? { linked ? track?.activeCue(at: studio.currentTime)?.id : nil }
    private var isThisTask: Bool { subtitles.taskProjectID == studio.selectedID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("字幕").font(.system(size: 13, weight: .semibold))
                if let track { Text("\(track.cues.count) 句").font(.system(size: 10)).foregroundStyle(Color.mutedText) }
                Spacer()
                Menu {
                    Button("重新生成字幕…") { subtitles.showGeneration = true }.disabled(subtitles.isRunning)
                    Toggle("在画面中显示字幕", isOn: $overlayVisible)
                    Button("字幕来源…") { showSource = true }
                    Divider()
                    ForEach(SubtitleExportMode.allCases) { mode in
                        Button("导出\(mode.title) SRT…") { if let project = studio.project { subtitles.export(project, mode: mode) } }.disabled(track == nil)
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 25, height: 27) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("字幕操作")
                IconButton(icon: "xmark", help: "收起字幕预览区", action: onClose)
            }.padding(.horizontal, 15).frame(height: 44)
            if track != nil {
                HStack {
                    Text(track?.cues.allSatisfy { $0.language == .zh } == true ? "中文字幕" : "原文 · 中文").font(.system(size: 11)).foregroundStyle(Color.mutedText)
                    Spacer()
                    Toggle("双向跟随", isOn: $linked).toggleStyle(.switch).controlSize(.mini).tint(Color.accent).fixedSize()
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            if let track {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(track.cues) { cue in
                                subtitleRow(cue).id(cue.id)
                            }
                        }.padding(14)
                    }
                    .onChange(of: currentID, initial: true) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: studio.selectedSubtitleID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "captions.bubble").font(.system(size: 28, weight: .light)).foregroundStyle(Color.accent)
                    Text(studio.project?.subtitleTrack != nil ? "素材已调整，重新生成字幕" : "听懂每一句").font(.system(size: 18, weight: .semibold))
                    Text("识别中、英、日、韩、西、法语人声，保留原文；非中文自动附上中文字幕。").font(.system(size: 13)).lineSpacing(6).foregroundStyle(Color.mutedText)
                    StudioButton(title: "生成字幕", icon: "sparkles", accent: true) { subtitles.showGeneration = true }.disabled(subtitles.isRunning)
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if subtitles.isRunning || (isThisTask && subtitles.error != nil) {
                VStack(alignment: .leading, spacing: 8) {
                    if subtitles.isRunning {
                        ProgressView(value: subtitles.progress).tint(Color.accent)
                        HStack {
                            Text(isThisTask ? subtitles.status : "正在为另一个项目生成字幕").font(.system(size: 11)).foregroundStyle(Color.mutedText)
                            Spacer(); Button("取消") { subtitles.cancel() }.buttonStyle(.plain)
                        }
                    } else if let error = subtitles.error {
                        Text(error).font(.system(size: 12)).lineSpacing(4).foregroundStyle(Color.orange).textSelection(.enabled)
                        if subtitles.retryAvailable(for: studio.project) {
                            Button("重试中文翻译") { subtitles.generate(studio: studio, scripts: scripts, retry: true) }
                            Button("模型设置") { scripts.present(studio: studio, settings: true) }.buttonStyle(.plain).foregroundStyle(Color.mutedText)
                        } else {
                            Button("重新生成字幕…") { subtitles.showGeneration = true }
                        }
                    }
                }.padding(14).background(Color.panel)
            }
        }.background(Color.studioBG)
        .onChange(of: linked, initial: true) { _, value in studio.subtitlePlaybackFollow = value && track != nil }
        .onChange(of: track?.id) { _, _ in studio.subtitlePlaybackFollow = linked && track != nil }
        .onDisappear { studio.subtitlePlaybackFollow = false }
        .sheet(item: $editingCue) { cue in SubtitleEditSheet(cue: cue) }
        .sheet(isPresented: $showSource) { SubtitleSourceSheet(sourceDescription: track?.sourceDescription) }
    }

    private func subtitleRow(_ cue: SubtitleCue) -> some View {
        let active = currentID == cue.id
        return Button {
            studio.selectedSubtitleID = cue.id
            if linked { studio.selectSubtitle(cue) }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(cue.language.title).font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text("\(timecode(cue.start, frameRate: studio.project?.frameRate ?? 30)) – \(timecode(cue.end, frameRate: studio.project?.frameRate ?? 30))").font(.system(size: 9, design: .monospaced))
                }.foregroundStyle(active ? Color.accent : Color.mutedText)
                Text(cue.text).font(.system(size: 14, weight: active ? .semibold : .regular)).lineSpacing(4)
                    .foregroundStyle(active ? Color.accent : Color.white.opacity(0.94))
                if cue.language != .zh {
                    Text(cue.chineseText).font(.system(size: 13)).lineSpacing(4).foregroundStyle(.white.opacity(active ? 0.94 : 0.7))
                }
            }.multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                .background(active ? Color.accent.opacity(0.1) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(active ? Color.accent.opacity(0.35) : .clear).allowsHitTesting(false) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(cue.language.title)字幕：\(cue.text)" + (cue.language == .zh ? "" : "\n中文：\(cue.chineseText)"))
            .accessibilityValue(active ? (studio.isPlaying ? "正在播放" : "当前字幕") : "")
            .contextMenu { Button("编辑这句字幕…") { editingCue = cue } }
    }
}

struct SubtitleGenerationSheet: View {
    @EnvironmentObject var studio: StudioModel
    @EnvironmentObject var subtitles: SubtitleWorkspaceModel
    @EnvironmentObject var scripts: ScriptWorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("生成多语言字幕").font(.system(size: 22, weight: .semibold)); Spacer(); Button("关闭") { subtitles.showGeneration = false } }
            Text(studio.project?.title ?? "").lineLimit(1).font(.system(size: 12)).foregroundStyle(Color.mutedText)
            Picker("视频语言", selection: $subtitles.languageCode) {
                Text("自动识别").tag("auto")
                ForEach(SubtitleLanguage.allCases, id: \.rawValue) { language in Text(language.title).tag(language.rawValue) }
            }.pickerStyle(.menu)
            Text("原文字幕 + 中文字幕\n中文视频只生成一份中文字幕。字幕保存在独立轨道，可逐句修改并导出 SRT。").font(.system(size: 13)).lineSpacing(7).foregroundStyle(Color.mutedText)
            VStack(alignment: .leading, spacing: 6) {
                Text("语音识别：Whisper small · 本机运行")
                Text("中文翻译：" + (scripts.subtitleTranslationModelID ?? "请先保存模型设置"))
                Text("生成后，脚本台词将共用这份字幕。")
            }.font(.system(size: 11)).foregroundStyle(Color.mutedText).textSelection(.enabled)
            if !SubtitleTranscriber.isAvailable {
                Text(SubtitleTranscriber.availabilityMessage).font(.system(size: 12)).foregroundStyle(Color.orange)
                Button("选择已下载的语音模型…") { subtitles.chooseModel() }
            }
            if let error = subtitles.error { Text(error).font(.system(size: 12)).foregroundStyle(Color.orange) }
            Divider()
            HStack(alignment: .center) {
                Text("人声在本机识别；非中文识别文本会发送到已配置的模型服务进行中文翻译。").font(.system(size: 11)).foregroundStyle(Color.mutedText).fixedSize(horizontal: false, vertical: true)
                Spacer()
                StudioButton(title: "生成字幕", icon: "sparkles", accent: true) { subtitles.generate(studio: studio, scripts: scripts) }
                    .disabled(subtitles.isRunning || !SubtitleTranscriber.isAvailable || studio.project == nil)
            }
        }.padding(25).frame(width: 540).background(Color.panel).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

private struct SubtitleSourceSheet: View {
    @EnvironmentObject var scripts: ScriptWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let sourceDescription: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("字幕来源").font(.title2); Spacer(); Button("关闭") { dismiss() } }
            Text("识别语种与原文") .font(.headline)
            Text("OpenAI 开源 Whisper small 多语言模型，通过 whisper.cpp 在本机处理视频原声，不调用 OpenAI 云端接口。")
                .font(.system(size: 13)).lineSpacing(5)
            Text("中文字幕翻译").font(.headline)
            Text("非中文的识别文本发送至你已保存的中转服务。当前模型：\(scripts.subtitleTranslationModelID ?? "尚未保存配置")。中文原声不重复翻译。")
                .font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
            if let sourceDescription {
                Text("这份字幕的生成记录：\(sourceDescription)")
                    .font(.system(size: 11)).foregroundStyle(Color.mutedText).textSelection(.enabled)
                if !sourceDescription.contains("Whisper") {
                    Text("旧版本没有记录具体翻译模型；当前设置不代表旧字幕生成时的设置。")
                        .font(.system(size: 11)).foregroundStyle(Color.mutedText)
                }
            }
            Text("脚本台词与字幕轨共用原文、译文和时间。脚本分析还会把所选视频及该范围的字幕发送至已配置模型，用于整理故事与镜头。")
                .font(.system(size: 12)).lineSpacing(4).foregroundStyle(Color.mutedText)
            HStack {
                Link("Whisper 模型来源", destination: URL(string: "https://github.com/openai/whisper")!)
                Link("whisper.cpp 引擎", destination: URL(string: "https://github.com/ggml-org/whisper.cpp")!)
            }.font(.system(size: 12)).tint(Color.accent)
        }.padding(24).frame(width: 510).background(Color.panel).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

struct SubtitleOverlay: View {
    @EnvironmentObject var studio: StudioModel
    @AppStorage("subtitleOverlayVisible") private var visible = true
    var body: some View {
        if visible, let cue = studio.currentSubtitleTrack?.activeCue(at: studio.currentTime) {
            VStack(spacing: 4) {
                Text(cue.text).font(.system(size: 16, weight: .medium))
                if cue.language != .zh { Text(cue.chineseText).font(.system(size: 15, weight: .medium)) }
            }.foregroundStyle(.white).multilineTextAlignment(.center).lineSpacing(3)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 30).padding(.bottom, 16).frame(maxWidth: .infinity)
                .allowsHitTesting(false).accessibilityLabel("当前画面字幕").accessibilityValue(cue.text + (cue.language == .zh ? "" : "\n" + cue.chineseText))
        }
    }
}

struct SubtitleEditSheet: View {
    @EnvironmentObject var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @JingduState var cue: SubtitleCue
    @JingduState private var saveError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("编辑字幕").font(.title2); Spacer(); Button("取消") { dismiss() } }
            Text("修改将同步到字幕轨、画面字幕和脚本台词。")
                .font(.system(size: 12)).foregroundStyle(Color.mutedText)
            HStack { NumericInput(title: "起点（秒）", value: $cue.start); NumericInput(title: "终点（秒）", value: $cue.end) }
            Text(cue.language.title + "原文").font(.caption).foregroundStyle(Color.mutedText)
            TextEditor(text: $cue.text).frame(height: 80).scrollContentBackground(.hidden).padding(8).background(Color.studioBG)
            if cue.language != .zh {
                Text("中文翻译").font(.caption).foregroundStyle(Color.mutedText)
                TextEditor(text: $cue.chineseText).frame(height: 80).scrollContentBackground(.hidden).padding(8).background(Color.studioBG)
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(Color.orange) }
            HStack { Spacer(); StudioButton(title: "保存", icon: "checkmark", accent: true) {
                if studio.saveSubtitle(cue) { dismiss() }
                else { saveError = studio.error ?? "无法保存，请检查时间范围。"; studio.error = nil }
            } }
        }.padding(24).frame(width: 500).background(Color.panel).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}
