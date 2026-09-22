import SwiftUI

// The same reader and player keep their identity when their positions change.
enum StudyWorkspaceLayout: String, CaseIterable, Identifiable {
    case picture, sideBySide, stacked
    var id: String { rawValue }
    var title: String {
        switch self { case .picture: return "画面优先"; case .sideBySide: return "左右对照"; case .stacked: return "上下对照" }
    }
    var icon: String {
        switch self { case .picture: return "sidebar.left"; case .sideBySide: return "rectangle.split.2x1"; case .stacked: return "rectangle.split.1x2" }
    }
}

private struct ReadingPaneLayout: Layout {
    let stacked: Bool
    let extent: CGFloat
    let showsReader: Bool
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let divider: CGFloat = showsReader ? 7 : 0
        let reader: CGRect
        let handle: CGRect
        let player: CGRect
        if stacked {
            player = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height - extent - divider)
            handle = CGRect(x: bounds.minX, y: player.maxY, width: bounds.width, height: divider)
            reader = CGRect(x: bounds.minX, y: handle.maxY, width: bounds.width, height: extent)
        } else {
            reader = CGRect(x: bounds.minX, y: bounds.minY, width: extent, height: bounds.height)
            handle = CGRect(x: reader.maxX, y: bounds.minY, width: divider, height: bounds.height)
            player = CGRect(x: handle.maxX, y: bounds.minY, width: bounds.width - extent - divider, height: bounds.height)
        }
        for (view, rect) in zip(subviews, [reader, handle, player]) {
            view.place(at: rect.origin, anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
}

struct ReadingWorkspace: View {
    @EnvironmentObject var studio: StudioModel
    let layout: StudyWorkspaceLayout
    let showsReader: Bool
    let showsNotes: Bool
    let onClose: () -> Void
    @AppStorage("scriptPane.pictureWidth") private var pictureWidth = 330.0
    @AppStorage("scriptPane.sideRatio") private var sideRatio = 0.46
    @AppStorage("scriptPane.stackRatio") private var stackRatio = 0.43
    @JingduState<Double?> private var dragStart: Double?
    var body: some View {
        GeometryReader { geometry in
            let vertical = layout == .stacked
            let length = vertical ? geometry.size.height : geometry.size.width
            let desired = vertical ? length * stackRatio : layout == .picture ? pictureWidth : length * sideRatio
            let lower = vertical ? min(170, length * 0.45) : min(310, length * 0.45)
            let upper = max(lower, length - (vertical ? 175 : 520) - 7)
            let extent = showsReader ? min(upper, max(lower, desired)) : 0
            ReadingPaneLayout(stacked: vertical, extent: extent, showsReader: showsReader) {
                Group {
                    if studio.showSubtitleReader { SubtitleSidebarPanel(onClose: onClose) }
                    else { ScriptSidebarPanel(isVisible: showsReader, onClose: onClose) }
                }.clipped()
                    .opacity(showsReader ? 1 : 0).allowsHitTesting(showsReader).accessibilityHidden(!showsReader)
                Rectangle().fill(Color.panel)
                    .overlay {
                        RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.18))
                            .frame(width: vertical ? 32 : 2, height: vertical ? 2 : 32)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        if dragStart == nil { dragStart = extent }
                        let offset = vertical ? -value.translation.height : value.translation.width
                        let next = min(upper, max(lower, (dragStart ?? extent) + offset))
                        if vertical { stackRatio = next / max(1, length) }
                        else if layout == .picture { pictureWidth = next }
                        else { sideRatio = next / max(1, length) }
                    }.onEnded { _ in dragStart = nil })
                    .help(vertical ? "拖动调整阅读区高度" : "拖动调整阅读区宽度")
                    .accessibilityLabel("调整阅读区域大小")
                    .opacity(showsReader ? 1 : 0).allowsHitTesting(showsReader).accessibilityHidden(!showsReader)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        PlayerWorkspace()
                        if studio.showContact && (!vertical || !showsReader) { ContextStrip() }
                    }
                    if showsNotes && !showsReader {
                        Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
                        InspectorPanel().frame(width: 300)
                    }
                }.clipped()
            }
        }
    }
}

