import SwiftUI

private enum ScriptRangeChoice: String, CaseIterable { case whole = "整段视频", shot = "当前镜头", custom = "自定义范围" }

/// This sheet only prepares a generation request. Reading, history selection,
/// and video comparison belong to the main window's independent script pane.
struct ScriptWorkspaceSheet: View {
    @EnvironmentObject var studio: StudioModel
    @EnvironmentObject var scripts: ScriptWorkspaceModel
    @JingduState private var rangeChoice = ScriptRangeChoice.whole
    @JingduState private var showDetails = false

    private var project: FilmProject? { studio.projects.first { $0.id == scripts.workspaceProjectID } }
    private var rangeIsValid: Bool {
        guard let project else { return false }
        return scripts.rangeStart.isFinite && scripts.rangeEnd.isFinite && scripts.rangeStart >= 0 &&
            scripts.rangeEnd > scripts.rangeStart && scripts.rangeEnd <= project.duration &&
            scripts.rangeEnd - scripts.rangeStart <= 300
    }
    private var windowSize: CGSize {
        let window = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        let screen = (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let target = scripts.showConfiguration ? CGSize(width: 880, height: 620)
            : CGSize(width: 620, height: showDetails ? 650 : 560)
        return CGSize(width: max(320, min(target.width, screen.width - 48)),
                      height: max(320, min(target.height, screen.height - 72)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if scripts.showConfiguration {
                ScrollView { ScriptConfigurationView().padding(24) }
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView { requestForm.padding(24) }
                    .frame(maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .background(Color.panel).foregroundStyle(.white).preferredColorScheme(.dark)
        .onAppear {
            if scripts.rangeStart == 0 && scripts.rangeEnd == project?.duration { rangeChoice = .whole }
            else if let shot = studio.selectedShot, scripts.rangeStart == shot.start && scripts.rangeEnd == shot.end { rangeChoice = .shot }
            else { rangeChoice = .custom }
            showDetails = !scripts.focus.isEmpty || !scripts.transcript.isEmpty
        }
        .onChange(of: scripts.outputFocusID) { _, id in
            if id != nil { scripts.showWorkspace = false }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(scripts.showConfiguration ? "模型设置" : "生成脚本")
                    .font(.system(size: 18, weight: .semibold))
                Text(project?.title ?? "先配置模型，再导入视频")
                    .font(.system(size: 12)).foregroundStyle(Color.mutedText).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(scripts.showConfiguration ? "返回生成" : "模型设置") {
                scripts.showConfiguration.toggle()
            }.disabled(scripts.isRunning)
            Button("关闭") { scripts.showWorkspace = false }.keyboardShortcut(.cancelAction)
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var requestForm: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 9) {
                Text("脚本形式").font(.system(size: 13, weight: .medium))
                Picker("脚本形式", selection: $scripts.style) {
                    ForEach(ScriptStyle.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text(scripts.style == .screenplay ? "按故事顺序呈现场景、人物行动与对白。" : "保留完整故事与对白，并细化镜头和视听表达。")
                    .font(.system(size: 12)).foregroundStyle(Color.mutedText)
                HStack(spacing: 12) {
                    Picker("生成方式", selection: $scripts.configuration.thinkingMode) {
                        ForEach(ScriptRelayConfiguration.ThinkingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.fixedSize()
                    Text(scripts.configuration.thinkingMode == .standard ? "直接整理完整脚本" : "深入推敲，等待时间更长")
                        .font(.system(size: 11)).foregroundStyle(Color.mutedText)
                    Spacer(minLength: 0)
                }.padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("视频范围").font(.system(size: 13, weight: .medium))
                Picker("视频范围", selection: $rangeChoice) {
                    ForEach(ScriptRangeChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                    .onChange(of: rangeChoice) { _, choice in
                        if choice == .whole { scripts.rangeStart = 0; scripts.rangeEnd = project?.duration ?? 0 }
                        else if choice == .shot, let shot = studio.selectedShot {
                            scripts.rangeStart = shot.start; scripts.rangeEnd = shot.end
                        }
                    }
                if rangeChoice == .custom {
                    HStack {
                        NumericInput(title: "起点（秒）", value: $scripts.rangeStart)
                        NumericInput(title: "终点（秒）", value: $scripts.rangeEnd)
                    }
                    if studio.selectedNote != nil || studio.pendingIn != nil {
                        Button("使用当前标记区间") {
                            if let note = studio.selectedNote, note.end > note.start {
                                scripts.rangeStart = note.start; scripts.rangeEnd = note.end
                            } else if let start = studio.pendingIn {
                                scripts.rangeStart = min(start, studio.currentTime)
                                scripts.rangeEnd = max(start, studio.currentTime)
                            }
                        }.controlSize(.small)
                    }
                }
                Text("已选 \(String(format: "%.1f", max(0, scripts.rangeEnd - scripts.rangeStart))) 秒 · 每次最多 5 分钟")
                    .font(.system(size: 12)).foregroundStyle(rangeIsValid ? Color.mutedText : Color.orange)
                if !rangeIsValid, project != nil {
                    Text("请选择视频内起点早于终点、时长不超过 5 分钟的范围。")
                        .font(.system(size: 11)).foregroundStyle(Color.orange)
                }
            }
            DisclosureGroup("补充说明（可选）", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("研究主题，例如开场、反转或镜头衔接", text: $scripts.focus)
                        .textFieldStyle(.roundedBorder)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("补充台词 / 字幕").font(.system(size: 11)).foregroundStyle(Color.mutedText)
                        TextEditor(text: $scripts.transcript).font(.system(size: 13))
                            .scrollContentBackground(.hidden).padding(8).frame(height: 92)
                            .background(Color.studioBG, in: RoundedRectangle(cornerRadius: 6))
                    }
                }.padding(.top, 10)
            }.font(.system(size: 12)).tint(Color.mutedText)
            Text("台词复用字幕轨的原文、中文翻译与时间；没有字幕时先识别人声。场景、动作和镜头由模型结合画面与台词整理。")
                .font(.system(size: 11)).foregroundStyle(Color.mutedText).lineSpacing(3)
        }.disabled(scripts.isRunning)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = scripts.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.orange)
                    Text(error).font(.system(size: 12)).foregroundStyle(Color.orange)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { scripts.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭错误提示")
                }
            }
            if !scripts.isRunning, !scripts.showConfiguration, let response = scripts.recoverableResponse(studio: studio) {
                HStack(spacing: 12) {
                    Text(scripts.responseStorageWarning ?? "已保留回复 · " + String(format: "%.1f–%.1f 秒", response.rangeStart, response.rangeEnd))
                        .font(.system(size: 11)).foregroundStyle(Color.mutedText)
                    Spacer(minLength: 0)
                    Button("重新读取") { scripts.recoverResponse(studio: studio) }
                        .help("只读取已收到的回复，不再次调用模型")
                    Button("导出原文") { scripts.exportResponse(studio: studio) }
                }
            }
            if scripts.isRunning {
                ProgressView(value: scripts.progress).tint(Color.accent)
                HStack(spacing: 12) {
                    Text(scripts.status).font(.system(size: 12)).foregroundStyle(Color.mutedText)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("取消生成") { scripts.cancel() }
                }
            } else if scripts.showConfiguration {
                if !scripts.status.isEmpty {
                    Text(scripts.status).font(.system(size: 12)).foregroundStyle(Color.mutedText)
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("结果将显示在主窗口的脚本预览区。")
                            .font(.system(size: 12)).foregroundStyle(Color.mutedText)
                        Text("所选视频与补充内容将发送至已配置的模型服务。")
                            .font(.system(size: 10)).foregroundStyle(Color.mutedText)
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    StudioButton(title: "生成完整脚本", icon: "sparkles", accent: true) {
                        scripts.analyze(studio: studio)
                    }.disabled(!rangeIsValid || scripts.isFetchingModels)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
}

struct ScriptConfigurationView: View {
    @EnvironmentObject var scripts: ScriptWorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Seed2.1 · 中转服务设置").font(.system(size: 20, weight: .semibold))
            Text("填写你的服务地址、AppID、Key 和模型名称。已有连接设置会继续保留。").font(.system(size: 13)).foregroundStyle(Color.mutedText)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 15) {
                    field("服务地址", placeholder: "https://relay.example.com", text: $scripts.configuration.baseURL)
                    field("AppID", placeholder: "分配给你的业务 AppID", text: $scripts.configuration.appID)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Key").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mutedText)
                        SecureField(scripts.keyIsSaved ? "已保存在钥匙串；留空保留原 Key" : "填写你自己的中转 Key", text: $scripts.keyDraft).textFieldStyle(.roundedBorder)
                        Text("Key 存入 macOS 钥匙串，不进入项目或导出文件。生成和连接检查不会自动弹出系统授权。").font(.system(size: 11)).foregroundStyle(Color.mutedText)
                        if scripts.keyIsSaved || scripts.credentialNeedsAuthorization {
                            Button("授权读取已存 Key") { scripts.authorizeSavedKey() }
                                .font(.system(size: 12)).tint(Color.accent)
                            if scripts.credentialNeedsAuthorization {
                                Text("当前 Key 尚未获准读取。点击上方按钮完成系统授权后，再重试刚才的操作。")
                                    .font(.system(size: 11)).foregroundStyle(.orange)
                            }
                        }
                    }
                    field("模型名称", placeholder: "doubao-seed-2-1-pro-260628", text: $scripts.configuration.modelID)
                    if !scripts.availableModels.isEmpty {
                        Menu("从服务模型列表中选择") {
                            ForEach(scripts.availableModels.filter { $0.localizedCaseInsensitiveContains("seed-2-1") }, id: \.self) { id in Button(id) { scripts.configuration.modelID = id } }
                            Divider()
                            ForEach(scripts.availableModels.filter { !$0.localizedCaseInsensitiveContains("seed-2-1") }, id: \.self) { id in Button(id) { scripts.configuration.modelID = id } }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 16) {
                    Text("连接方式").font(.system(size: 15, weight: .semibold))
                    Picker("生成方式", selection: $scripts.configuration.thinkingMode) {
                        ForEach(ScriptRelayConfiguration.ThinkingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("标准生成直接整理脚本；深度分析会增加思考时间，较长视频可能触发中转超时。")
                        .font(.system(size: 11)).foregroundStyle(Color.mutedText)
                    Picker("请求格式", selection: $scripts.configuration.route) { ForEach(ScriptRelayConfiguration.Route.allCases, id: \.self) { Text($0.title).tag($0) } }
                    field("路由模型名（通常留空）", placeholder: "provider_model；留空使用模型名称", text: $scripts.configuration.providerModel)
                    HStack { Text("服务超时（秒）").font(.system(size: 12)); TextField("300", value: $scripts.configuration.timeout, format: .number).textFieldStyle(.roundedBorder).frame(width: 80) }
                    Text("默认 300 秒。超过 300 秒需由中转服务开通更长超时额度。").font(.system(size: 11)).foregroundStyle(Color.mutedText)
                    Text("请使用服务提供方给出的地址与请求格式；内网服务需要相应网络。更换地址或 AppID 后，请使用对应的 Key。").font(.system(size: 12)).foregroundStyle(Color.mutedText).lineSpacing(4)
                }.padding(18).frame(width: 340).background(Color.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 12) {
                StudioButton(title: "保存配置", icon: "lock", accent: true) { scripts.saveConfiguration() }
                StudioButton(title: scripts.isFetchingModels ? "正在读取…" : "检查连接 / 读取模型", icon: "arrow.triangle.2.circlepath") { scripts.fetchModels() }
                if scripts.keyIsSaved { Button("返回生成") { scripts.showConfiguration = false } }
            }
        }.disabled(scripts.isRunning || scripts.isFetchingModels)
        .onChange(of: scripts.configuration.baseURL) { _, _ in scripts.refreshKeyStatus() }
        .onChange(of: scripts.configuration.appID) { _, _ in scripts.refreshKeyStatus() }
    }
    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mutedText); TextField(placeholder, text: text).textFieldStyle(.roundedBorder) }
    }
}
