import SwiftUI
import UniformTypeIdentifiers

struct ScriptDraftKey: Hashable {
    let projectID: UUID
    let analysisID: UUID
}

@MainActor final class ScriptWorkspaceModel: ObservableObject {
    @Published var showWorkspace = false
    @Published var showConfiguration = false
    @Published var configuration = ScriptRelayConfiguration() {
        didSet {
            if oldValue.credentialAccount != configuration.credentialAccount {
                keyDraft = ""
                credentialNeedsAuthorization = false
                refreshKeyStatus()
            }
        }
    }
    @Published var keyDraft = ""
    @Published var keyIsSaved = false
    @Published private(set) var credentialNeedsAuthorization = false
    @Published var availableModels: [String] = []
    @Published var isFetchingModels = false
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var status = ""
    @Published var error: String?
    @Published var rangeStart = 0.0
    @Published var rangeEnd = 0.0
    @Published var style: ScriptStyle = .shotScript
    @Published var focus = ""
    @Published var transcript = ""
    @Published var drafts: [ScriptDraftKey: ScriptAnalysis] = [:]
    @Published var unsavedAnalysisIDs: Set<ScriptDraftKey> = []
    @Published var selectedAnalysisID: UUID?
    @Published var workspaceProjectID: UUID?
    @Published var outputFocusID: UUID?
    @Published var showReader = true {
        didSet { if persistent { UserDefaults.standard.set(showReader, forKey: "scriptReaderVisible") } }
    }
    @Published var autoGenerateOnOpen = true {
        didSet { if persistent { UserDefaults.standard.set(autoGenerateOnOpen, forKey: "scriptAutoGenerateOnOpen") } }
    }
    @Published private(set) var automaticGenerationHint: String?
    @Published private(set) var responses: [ScriptResponseRecord] = []
    @Published private(set) var responseStorageWarning: String?
    private let responseArchive = ScriptResponseArchive()
    private var readingSelections: [UUID: UUID] = [:]
    private let persistent: Bool
    private let client: ScriptRelayClient
    private let subtitleWorkspace: SubtitleWorkspaceModel?
    private var task: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var generation = UUID()
    private var automaticTask: Task<Void, Never>?
    private var automaticCandidateID: UUID?
    private var automaticSchedule = UUID()
    // An unsuccessful or cancelled request is retried explicitly, never by a
    // view refresh or by switching away and back during the same app session.
    private var automaticAttempts: Set<UUID> = []
    private let credentials: ScriptCredentialSession
    private let preferencesKey = "scriptRelayConfiguration.v1"
    private var savedConfiguration: ScriptRelayConfiguration?

