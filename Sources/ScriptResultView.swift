import SwiftUI

private enum ScriptReadMode: String, CaseIterable { case complete = "全文", dialogue = "台词" }

@MainActor struct ScriptResultPanel: View {
    @EnvironmentObject var studio: StudioModel
    let analysis: ScriptAnalysis
    let isCurrent: Bool
    let isVisible: Bool
    let isPersisted: Bool
    let subtitles: SubtitleTrack?
    let onAddToTimeline: () -> Void
    let onExport: (ScriptAnalysis, Bool) -> Void
    let onSave: (ScriptAnalysis) -> Void
    @Binding var draft: ScriptAnalysis
    @AppStorage("scriptReaderLinked") private var linked = true
    @JingduState private var mode = ScriptReadMode.complete
    @JingduState private var editing = false
    @JingduState<UUID?> private var selectedSegmentID: UUID?
    @JingduState<UUID?> private var selectedCueID: UUID?
    @JingduState private var showAnalysis = false
    @JingduState private var narrativeEdits: [UUID: String] = [:]
    @JingduState private var scrollRequest = UUID()
    @JingduState private var editingSubtitle: SubtitleCue?
    @JingduState private var sharedCues: [ScriptReadingCue] = []
    @JingduState private var sharedCuesBySegment: [UUID: [ScriptReadingCue]] = [:]

