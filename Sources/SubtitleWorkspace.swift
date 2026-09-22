import SwiftUI
import UniformTypeIdentifiers

enum SubtitlePipelineError: LocalizedError {
    case noSpeech
    var errorDescription: String? { "没有识别到可用的人声字幕；视频可能没有音轨、只有静音或没有可识别的对白。" }
}

@MainActor final class SubtitleWorkspaceModel: ObservableObject {
    @Published var showGeneration = false
    @Published var languageCode = "auto"
    @Published private(set) var isRunning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published var error: String?
    @Published var exportError: String?
    @Published private(set) var taskProjectID: UUID?
    @Published private(set) var canRetryTranslation = false
    typealias Transcription = (FilmProject, SubtitleLanguage?, @escaping @Sendable (Double, String) -> Void) async throws -> [SubtitleCue]
    private let transcribe: Transcription
    private let translator: SubtitleTranslator
    init(transcribe: @escaping Transcription = { project, language, progress in
        try await SubtitleTranscriber.transcribe(project: project, language: language, progress: progress)
    }, translator: SubtitleTranslator = SubtitleTranslator()) {
        self.transcribe = transcribe; self.translator = translator
    }
    private var task: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private var generation = UUID()
    private var activeProject: FilmProject?
    private var waiters: [UUID: CheckedContinuation<SubtitleTrack, Error>] = [:]
    private var pending: (FilmProject, [SubtitleCue])?

    /// Scripts and the subtitle UI share one recognition/translation operation.
    /// A valid saved track is reused without touching credentials or the network.
    func ensureTrack(for project: FilmProject, studio: StudioModel, scripts: ScriptWorkspaceModel) async throws -> SubtitleTrack {
        try await requestTrack(for: project, studio: studio, scripts: scripts, regenerate: false, retry: retryAvailable(for: project))
    }

    func generate(studio: StudioModel, scripts: ScriptWorkspaceModel, retry: Bool = false) {
        guard !isRunning, manualTask == nil, let project = studio.project else { return }
        showGeneration = false; studio.showSubtitleReader = true
        isRunning = true; taskProjectID = project.id; error = nil
        manualTask = Task { [self] in
            defer { manualTask = nil; if task == nil { isRunning = false } }
            do {
                let track = try await requestTrack(for: project, studio: studio, scripts: scripts, regenerate: true, retry: retry)
                if studio.selectedID == project.id { studio.notify("已生成 \(track.cues.count) 条字幕") }
            } catch {
                if error is CancellationError { if task == nil { status = "已取消生成" } }
                else if self.error == nil { self.error = error.localizedDescription }
            }
        }
    }