    init(persistent: Bool = true, client: ScriptRelayClient = ScriptRelayClient(), credentials: ScriptCredentialSession? = nil, subtitles: SubtitleWorkspaceModel? = nil) {
        self.persistent = persistent; self.client = client; self.subtitleWorkspace = subtitles
        self.credentials = credentials ?? (persistent
            ? ScriptCredentialSession(read: { try ScriptKeychain.load(account: $0) },
                write: { try ScriptKeychain.save($0, account: $1) }, exists: { ScriptKeychain.contains(account: $0) },
                authorize: { try ScriptKeychain.authorize(account: $0) })
            : .memoryOnly())
        if persistent, let value = UserDefaults.standard.object(forKey: "scriptReaderVisible") as? Bool { showReader = value }
        if persistent, let value = UserDefaults.standard.object(forKey: "scriptAutoGenerateOnOpen") as? Bool { autoGenerateOnOpen = value }
        if persistent, let data = UserDefaults.standard.data(forKey: preferencesKey),
           let saved = try? JSONDecoder().decode(ScriptRelayConfiguration.self, from: data) {
            configuration = saved; savedConfiguration = saved
        }
        if persistent { responses = responseArchive.load() }
        refreshKeyStatus()
    }
    func refreshKeyStatus() {
        keyIsSaved = credentials.contains(account: configuration.credentialAccount)
    }
    func syncProject(studio: StudioModel) {
        guard workspaceProjectID != studio.project?.id else { return }
        if let projectID = workspaceProjectID, let selection = selectedAnalysisID { readingSelections[projectID] = selection }
        if let project = studio.project {
            workspaceProjectID = project.id; rangeStart = 0; rangeEnd = min(project.duration, 300)
            selectedAnalysisID = project.scriptAnalyses.first { $0.id == readingSelections[project.id] }?.id ?? project.scriptAnalyses.last?.id
            focus = ""; transcript = ""; error = nil
            if !isRunning { status = "" }
        } else {
            workspaceProjectID = nil; selectedAnalysisID = nil
        }
    }
    func projectDidOpen(studio: StudioModel) {
        syncProject(studio: studio)
        automaticTask?.cancel(); automaticTask = nil; automaticSchedule = UUID()
        automaticCandidateID = autoGenerateOnOpen ? studio.project?.id : nil
        automaticGenerationHint = nil
        resumeAutomaticGeneration(studio: studio)
    }
    func automaticGenerationPreferenceChanged(studio: StudioModel) {
        projectDidOpen(studio: studio)
    }
    func resumeAutomaticGeneration(studio: StudioModel) {
        guard autoGenerateOnOpen, let id = automaticCandidateID,
              let project = studio.project, project.id == id, workspaceProjectID == id else { return }
        guard project.scriptAnalyses.isEmpty else {
            automaticCandidateID = nil; automaticGenerationHint = nil; return
        }
        guard !automaticAttempts.contains(id) else {
            automaticCandidateID = nil
            automaticGenerationHint = "本次已尝试生成，可点击“生成脚本”手动重试。"
            return
        }
        guard !project.videoClips.isEmpty, project.duration.isFinite, project.duration > 0 else {
            automaticGenerationHint = "加入视频后，打开项目即可自动生成脚本。"; return
        }
        guard project.duration <= 300 else {
            automaticGenerationHint = "视频超过 5 分钟，请点击“生成脚本”选择范围，分段生成。"; return
        }
        guard let savedConfiguration, configuration == savedConfiguration else {
            automaticGenerationHint = "请先保存模型设置，再自动生成脚本。"; return
        }
        guard (try? savedConfiguration.validate()) != nil,
              credentials.contains(account: configuration.credentialAccount) else {
            automaticGenerationHint = "先在模型设置中保存连接和 Key，之后打开项目即可自动生成。"; return
        }
        guard studio.mediaAvailable else {
            automaticGenerationHint = "视频准备好后自动生成；请确保原素材仍在本机。"; return
        }
        guard !studio.busy, !isRunning, !isFetchingModels, !showWorkspace else {
            automaticGenerationHint = "等待当前操作完成后，自动生成这个项目的脚本。"; return
        }
        guard automaticTask == nil else { return }
        let token = automaticSchedule
        automaticTask = Task { [weak self, weak studio] in
            do { try await Task.sleep(nanoseconds: 450_000_000) }
            catch { return }
            guard let self, let studio, self.automaticSchedule == token else { return }
            self.automaticTask = nil
            guard self.autoGenerateOnOpen, self.automaticCandidateID == id,
                  studio.project?.id == id, self.workspaceProjectID == id,
                  let current = studio.project, current.scriptAnalyses.isEmpty,
                  !current.videoClips.isEmpty, current.duration.isFinite,
                  current.duration > 0, current.duration <= 300,
                  !self.automaticAttempts.contains(id), studio.mediaAvailable,
                  !studio.busy, !self.isRunning, !self.isFetchingModels, !self.showWorkspace,
                  self.savedConfiguration == self.configuration,
                  (try? self.configuration.validate()) != nil,
                  self.credentials.contains(account: self.configuration.credentialAccount) else {
                self.resumeAutomaticGeneration(studio: studio); return
            }
            self.automaticCandidateID = nil
            self.automaticAttempts.insert(id)
            self.automaticGenerationHint = nil
            self.rangeStart = 0; self.rangeEnd = current.duration
            self.focus = ""; self.transcript = ""
            if !studio.showSubtitleReader { self.showReader = true }
            self.analyze(studio: studio, automatic: true)
        }
    }
    func present(studio: StudioModel, settings: Bool = false) {
        studio.dismissTextFocus(); studio.player.pause(); studio.isPlaying = false
        syncProject(studio: studio)
        showConfiguration = settings || (!keyIsSaved && selectedAnalysis(studio: studio) == nil)
        showWorkspace = true
    }
    func saveConfiguration() {
        // Normalizing the account can trigger didSet and clear the field. Keep
        // this explicit save's draft until validation and storage succeed.
        let pendingKey = keyDraft
        do {
            configuration.baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration.appID = configuration.appID.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration.modelID = configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration.providerModel = configuration.providerModel.trimmingCharacters(in: .whitespacesAndNewlines)
            try configuration.validate(requireModel: false)
            if !pendingKey.isEmpty {
                try credentials.save(pendingKey, account: configuration.credentialAccount)
                credentialNeedsAuthorization = false
                keyDraft = ""
            }
            if persistent { UserDefaults.standard.set(try JSONEncoder().encode(configuration), forKey: preferencesKey) }
            savedConfiguration = configuration
            refreshKeyStatus(); status = keyIsSaved ? "配置已保存，Key 存放在 macOS 钥匙串" : "接口配置已保存，请填写 Key 后开始分析"
            error = nil
        } catch {
            keyDraft = pendingKey
            if error as? ScriptCredentialError == .authorizationRequired { credentialNeedsAuthorization = true }
            self.error = error.localizedDescription
        }
    }
    /// All background and generation paths use silent reads. Only the settings
    /// button below is allowed to request macOS authorization UI.
    private func savedKey(for account: String) throws -> String? {
        do {
            let key = try credentials.key(for: account)
            if account == configuration.credentialAccount { credentialNeedsAuthorization = false }
            return key
        } catch {
            if error as? ScriptCredentialError == .authorizationRequired,
               account == configuration.credentialAccount { credentialNeedsAuthorization = true }
            throw error
        }
    }
    func authorizeSavedKey() {
        guard !isRunning, !isFetchingModels else { return }
        do {
            try configuration.validate(requireModel: false)
            guard let key = try credentials.authorize(account: configuration.credentialAccount), !key.isEmpty else {
                refreshKeyStatus()
                throw ScriptRelayError.message("没有找到这个服务和 AppID 对应的 Key，请填写后保存。")
            }
            credentialNeedsAuthorization = false; keyIsSaved = true; error = nil
            status = "已授权读取；本次运行中的脚本和字幕共用此 Key，可重试刚才的操作。"
        } catch {
            if error as? ScriptCredentialError == .authorizationRequired || error as? ScriptCredentialError == .cancelled {
                credentialNeedsAuthorization = true
            }
            self.error = error.localizedDescription
        }
    }
    private func resolvedKey() throws -> String {
        if !keyDraft.isEmpty {
            guard ScriptRelayConfiguration.validHeader(keyDraft) else { throw ScriptRelayError.message("Key 不能包含空格或换行。") }
            return keyDraft
        }
        let saved = try savedKey(for: configuration.credentialAccount)
        guard let saved, !saved.isEmpty else { throw ScriptRelayError.message("请先在模型设置中填写你的 Key。") }
        return saved
    }
    var subtitleTranslationModelID: String? { savedConfiguration?.modelID }
    func subtitleTranslationAccess() throws -> (ScriptRelayConfiguration, String) {
        guard let config = savedConfiguration else { throw ScriptRelayError.message("请先在模型设置中保存翻译服务配置。") }
        try config.validate()
        guard let key = try savedKey(for: config.credentialAccount), !key.isEmpty else {
            throw ScriptRelayError.message("请先在模型设置中保存 Key，再翻译中文字幕。")
        }
        return (config, key)
    }
    func fetchModels() {
        guard !isFetchingModels, !isRunning else { return }
        do {
            try configuration.validate(requireModel: false); let key = try resolvedKey(); let config = configuration
            isFetchingModels = true; error = nil
            listTask = Task {
                defer { isFetchingModels = false }
                do {
                    availableModels = try await client.models(configuration: config, key: key)
                    status = availableModels.contains(config.modelID) ? "连接成功，已找到当前模型" : "连接成功，请从列表选择所需模型"
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func analyze(studio: StudioModel, automatic: Bool = false) {
        guard !isRunning, let project = studio.projects.first(where: {$0.id == workspaceProjectID}) else { return }
        do {
            let config: ScriptRelayConfiguration
            if automatic {
                guard let savedConfiguration, savedConfiguration == configuration else {
                    throw ScriptRelayError.message("请先保存模型设置，再自动生成脚本。")
                }
                config = savedConfiguration
            } else { config = configuration }
            try config.validate()
            let key: String
            if automatic {
                guard let saved = try savedKey(for: config.credentialAccount), !saved.isEmpty else {
                    throw ScriptRelayError.message("请先在模型设置中保存你的 Key。")
                }
                key = saved
            } else { key = try resolvedKey() }
            guard rangeStart.isFinite, rangeEnd.isFinite, rangeStart >= 0, rangeEnd <= project.duration,
                  rangeEnd > rangeStart, rangeEnd - rangeStart <= 300 else {
                throw ScriptRelayError.message("请选择项目内 0–300 秒的有效片段；长视频可分段反解。")
            }
            guard focus.count <= 4000, transcript.count <= 30000 else { throw ScriptRelayError.message("关注点最多 4000 字，补充台词最多 30000 字。") }
            let start = rangeStart, end = rangeEnd
            let selectedStyle = style, selectedFocus = focus, suppliedTranscript = transcript
            generation = UUID(); let token = generation
            automaticAttempts.insert(project.id)
            if automaticCandidateID == project.id { automaticCandidateID = nil }
            automaticGenerationHint = nil
            error = nil; isRunning = true; progress = 0; status = "正在准备所选视频 · \(project.title)"
            task = Task { [self] in
                defer {
                    if generation == token {
                        isRunning = false; task = nil
                        resumeAutomaticGeneration(studio: studio)
                    }
                }
                var inputMode = "\(selectedStyle.title) · \(config.thinkingMode.title) · 尚未取得视频与台词证据"
                var evidenceProject = project
                do {
                    var noSpeech = false
                    if let existing = project.subtitleTrack, existing.isCurrent(for: project) {
                        status = "正在复用已识别的原文、中文和时间位置"
                    } else {
                        guard let subtitleWorkspace else {
                            throw ScriptRelayError.message("共享字幕识别服务尚未就绪，请重新打开镜读后重试。")
                        }
                        status = "正在准备共用台词：本地识别人声，并翻译中文字幕…"
                        do {
                            evidenceProject.subtitleTrack = try await subtitleWorkspace.ensureTrack(for: project, studio: studio, scripts: self)
                        } catch SubtitlePipelineError.noSpeech {
                            noSpeech = true
                            status = "未识别到人声，继续按画面生成脚本；不生成推测台词"
                        }
                    }
                    try Task.checkCancellation()
                    let snapshot = SubtitleTrack(sourceClips: project.videoClips, cues: [], sourceDescription: "")
                    guard let current = studio.projects.first(where: { $0.id == project.id }), snapshot.isCurrent(for: current) else {
                        throw ScriptRelayError.message("准备台词期间视频素材发生了变化，请重新生成；已有字幕保留。")
                    }
                    // Use the current shared track, including edits made while a
                    // different consumer was finishing recognition.
                    evidenceProject.subtitleTrack = current.subtitleTrack.flatMap { $0.isCurrent(for: current) ? $0 : nil }
                    let prompt = ScriptPrompt.make(project: evidenceProject, start: start, end: end, style: selectedStyle, focus: selectedFocus, transcript: suppliedTranscript)
                    let audioEvidence = noSpeech ? "本地识别未取得人声，仅依据画面；不包含原声/BGM/音效理解" : (evidenceProject.subtitleTrack?.sourceDescription ?? "未取得语音证据")
                    inputMode = "\(selectedStyle.title) · \(config.thinkingMode.title) · 视频画面（服务默认采样）；\(audioEvidence)"
                    let media = try await ScriptMediaPreparer.prepare(project, rangeStart: start, rangeEnd: end) { [weak self] value in
                        Task { @MainActor in if self?.generation == token { self?.progress = value * 0.35 } }
                    }
                    defer { media.cleanup() }
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    guard let prepared = studio.projects.first(where: { $0.id == project.id }), snapshot.isCurrent(for: prepared) else {
                        throw ScriptRelayError.message("准备视频期间素材发生了变化，请重新生成；已有字幕保留。")
                    }
                    status = "\(project.title) · 正在调用模型 · 已准备 \(String(format: "%.1f", Double(media.byteCount) / 1048576)) MB 视频"
                    progress = 0.4
                    let text = try await client.analyze(configuration: config, key: key, videoURL: media.videoURL, prompt: prompt)
                    try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
                    progress = 0.9; status = "正在整理脚本和时间位置"
                    let response = ScriptResponseRecord(project: evidenceProject, rangeStart: start, rangeEnd: end,
                        modelID: config.modelID, inputMode: inputMode, text: text)
                    retain(response)
                    try storeResult(response.parse(), projectID: project.id, studio: studio)
                } catch is CancellationError { if generation == token { status = "已取消反解"; progress = 0 } }
                catch ScriptRelayError.incompleteResponse(let text) {
                    if generation == token {
                        var response = ScriptResponseRecord(project: evidenceProject, rangeStart: start, rangeEnd: end,
                            modelID: config.modelID, inputMode: inputMode, text: text)
                        response.isIncomplete = true; retain(response)
                        self.error = "模型回复尚未完成，已保留原文供导出查看。可缩短选段后重新生成。"
                        status = "未保存为完整脚本，已有记录保留"
                    }
                }
                catch { if generation == token { self.error = error.localizedDescription; status = "本次未生成脚本，已有记录保留" } }
            }
        } catch {
            self.error = error.localizedDescription
            if !automatic { showConfiguration = !keyIsSaved || credentialNeedsAuthorization }
        }
    }
    private func retain(_ response: ScriptResponseRecord) {
        responses.insert(response, at: 0)
        responses = Array(responses.prefix(ScriptResponseArchive.limit))
        responseStorageWarning = nil
        if persistent {
            do { try responseArchive.save(response) }
            catch { responseStorageWarning = "回复暂存于内存，未能写入本地：\(error.localizedDescription)" }
        }
    }
    func recoverableResponse(studio: StudioModel) -> ScriptResponseRecord? {
        guard let project = studio.projects.first(where: { $0.id == workspaceProjectID }),
              let response = responses.first(where: { response in
                  response.project.id == project.id && !project.scriptAnalyses.contains(where: { $0.id == response.id })
              }) else { return nil }
        return response
    }
    func recoverResponse(studio: StudioModel) {
        guard !isRunning, let response = recoverableResponse(studio: studio) else { return }
        do {
            let result = try response.parse()
            guard let project = studio.projects.first(where: { $0.id == response.project.id }), result.isCurrent(for: project) else {
                throw ScriptRelayError.message("素材已调整，这份回复对应旧版本。可以导出原文查看。")
            }
            try storeResult(result, projectID: response.project.id, studio: studio)
        } catch { self.error = error.localizedDescription; status = "回复已保留，暂时无法整理成脚本" }
    }
    func exportResponse(studio: StudioModel) {
        guard let response = recoverableResponse(studio: studio) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        panel.title = "导出模型回复"; panel.nameFieldStringValue = "模型回复-\(response.id.uuidString.prefix(8)).txt"
        if panel.runModal() == .OK, let url = panel.url {
            do { try response.text.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func storeResult(_ result: ScriptAnalysis, projectID: UUID, studio: StudioModel) throws {
        guard var latest = studio.projects.first(where: { $0.id == projectID }) else {
            throw ScriptRelayError.message("原项目已移出作品库，回复已保留，无法保存脚本。")
        }
        // Stable response identity makes local recovery idempotent.
        if let index = latest.scriptAnalyses.firstIndex(where: { $0.id == result.id }) { latest.scriptAnalyses[index] = result }
        else { latest.scriptAnalyses.append(result) }
        if latest.scriptAnalyses.count > 20 { latest.scriptAnalyses.removeFirst(latest.scriptAnalyses.count - 20) }
        let saved = studio.updateAndSave(latest)
        if saved { unsavedAnalysisIDs.removeAll(); self.error = nil }
        else {
            unsavedAnalysisIDs.insert(ScriptDraftKey(projectID: projectID, analysisID: result.id))
            self.error = studio.error ?? "脚本未能存入作品库，请先导出备份。"
        }
        progress = 1
        status = "\(latest.title) · 反解完成 · \(result.segments.count) 个段落，" + (saved ? "已保存" : "尚未存入作品库，请导出或重试保存")
        if workspaceProjectID == projectID {
            selectedAnalysisID = result.id; showConfiguration = false
            if studio.selectedID == projectID { showReader = true; outputFocusID = result.id }
        }
    }
    func cancel() {
        task?.cancel(); status = "正在取消…"
    }
    func selectedAnalysis(studio: StudioModel) -> ScriptAnalysis? {
        let project = studio.projects.first { $0.id == workspaceProjectID }
        return project?.scriptAnalyses.first { $0.id == selectedAnalysisID } ?? project?.scriptAnalyses.last
    }
    func saveAnalysis(_ analysis: ScriptAnalysis, studio: StudioModel) {
        do { try ProjectPersistence.validateScriptAnalysis(analysis) }
        catch { self.error = error.localizedDescription; status = "请修正脚本内容后再保存，已有记录保留"; return }
        guard var project = studio.projects.first(where: {$0.id == workspaceProjectID}),
              let i = project.scriptAnalyses.firstIndex(where: {$0.id == analysis.id}) else { return }
        project.scriptAnalyses[i] = analysis
        if studio.updateAndSave(project) {
            drafts.removeValue(forKey: ScriptDraftKey(projectID: project.id, analysisID: analysis.id)); unsavedAnalysisIDs.removeAll()
            status = "脚本修改已保存"; error = nil
        } else { unsavedAnalysisIDs.insert(ScriptDraftKey(projectID: project.id, analysisID: analysis.id)); error = studio.error; status = "修改仍在内存中，请导出备份或重试保存" }
    }
    func play(_ segment: ScriptSegment, analysis: ScriptAnalysis, studio: StudioModel) {
        guard let project = studio.projects.first(where: {$0.id == workspaceProjectID}), analysis.isCurrent(for: project) else {
            error = "素材已调整，这份脚本对应旧版本。请重新反解后定位回看。"; return
        }
        if studio.selectedID != project.id { studio.select(project.id) }
        showWorkspace = false
        studio.playNote(StudyNote(start: segment.start, end: segment.end, track: .story, title: "脚本回看", body: "", takeaway: ""))
    }
    func addToTimeline(_ analysis: ScriptAnalysis, studio: StudioModel) {
        guard var project = studio.projects.first(where: {$0.id == workspaceProjectID}), analysis.isCurrent(for: project),
              let i = project.scriptAnalyses.firstIndex(where: {$0.id == analysis.id}) else { error = "素材已调整，请重新反解后添加到时间轴。"; return }
        guard project.scriptAnalyses[i].timelineNoteIDs.isEmpty else { status = "这份脚本已经加入时间轴"; return }
        let subtitles = ScriptReading.usableSubtitleTrack(for: analysis, project: project)
        let notes = analysis.segments.enumerated().map { index, segment in
            let cues = ScriptReading.displayCues(for: segment, in: analysis, subtitles: subtitles)
            var descriptions = ["完整脚本：" + ScriptReading.narrative(for: segment),
                "逐句台词：" + cues.map { ($0.speaker.isEmpty ? "" : $0.speaker + "：") + $0.text }.joined(separator: "\n"),
                "画面：" + segment.visual, "动作：" + segment.action]
            if subtitles == nil { descriptions.append("台词：" + segment.dialogue) }
            descriptions += ["声音：" + segment.sound, "镜头：" + segment.camera, "衔接：" + segment.transition,
                "待核对：" + segment.uncertainty]
            return StudyNote(start: segment.start, end: segment.end, track: .story,
                title: "脚本 \(index + 1) · " + String((segment.visual.isEmpty ? segment.action : segment.visual).prefix(80)),
                body: descriptions.joined(separator: "\n\n"),
                takeaway: "模型分析（需核对）：" + segment.reasoning)
        }
        project.notes += notes; project.scriptAnalyses[i].timelineNoteIDs = notes.map(\.id)
        if studio.updateAndSave(project) {
            unsavedAnalysisIDs.removeAll(); drafts.removeValue(forKey: ScriptDraftKey(projectID: project.id, analysisID: analysis.id))
            status = "已将 \(notes.count) 段脚本加入叙事轨，可以逐段回看和编辑"; error = nil
        } else { unsavedAnalysisIDs.insert(ScriptDraftKey(projectID: project.id, analysisID: analysis.id)); error = studio.error; status = "时间轴笔记仍在内存中，请导出备份或重试保存" }
    }
    func export(_ analysis: ScriptAnalysis, dialogueOnly: Bool = false, subtitles: SubtitleTrack? = nil) {
        do { try ProjectPersistence.validateScriptAnalysis(analysis) }
        catch { self.error = error.localizedDescription; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.title = dialogueOnly ? "导出台词" : "导出完整剧本"
        let safeName = analysis.title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        panel.nameFieldStringValue = String(safeName.prefix(100)) + (dialogueOnly ? "-台词.md" : "-完整剧本.md")
        if panel.runModal() == .OK, let url = panel.url {
            do { try (dialogueOnly ? analysis.exportDialogueMarkdown(subtitles: subtitles) : analysis.exportMarkdown(subtitles: subtitles)).write(to: url, atomically: true, encoding: .utf8); status = "脚本已导出" }
            catch { self.error = error.localizedDescription }
        }
    }
}