    private var edited: Bool { draft != analysis }
    private var cues: [ScriptReadingCue] {
        subtitles == nil ? draft.segments.flatMap { displayCues($0) }
            : sharedCues
    }
    private var followsPlayback: Bool { linked && isCurrent && isVisible && !editing }
    private var followScrollTarget: String? {
        guard followsPlayback else { return nil }
        if mode == .dialogue {
            return ScriptReading.followCue(at: studio.currentTime, in: draft, subtitles: subtitles).map { "cue-" + $0.id.uuidString }
        }
        if let cue = ScriptReading.cue(at: studio.currentTime, in: draft, subtitles: subtitles) { return "cue-" + cue.id.uuidString }
        return ScriptReading.segment(at: studio.currentTime, in: draft).map { "scene-" + $0.id.uuidString }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            if editing || edited || !isPersisted || !isCurrent {
                HStack(spacing: 7) {
                    Text(!isPersisted ? "尚未保存" : edited ? "有未保存的修改" : editing ? "正在编辑" : "素材已调整，联动暂停")
                        .foregroundStyle(!isPersisted || edited || !isCurrent ? Color.orange : Color.mutedText)
                    Spacer(minLength: 0)
                    if editing { Button("完成") { toggleEditing() }.buttonStyle(.plain).foregroundStyle(Color.accent) }
                }.font(.system(size: 11)).padding(.horizontal, 16).padding(.bottom, 9)
            }
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            document.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: followsPlayback, initial: true) { _, active in
            studio.scriptPlaybackFollow = active
            if active { followPlayback(studio.currentTime) }
        }
        .onDisappear { studio.scriptPlaybackFollow = false }
        .onChange(of: studio.currentTime) { _, time in if followsPlayback { followPlayback(time) } }
        .onChange(of: analysis.id) { _, _ in selectedCueID = nil; selectedSegmentID = nil; editing = false; narrativeEdits = [:]; followPlayback(studio.currentTime) }
        .onChange(of: subtitles, initial: true) { _, _ in refreshSharedCues(); followPlayback(studio.currentTime) }
        .onChange(of: draft) { _, _ in refreshSharedCues() }
        .sheet(item: $editingSubtitle) { cue in SubtitleEditSheet(cue: cue) }
    }
    private var toolbar: some View {
        HStack(spacing: 5) {
            Picker("阅读内容", selection: $mode) {
                ForEach(ScriptReadMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 104)
            Spacer(minLength: 0)
            if edited || !isPersisted {
                Button { onSave(draft) } label: {
                    Image(systemName: "square.and.arrow.down").frame(width: 27, height: 27)
                }.buttonStyle(.plain).foregroundStyle(Color.accent).help("保存脚本修改").accessibilityLabel("保存脚本修改")
            }
            Toggle("双向跟随", isOn: $linked)
                .toggleStyle(.switch).controlSize(.mini).tint(Color.accent).fixedSize()
                .foregroundStyle(linked ? Color.accent : Color.mutedText)
                .disabled(!isCurrent || editing)
                .help(linked ? "已开启：播放或拖动时间轴会跟随台词；点击台词定位画面，保持当前播放或暂停状态。" : "已关闭：台词与时间轴独立浏览。")
                .accessibilityLabel("台词与时间轴双向跟随")
            Menu {
                Button(editing ? "完成编辑" : "编辑文字") { toggleEditing() }
                Button(edited ? "保存修改" : "保存脚本") { onSave(draft) }.disabled(!edited && isPersisted)
                Divider()
                Button("定位当前画面对应文字") { followPlayback(studio.currentTime); scrollRequest = UUID() }.disabled(!followsPlayback)
                Toggle("显示设计解读", isOn: Binding(get: { showAnalysis }, set: { value in
                    if value { mode = .complete }
                    showAnalysis = value
                }))
                Divider()
                Button("导出完整剧本…") { onExport(draft, false) }
                Button("仅导出台词…") { onExport(draft, true) }.disabled(cues.isEmpty)
                Divider()
                Button(analysis.timelineNoteIDs.isEmpty ? "加入时间轴笔记" : "已加入时间轴") { onAddToTimeline() }
                    .disabled(!isCurrent || !isPersisted || edited || !analysis.timelineNoteIDs.isEmpty)
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 27) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("脚本操作").accessibilityLabel("脚本操作")
        }.font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 9)
    }
    private var document: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    documentHeading
                    if mode == .complete {
                        if !draft.synopsis.isEmpty || editing {
                            if editing { textEditor("故事梗概", text: $draft.synopsis, height: 80) }
                            else { Text(draft.synopsis).font(.system(size: 13)).lineSpacing(6).foregroundStyle(Color.white.opacity(0.64)).textSelection(.enabled) }
                            Spacer().frame(height: 25)
                        }
                        ForEach(Array(draft.segments.enumerated()), id: \.element.id) { index, segment in
                            scene(segment, index: index).id("scene-" + segment.id.uuidString)
                        }
                        if showAnalysis { analysisFooter.id("analysis-details") }
                    } else if cues.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("还没有可提取的台词").font(.system(size: 15, weight: .medium))
                            Text("可回到全文查看完整的场景与视听描述。")
                                .font(.system(size: 12)).foregroundStyle(Color.mutedText).lineSpacing(5)
                            Button("阅读完整剧本") { mode = .complete }
                        }.padding(.vertical, 36)
                    } else {
                        ForEach(cues) { cue in dialogue(cue).id("cue-" + cue.id.uuidString).padding(.bottom, 12) }
                    }
                }.frame(maxWidth: 720, alignment: .leading).padding(.horizontal, 20).padding(.top, 21).padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
                .onChange(of: followScrollTarget, initial: true) { _, target in
                    if let target { proxy.scrollTo(target, anchor: target.hasPrefix("cue-") ? .center : .top) }
                }
                .onChange(of: mode) { _, _ in
                    if let target = followScrollTarget { proxy.scrollTo(target, anchor: .center) }
                }
                .onChange(of: scrollRequest) { _, _ in
                    if let target = followScrollTarget { proxy.scrollTo(target, anchor: .center) }
                }
                .onChange(of: showAnalysis) { _, value in
                    if value { proxy.scrollTo("analysis-details", anchor: .top) }
                }
        }
    }
    private var documentHeading: some View {
        VStack(alignment: .leading, spacing: 9) {
            if editing { TextField("剧本标题", text: $draft.title).textFieldStyle(.plain).font(.system(size: 20, weight: .semibold)) }
            else { Text(draft.title).font(.system(size: 20, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Text(scriptRange(draft.rangeStart, draft.rangeEnd))
                Text("·")
                Text(mode == .complete ? "\(draft.segments.count) 段" : "\(cues.count) 条台词")
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.mutedText)
            if subtitles != nil {
                Label("台词与字幕同步", systemImage: "link")
                    .font(.system(size: 11)).foregroundStyle(Color.accent.opacity(0.85))
                    .help("原文、中文翻译和时间来自同一字幕轨。右键台词可编辑，修改会同步到字幕。")
            }
        }.padding(.bottom, 22)
    }
    private func scene(_ segment: ScriptSegment, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Button { selectSegment(segment) } label: {
                HStack(spacing: 8) {
                    Text(String(format: "%02d", index + 1)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Text(scriptRange(segment.start, segment.end)).font(.system(size: 10, design: .monospaced))
                    Spacer()
                    if selectedSegmentID == segment.id { Circle().fill(Color.accent).frame(width: 4, height: 4) }
                }.foregroundStyle(selectedSegmentID == segment.id ? Color.accent : Color.mutedText).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("段落 \(index + 1)，\(scriptRange(segment.start, segment.end))")
            if editing { textEditor("场景与视听叙述", text: narrativeBinding(segment.id), height: 170) }
            else { Text(ScriptReading.narrative(for: segment)).font(.system(size: 14)).lineSpacing(7).foregroundStyle(Color.white.opacity(0.9)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            let segmentCues = displayCues(segment)
            ForEach(segmentCues) { cue in dialogue(cue).id("cue-" + cue.id.uuidString) }
            if subtitles == nil, segmentCues.isEmpty, !segment.dialogue.isEmpty {
                if editing { textEditor("对白记录 / 待核对", text: segmentTextBinding(segment.id, \.dialogue), height: 65) }
                else { Text(segment.dialogue).font(.system(size: 12)).lineSpacing(5).foregroundStyle(Color.mutedText).textSelection(.enabled) }
            }
        }.padding(.bottom, 27)
    }
    private func dialogue(_ cue: ScriptReadingCue) -> some View {
        let current = followsPlayback && selectedCueID == cue.id
        let selected = selectedCueID == cue.id
        let lines = ScriptReading.dialogueLines(cue.text)
        let sharedCue = subtitles?.cues.first { $0.id == cue.id }
        return VStack(alignment: .leading, spacing: 8) {
            if editing, sharedCue == nil {
                HStack {
                    Text(cue.isParagraphFallback ? "段落对白" : "逐句对白").font(.system(size: 11)).foregroundStyle(Color.accent)
                    Spacer(); Text(scriptRange(cue.start, cue.end)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.mutedText)
                }
                if !cue.isParagraphFallback {
                    TextField("人物 / 说话者", text: cueTextBinding(cue, speaker: true)).textFieldStyle(.roundedBorder)
                    HStack { NumericInput(title: "起点（秒）", value: cueTimeBinding(cue, start: true)); NumericInput(title: "终点（秒）", value: cueTimeBinding(cue, start: false)) }
                }
                TextEditor(text: cueTextBinding(cue, speaker: false)).font(.system(size: 14)).scrollContentBackground(.hidden).frame(height: 65)
                Text("原文与译文各占一行").font(.system(size: 10)).foregroundStyle(Color.mutedText)
            } else {
                Button { selectCue(cue) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            if current {
                                Image(systemName: studio.isPlaying ? "waveform" : "play.fill")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accent)
                                    .accessibilityHidden(true)
                            }
                            Text(cue.speaker.isEmpty ? "对白" : cue.speaker).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(current ? Color.accent : Color.white.opacity(0.75))
                            Spacer()
                            Text(scriptRange(cue.start, cue.end))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(current ? Color.accent.opacity(0.8) : Color.mutedText).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line).font(.system(size: index == 0 ? 14 : 13, weight: current ? .semibold : .regular))
                                    .foregroundStyle(index == 0 ? (current ? Color.accent : Color.white.opacity(0.92)) : Color.white.opacity(current ? 0.94 : 0.66))
                                    .lineSpacing(4).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(!linked ? "双向跟随已关闭，点击仅选择文字" : cue.isParagraphFallback ? "按所在段落定位；这份脚本未提供逐句时间" : "点击定位画面；台词时间可在编辑时核对")
                    .accessibilityLabel("台词 \(cue.speaker)：\(lines.joined(separator: "\n"))，\(scriptRange(cue.start, cue.end))")
                    .accessibilityValue(current ? (studio.isPlaying ? "正在播放" : "当前台词") : selected ? "已选中" : "")
                    .contextMenu {
                        if let sharedCue { Button("编辑这句字幕…") { editingSubtitle = sharedCue } }
                    }
                if editing, let sharedCue {
                    Button("编辑字幕与台词…") { editingSubtitle = sharedCue }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accent)
                }
            }
        }.padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? Color.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(current ? Color.accent.opacity(0.28) : Color.clear, lineWidth: 1).allowsHitTesting(false) }
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(current ? Color.accent : Color.white.opacity(selected ? 0.35 : 0.1)).frame(width: current ? 3 : 1).padding(.vertical, current ? 8 : 0).allowsHitTesting(false) }
    }
    private var analysisFooter: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("设计解读").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mutedText)
                VStack(alignment: .leading, spacing: 18) {
                    if editing {
                        textEditor("叙事结构", text: $draft.structure, height: 100)
                        textEditor("证据限制与待核对项", text: $draft.caveats, height: 80)
                    } else {
                        Text(draft.structure).lineSpacing(6).textSelection(.enabled)
                        Text(draft.caveats).foregroundStyle(Color.mutedText).lineSpacing(5).textSelection(.enabled)
                    }
                    ForEach(draft.segments) { segment in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(scriptRange(segment.start, segment.end)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.accent)
                            if editing {
                                textEditor("设计解读", text: segmentTextBinding(segment.id, \.reasoning), height: 80)
                                textEditor("待核对", text: segmentTextBinding(segment.id, \.uncertainty), height: 60)
                            } else {
                                Text(segment.reasoning).textSelection(.enabled)
                                Text(segment.uncertainty).foregroundStyle(Color.mutedText).textSelection(.enabled)
                            }
                        }
                    }
                    Text("\(draft.modelID) · \(draft.inputMode)").font(.system(size: 10)).foregroundStyle(Color.mutedText)
                }.font(.system(size: 12)).padding(.top, 14)
            }.font(.system(size: 12))
        }
    }
    private func textEditor(_ label: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.mutedText)
            TextEditor(text: text).font(.system(size: 14)).scrollContentBackground(.hidden).padding(9).frame(height: height)
                .background(Color.studioBG, in: RoundedRectangle(cornerRadius: 6))
        }
    }
    private func displayCues(_ segment: ScriptSegment) -> [ScriptReadingCue] {
        if subtitles != nil { return sharedCuesBySegment[segment.id] ?? [] }
        let current = ScriptReading.displayCues(for: segment)
        // Keep a legacy dialogue editor mounted while its text is selected and replaced.
        if subtitles == nil, editing, current.isEmpty, segment.dialogueCues.isEmpty,
           let original = analysis.segments.first(where: { $0.id == segment.id }), ScriptReading.hasDialogue(original.dialogue) {
            return [ScriptReadingCue(id: segment.id, segmentID: segment.id, start: segment.start, end: segment.end,
                                     speaker: "", text: segment.dialogue, isParagraphFallback: true)]
        }
        return current
    }
    private func refreshSharedCues() {
        // Rebuild when text or timing changes, not once per scene on each
        // playback tick. Every shared row keeps the subtitle's stable identity.
        sharedCues = subtitles == nil ? [] : ScriptReading.cues(in: draft, subtitles: subtitles)
        sharedCuesBySegment = Dictionary(grouping: sharedCues, by: \.segmentID)
        scrollRequest = UUID()
    }
    private func followPlayback(_ time: Double) {
        guard followsPlayback else { return }
        let active = ScriptReading.cue(at: time, in: draft, subtitles: subtitles)
        selectedSegmentID = active?.segmentID ?? ScriptReading.segment(at: time, in: draft)?.id
        selectedCueID = active?.id
    }
    private func toggleEditing() {
        if !editing {
            narrativeEdits = Dictionary(uniqueKeysWithValues: draft.segments.map { ($0.id, ScriptReading.narrative(for: $0)) })
        }
        studio.dismissTextFocus()
        editing.toggle()
    }
    private func selectSegment(_ segment: ScriptSegment) {
        selectedSegmentID = segment.id; selectedCueID = nil
        if followsPlayback { seekPreview(segment.start) }
    }
    private func selectCue(_ cue: ScriptReadingCue) {
        selectedSegmentID = cue.segmentID; selectedCueID = cue.id
        if followsPlayback { seekPreview(cue.start) }
    }
    private func seekPreview(_ time: Double) {
        guard isCurrent, time.isFinite, studio.mediaAvailable else { return }
        studio.dismissTextFocus(); studio.loopShot = false
        studio.seek(min(draft.rangeEnd, max(draft.rangeStart, time)))
        if linked { followPlayback(studio.currentTime) }
    }
    private func narrativeBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { narrativeEdits[id] ?? draft.segments.first(where: { $0.id == id }).map { ScriptReading.narrative(for: $0) } ?? "" },
                set: { text in narrativeEdits[id] = text; if let index = draft.segments.firstIndex(where: { $0.id == id }) { draft.segments[index].screenplay = text } })
    }
    private func segmentTextBinding(_ id: UUID, _ path: WritableKeyPath<ScriptSegment, String>) -> Binding<String> {
        Binding(get: { draft.segments.first(where: { $0.id == id })?[keyPath: path] ?? "" },
                set: { text in if let index = draft.segments.firstIndex(where: { $0.id == id }) { draft.segments[index][keyPath: path] = text } })
    }
    private func cueTextBinding(_ cue: ScriptReadingCue, speaker: Bool) -> Binding<String> {
        Binding(get: {
            guard let segment = draft.segments.first(where: { $0.id == cue.segmentID }) else { return "" }
            if cue.isParagraphFallback { return speaker ? "" : segment.dialogue }
            guard let value = segment.dialogueCues.first(where: { $0.id == cue.id }) else { return "" }
            return speaker ? value.speaker : value.text
        }, set: { text in
            guard let i = draft.segments.firstIndex(where: { $0.id == cue.segmentID }) else { return }
            if cue.isParagraphFallback { draft.segments[i].dialogue = text; return }
            guard let j = draft.segments[i].dialogueCues.firstIndex(where: { $0.id == cue.id }) else { return }
            if speaker { draft.segments[i].dialogueCues[j].speaker = text } else { draft.segments[i].dialogueCues[j].text = text }
        })
    }
    private func cueTimeBinding(_ cue: ScriptReadingCue, start: Bool) -> Binding<Double> {
        Binding(get: {
            let value = draft.segments.first(where: { $0.id == cue.segmentID })?.dialogueCues.first(where: { $0.id == cue.id })
            return start ? (value?.start ?? cue.start) : (value?.end ?? cue.end)
        }, set: { value in
            guard value.isFinite, let i = draft.segments.firstIndex(where: { $0.id == cue.segmentID }),
                  let j = draft.segments[i].dialogueCues.firstIndex(where: { $0.id == cue.id }) else { return }
            let segment = draft.segments[i]
            let lower = j > 0 ? segment.dialogueCues[j - 1].end : segment.start
            let upper = j + 1 < segment.dialogueCues.count ? segment.dialogueCues[j + 1].start : segment.end
            if start { draft.segments[i].dialogueCues[j].start = min(max(lower, value), segment.dialogueCues[j].end - 0.001) }
            else { draft.segments[i].dialogueCues[j].end = max(min(upper, value), segment.dialogueCues[j].start + 0.001) }
        })
    }
}

private func scriptRange(_ start: Double, _ end: Double) -> String {
    func format(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 86_400_000 else { return "--:--" }
        return String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
    return format(start) + "–" + format(end)
}
