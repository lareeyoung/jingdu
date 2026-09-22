import SwiftUI

@main struct JingduApp: App {
    @StateObject private var model: StudioModel
    @StateObject private var scripts: ScriptWorkspaceModel
    @StateObject private var subtitles: SubtitleWorkspaceModel
    init() {
        let subtitles = SubtitleWorkspaceModel()
        _subtitles = StateObject(wrappedValue: subtitles)
        _scripts = StateObject(wrappedValue: ScriptWorkspaceModel(subtitles: subtitles))
        _model = StateObject(wrappedValue: StudioModel())
    }
    var body: some Scene {
        WindowGroup("镜读 · 拉片工作台") {
            StudioRoot().environmentObject(model).environmentObject(scripts).environmentObject(subtitles)
        }
        .defaultSize(width: 1480, height: 980)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { Button("导入视频…") { model.openVideo() }.keyboardShortcut("o"); Button("导入项目备份…") { model.importProject() }; Divider(); Button("导出拉片笔记…") { model.export("md") }.keyboardShortcut("e").disabled(model.project == nil) }
            CommandGroup(replacing: .undoRedo) { Button("撤销") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo); Button("重做") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo) }
            CommandMenu("脚本反解") {
                Button(scripts.showReader ? "收起脚本预览区" : "展开脚本预览区") { model.dismissTextFocus(); model.showSubtitleReader = false; scripts.showReader.toggle() }.keyboardShortcut("j").disabled(model.project == nil)
                Button("反解当前视频脚本…") { scripts.present(studio: model) }.keyboardShortcut("j", modifiers: [.command, .shift]).disabled(model.project == nil || model.busy)
                Toggle("打开项目自动生成", isOn: $scripts.autoGenerateOnOpen)
                Button("模型与中转设置…") { scripts.present(studio: model, settings: true) }
            }
            CommandMenu("字幕") {
                Button("展开字幕预览区") { model.showSubtitleReader = true; scripts.showReader = false }.disabled(model.project == nil)
                Button("生成多语言字幕…") { subtitles.showGeneration = true }.disabled(model.project == nil || subtitles.isRunning)
                ForEach(SubtitleExportMode.allCases) { mode in
                    Button("导出\(mode.title) SRT…") { if let project = model.project { subtitles.export(project, mode: mode) } }.disabled(model.currentSubtitleTrack == nil)
                }
            }
            CommandMenu("标记与片段") {
                Button("创建镜头反馈") { model.addNote(track: .camera) }.keyboardShortcut("1", modifiers: [.command, .shift]).disabled(model.project == nil)
                Button("创建声音反馈") { model.addNote(track: .sound) }.keyboardShortcut("2", modifiers: [.command, .shift]).disabled(model.project == nil)
                Button("创建叙事反馈") { model.addNote(track: .story) }.keyboardShortcut("3", modifiers: [.command, .shift]).disabled(model.project == nil)
                Button("创建学习灵感") { model.addNote(track: .learning) }.keyboardShortcut("4", modifiers: [.command, .shift]).disabled(model.project == nil)
                Divider()
                Button("收集片段到灵感空间…") { model.requestCapture() }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(model.project == nil)
                Button("重命名当前项目…") { model.requestRename() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.project == nil)
                Button("导入音乐或音效…") { model.importMusic() }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(model.project == nil)
            }
            CommandGroup(replacing: .help) { Button("拉片方法与快捷键") { model.showHelp = true } }
        }
    }
}