    private func requestTrack(for project: FilmProject, studio: StudioModel, scripts: ScriptWorkspaceModel,
                              regenerate: Bool, retry: Bool) async throws -> SubtitleTrack {
        try Task.checkCancellation()
        let snapshot = SubtitleTrack(sourceClips: project.videoClips, cues: [], sourceDescription: "")
        guard let current = studio.projects.first(where: { $0.id == project.id }), snapshot.isCurrent(for: current) else {
            throw ScriptRelayError.message("视频素材已变化，请重新开始；已有字幕保留。")
        }
        if !regenerate, let track = current.subtitleTrack, track.isCurrent(for: current) { return track }
        if let task, task.isCancelled {
            // The prior worker must finish cleaning up before another request
            // can start; never attach a new consumer to a cancelled operation.
            await task.value
            return try await requestTrack(for: project, studio: studio, scripts: scripts, regenerate: regenerate, retry: retry)
        }
        if let activeProject {
            guard activeProject.id == current.id,
                  SubtitleTrack(sourceClips: activeProject.videoClips, cues: [], sourceDescription: "").isCurrent(for: current) else {
                throw ScriptRelayError.message("另一段视频的字幕正在识别，请等待完成或取消后重试。")
            }
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiters[waiterID] = continuation
                if task == nil { begin(current, studio: studio, scripts: scripts, retry: retry) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        // Cancelling a script does not cancel subtitles explicitly requested by
        // the user. The worker stops once no consumer still needs its result.
        if waiters.isEmpty { task?.cancel() }
    }

    private func begin(_ project: FilmProject, studio: StudioModel, scripts: ScriptWorkspaceModel, retry: Bool) {
        let language = SubtitleLanguage(rawValue: languageCode)
        let token = UUID(); generation = token; activeProject = project
        isRunning = true; taskProjectID = project.id; error = nil; progress = 0; canRetryTranslation = false
        task = Task { [self] in
            var translationFinished = false
            let result: Result<SubtitleTrack, Error>
            do {
                let raw: [SubtitleCue]
                if retry, let retained = pending, retained.0.id == project.id,
                   SubtitleTrack(sourceClips: retained.0.videoClips, cues: [], sourceDescription: "").isCurrent(for: project) {
                    raw = retained.1
                } else {
                    pending = nil; status = "正在识别人声和语言…"
                    do {
                        raw = try await transcribe(project, language) { [weak self] amount, message in
                            Task { @MainActor in
                                guard let self, self.generation == token, self.isRunning else { return }
                                self.progress = amount * 0.7; self.status = message
                            }
                        }
                    } catch SubtitleTranscriber.Failure.noSpeech { throw SubtitlePipelineError.noSpeech }
                }
                try Task.checkCancellation()
                guard !raw.isEmpty else { throw SubtitlePipelineError.noSpeech }
                pending = (project, raw)
                var translated = raw
                var sourceDescription = "本地 Whisper small / whisper.cpp 语音识别"
                if raw.contains(where: { $0.language != .zh }) {
                    status = "原文已识别，正在翻译中文字幕…"; progress = 0.7
                    let (config, key) = try scripts.subtitleTranslationAccess()
                    translated = try await translator.translate(raw, configuration: config, key: key) { [weak self] amount in
                        Task { @MainActor in
                            guard let self, self.generation == token, self.isRunning else { return }
                            self.progress = 0.7 + amount * 0.3
                        }
                    }
                    sourceDescription += " · \(config.modelID) 中文翻译"
                }
                try Task.checkCancellation()
                let track = SubtitleTrack(sourceClips: project.videoClips, cues: translated, sourceDescription: sourceDescription)
                guard var current = studio.projects.first(where: { $0.id == project.id }), track.isCurrent(for: current) else {
                    throw ScriptRelayError.message("识别期间视频素材发生了变化，请重新生成；已有字幕保留。")
                }
                guard current.subtitleTrack == project.subtitleTrack else {
                    throw ScriptRelayError.message("识别期间字幕已被修改，本次结果未覆盖你的修改；请确认后重新生成。")
                }
                current.subtitleTrack = track; translationFinished = true
                guard studio.updateAndSave(current) else {
                    throw ScriptRelayError.message(studio.error ?? "字幕尚未保存，请先导出项目备份。")
                }
                pending = nil; progress = 1; status = "已生成 \(translated.count) 条字幕"
                result = .success(track)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    status = "已取消生成"; pending = nil; result = .failure(CancellationError())
                } else {
                    self.error = error.localizedDescription; status = "字幕尚未完成"
                    canRetryTranslation = pending != nil && !translationFinished
                    result = .failure(error)
                }
            }
            guard generation == token else { return }
            let completed = Array(waiters.values)
            waiters.removeAll(); task = nil; activeProject = nil; isRunning = false
            for waiter in completed { waiter.resume(with: result) }
        }
    }
    func cancel() { manualTask?.cancel(); task?.cancel() }
    func chooseModel() {
        let panel = NSOpenPanel(); panel.title = "选择本地多语言语音模型"; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do { try SubtitleTranscriber.selectModelURL(url); error = nil; status = "语音模型已就绪" }
            catch { self.error = error.localizedDescription }
        }
    }
    func retryAvailable(for project: FilmProject?) -> Bool {
        guard canRetryTranslation, let project, let pending, pending.0.id == project.id else { return false }
        return SubtitleTrack(sourceClips: pending.0.videoClips, cues: [], sourceDescription: "").isCurrent(for: project)
    }
    func export(_ project: FilmProject, mode: SubtitleExportMode) {
        guard let track = project.subtitleTrack, track.isCurrent(for: project) else { return }
        do {
            let content = try track.exportSRT(mode: mode)
            let panel = NSSavePanel(); panel.title = "导出字幕"; panel.nameFieldStringValue = project.title + "-" + mode.title + ".srt"
            panel.allowedContentTypes = [.init(filenameExtension: "srt") ?? .plainText]
            if panel.runModal() == .OK, let url = panel.url { try content.write(to: url, atomically: true, encoding: .utf8) }
        } catch { self.exportError = error.localizedDescription }
    }
}

extension StudioModel {
    var currentSubtitleTrack: SubtitleTrack? {
        guard let project, let track = project.subtitleTrack, track.isCurrent(for: project) else { return nil }
        return track
    }
    func selectSubtitle(_ cue: SubtitleCue) {
        dismissTextFocus(); selectedSubtitleID = cue.id; showSubtitleReader = true
        selectedNoteID = nil; selectedClipID = nil; selectedMusicID = nil
        loopShot = false; seek(cue.start)
    }
    func saveSubtitle(_ cue: SubtitleCue) -> Bool {
        guard var project, var track = currentSubtitleTrack,
              let index = track.cues.firstIndex(where: { $0.id == cue.id }) else { return false }
        var edited = cue
        if edited.language == .zh { edited.chineseText = "" }
        track.cues[index] = edited; project.subtitleTrack = track
        return updateAndSave(project)
    }
}
