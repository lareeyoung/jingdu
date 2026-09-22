import SwiftUI

struct HelpSheet: View {
    @EnvironmentObject var model: StudioModel
    let workflows: [(String, String)] = [
        ("浏览时间轴", "触控板双指捏合缩放，双指左右滑动浏览；点击定位，方向键逐帧看。自动切镜的候选需要回看确认。"),
        ("导入多段素材", "多选视频后，可合并为一条时间轴或分别建立项目；“添加”还能把视频追加到当前项目。素材接缝始终可见。"),
        ("随看随记", "C 记镜头，S 记声音。新笔记直接进入正文；输入时可用 ⌘⇧1 / 2 / 3 / 4 创建四类笔记。按 Esc 或点击播放、播放器、时间轴退出输入。"),
        ("重命名项目", "点击顶部铅笔，或右键侧栏项目重命名。只改作品库名称，原视频文件名不变。"),
        ("收集到灵感空间", "用 I / O 标记区间，或选中一个镜头，再点“收集片段”。可新建空间，也能从不同项目继续加入同一个空间，保留来源、切点和笔记。"),
        ("排序、配乐与导出", "选中视频素材调整顺序和入出点；导入音乐后，可裁剪、拖动位置、在播放头处分割并调音量。“导出”可生成含音乐的 MP4。"),
        ("生成多语言字幕", "顶部“字幕”→“生成字幕”，自动识别中、英、日、韩、西、法语原声；非中文附中文译文，原文与中文分行。独立字幕轨可点击定位，侧栏可双向跟随、右键编辑和导出 SRT。原声本地识别，仅非中文文字发送到已配置的模型翻译。每次最多 30 分钟。"),
        ("反解视频脚本", "展开顶部“脚本”后点击“生成脚本”，或按 ⌘⇧J，选择剧情剧本或分镜脚本，再选视频范围。每次最多 5 分钟，研究主题与补充台词按需展开。点击“生成完整脚本”会发送最多 40 MB、720p 或更低的临时视频副本到你配置的中转服务。"),
        ("完整阅读与台词筛选", "默认按完整文稿阅读故事、动作、对白和视听表达。“台词”只筛选阅读内容，不删除全文中的对白。双语台词分行显示；开启双向跟随时，当前句以整条浅绿色高亮，暂停后仍保留当前位置。“脚本操作（⋯）”可导出完整剧本或单独台词 Markdown。"),
        ("台词与画面对照", "脚本拥有独立预览区。顶部布局菜单可选画面优先、左右对照、上下对照，拖动分隔条调整大小，⌘J 收起或展开。开启「双向跟随」后，播放或拖动时间轴自动滚动并高亮台词；点击台词定位画面和播放头，保持当前播放状态。关闭后独立阅读，开关自动记忆。"),
        ("核对与保存脚本", "新结果的逐句时间由模型估计，可在“编辑文字”中修订台词、说话人和起止秒数，再保存修改；旧对白明确标为段落定位。每项目保留最近 20 份，主动选择“加入时间轴笔记”才建立叙事笔记；剪辑或声音设置变化后需重新反解。")
    ]
    let questions: [(String, String, String)] = [
        ("叙事衔接", "新增信息与动作连续", "下一镜新增了什么信息？对照切点两侧的形状、运动和动作阶段。匹配剪辑可借相似元素连接画面；先写可见变化，再判断因果或象征。"),
        ("镜头设计", "景别、方向与视线", "由远到近后，多看见什么、少看见什么？左右方向是否变化，下一镜是否回应人物的视线？180 度规则帮助保持空间关系，越轴本身不等于错误。"),
        ("声音设计", "先入、延续与强弱", "先听片段：下一场声音先于画面进入是 J cut；上一场声音延续到下一画面是 L cut。对白、音乐、环境和动作声哪层突出？强声前是否有留白？波形须结合听感判断。"),
        ("可迁移技巧", "从发现到方法", "换掉角色和场景，什么关系仍然成立？写成“条件 → 操作 → 预期效果”。尝试删去一镜或移动切点几帧，记录信息和节奏的实际变化。")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("从“好看”走到“看懂”").font(.system(size: 24, weight: .semibold)); Text("镜读 1.5.3 · 先记证据，再把方法用进自己的创作。").font(.system(size: 13)).foregroundStyle(Color.mutedText) }; Spacer(); Button("完成") { model.showHelp = false }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("常用操作").font(.system(size: 15, weight: .semibold))
                    ForEach(Array(workflows.enumerated()), id: \.offset) { _, workflow in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(workflow.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accent)
                            Text(workflow.1).font(.system(size: 12)).lineSpacing(4).foregroundStyle(Color.mutedText)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("拉片时问自己").font(.system(size: 15, weight: .semibold)).padding(.top, 7)
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        HStack(alignment: .top, spacing: 16) { Text(String(format: "%02d", index + 1)).font(.system(size: 24, weight: .light, design: .monospaced)).foregroundStyle(NoteTrack.allCases[index].color); VStack(alignment: .leading, spacing: 7) { Text(question.0 + " · " + question.1).font(.system(size: 14, weight: .semibold)); Text(question.2).font(.system(size: 13)).lineSpacing(5).foregroundStyle(.white.opacity(0.7)) } }.padding(16).background(Color.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                    }
                    Text("快捷键").font(.system(size: 15, weight: .semibold)).padding(.top, 7)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        shortcut("Space", "播放 / 暂停"); shortcut("← / →", "前后逐帧"); shortcut("⇧ ← / →", "前后镜头"); shortcut("B", "在播放位置拆分镜头"); shortcut("C / S", "快速镜头 / 声音笔记"); shortcut("M", "在所选轨道添加笔记"); shortcut("⌘⇧1 / 2", "镜头 / 声音笔记"); shortcut("⌘⇧3 / 4", "叙事 / 学习笔记"); shortcut("I / O", "区间起点 / 终点"); shortcut("L", "循环当前镜头"); shortcut("⌘⇧K", "收集片段到灵感空间"); shortcut("⌘⇧J", "反解视频脚本"); shortcut("⌘⇧R", "重命名项目"); shortcut("⌘⇧A", "导入音乐或音效"); shortcut("Esc", "退出当前输入"); shortcut("⌘ Z", "撤销操作"); shortcut("⌘⇧Z", "重做操作")
                    }
                    Text("单字母快捷键在文字输入时保留给打字；⌘ 组合键在输入中也可使用。笔记标题可空，正文或心得会成为摘要；预览、记录状态和片尾标记会随编辑更新。").font(.system(size: 12)).foregroundStyle(Color.mutedText).lineSpacing(5)
                    Text("波形来自真实音轨的 RMS 音量包络，帮助看强弱、停顿和节奏；它不识别音效或声音含义，也不是逐采样峰值表。请结合实际聆听判断。").font(.system(size: 12)).foregroundStyle(Color.mutedText).lineSpacing(5)
                    Text("MP4 画幅跟随首段素材，最长边不超过 1920 像素，最高 60 fps；其他比例等比居中，必要时留黑边。排序、裁剪和音量设置会一起导出。").font(.system(size: 12)).foregroundStyle(Color.mutedText).lineSpacing(5)
                    Text("在模型设置填写服务提供方给出的地址、AppID 和 Key，点击“保存配置”，Key 会存入 macOS 钥匙串。普通调用只会静默读取；若提示需要授权，在设置中主动点击“授权读取已存 Key”，系统验证成功后本次运行共用缓存。再点“检查连接 / 读取模型”确认服务列表；默认 Seed2.1 Pro，也可选择 Turbo。返回工作台，选择视频范围与输出形式，再点“生成完整脚本”。").font(.system(size: 12)).foregroundStyle(Color.mutedText).lineSpacing(5).padding(.top, 8)
                    Text("脚本和字幕共用本机 Whisper 识别的人声、原文与时间位置；非中文文本使用已配置的 Seed 模型翻译。Seed 结合画面和这份台词整理完整脚本，不另外猜测对白。识别、翻译和设计解释仍需对照成片核对。").font(.system(size: 12)).foregroundStyle(Color.mutedText).lineSpacing(5)
                    Text("作品库、笔记与已保存脚本留在本机；JSON 备份不含媒体或中转账号信息，请同时保留原视频和音乐。“生成完整脚本”会发送所选范围的视频副本、关注点与补充文本；字幕功能本地识别人声，再发送非中文文字做中文翻译；连接检查不发送媒体。其他本地功能照常在本机完成，源文件不改写，临时副本在结束、失败或取消后清理。").font(.system(size: 12)).foregroundStyle(Color.mutedText).lineSpacing(5)
                    HStack { Link("剪辑原理", destination: URL(string: "https://open.library.okstate.edu/introfilmtv/part/editing/")!); Link("摄影原理", destination: URL(string: "https://open.library.okstate.edu/introfilmtv/part/cinematography/")!); Link("J / L cut", destination: URL(string: "https://helpx.adobe.com/uk/premiere/desktop/edit-projects/trim-clips/perform-j-cuts-and-l-cuts.html")!); Link("声音与音乐", destination: URL(string: "https://www.oscars.org/sites/oscars/files/complete_sound_and_music_activities_guide.pdf")!) }.font(.system(size: 11)).tint(Color.accent)
                }
            }
        }.padding(28).frame(width: 680, height: 700).background(Color.panel)
    }
    func shortcut(_ key: String, _ description: String) -> some View { HStack { Text(key).font(.system(size: 11, weight: .medium, design: .monospaced)).frame(width: 77, height: 26).background(Color.elevated, in: RoundedRectangle(cornerRadius: 5)); Text(description).font(.system(size: 12)).foregroundStyle(Color.mutedText) } }
}