struct ScriptSidebarPanel: View {
    @EnvironmentObject var studio: StudioModel
    @EnvironmentObject var scripts: ScriptWorkspaceModel
    let isVisible: Bool
    let onClose: () -> Void
    private var project: FilmProject? { studio.project }
    private var selected: ScriptAnalysis? {
        guard scripts.workspaceProjectID == project?.id else { return nil }
        return scripts.selectedAnalysis(studio: studio)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("脚本").font(.system(size: 13, weight: .semibold))
                if let project, project.scriptAnalyses.count > 1 {
                    Menu {
                        ForEach(project.scriptAnalyses.reversed()) { item in
                            Button { scripts.selectedAnalysisID = item.id } label: {
                                if selected?.id == item.id { Label(item.title, systemImage: "checkmark") }
                                else { Text(item.title) }
                            }
                        }
                    } label: { Text("版本 \(project.scriptAnalyses.firstIndex(where: { $0.id == selected?.id }).map { $0 + 1 } ?? 1)").font(.system(size: 11)) }
                    .menuStyle(.borderlessButton).fixedSize().help("选择已保存的脚本")
                }
                Spacer(minLength: 0)
                Button { scripts.present(studio: studio) } label: {
                    Label(selected == nil ? "生成脚本" : "重新生成", systemImage: "sparkles").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(Color.mutedText).disabled(studio.busy || scripts.isRunning)
                IconButton(icon: "xmark", help: "收起脚本预览区 ⌘J", action: onClose)
            }.padding(.leading, 18).padding(.trailing, 8).frame(height: 44)
            Toggle("打开项目自动生成", isOn: $scripts.autoGenerateOnOpen)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11)).foregroundStyle(Color.mutedText)
                .help("默认开启。已有脚本不重复生成；使用已配置模型。")
                .padding(.horizontal, 18).padding(.bottom, 12)
            Divider().opacity(0.5)
            if let selected, let project {
                let key = ScriptDraftKey(projectID: project.id, analysisID: selected.id)
                let sharedSubtitles = ScriptReading.usableSubtitleTrack(for: selected, project: project)
                ScriptResultPanel(analysis: selected,
                    isCurrent: selected.isCurrent(for: project),
                    isVisible: isVisible,
                    isPersisted: !scripts.unsavedAnalysisIDs.contains(key),
                    subtitles: sharedSubtitles,
                    onAddToTimeline: { scripts.addToTimeline(selected, studio: studio) },
                    onExport: { scripts.export($0, dialogueOnly: $1, subtitles: sharedSubtitles) },
                    onSave: { scripts.saveAnalysis($0, studio: studio) },
                    draft: Binding(get: { scripts.drafts[key] ?? selected }, set: { scripts.drafts[key] = $0 }))
                    .id(key)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("在这里读完整的故事").font(.system(size: 18, weight: .medium))
                    Text("场景、动作、对白与视听表达，\n沿着画面的时间展开。").font(.system(size: 13)).lineSpacing(6).foregroundStyle(Color.mutedText)
                    if let hint = scripts.automaticGenerationHint {
                        Text(hint).font(.system(size: 12)).lineSpacing(4).foregroundStyle(Color.mutedText)
                    }
                    Button("生成这段视频的脚本") { scripts.present(studio: studio) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accent).disabled(studio.busy || scripts.isRunning)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, 20)
            }
            if scripts.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(scripts.status).font(.system(size: 11)).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("取消") { scripts.cancel() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.mutedText)
                        .help("取消本次脚本生成")
                }.padding(12).background(Color.panel)
            } else if let error = scripts.error {
                HStack(alignment: .top) {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { scripts.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(Color.panel)
            }
        }.background(Color(red: 0.07, green: 0.08, blue: 0.095))
    }
}
