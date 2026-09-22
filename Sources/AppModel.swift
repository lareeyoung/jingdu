import SwiftUI
import AVKit
import UniformTypeIdentifiers

enum BatchImportMode: String, CaseIterable { case combined, separate, append }

@MainActor final class StudioModel: ObservableObject {
    @Published var projects: [FilmProject] = []
    @Published var selectedID: UUID?
    @Published var currentTime: Double = 0
    @Published var selectedShotIndex = 0
    @Published var isPlaying = false
    @Published var loopShot = false
    @Published var muted = false
    @Published var rate: Float = 1
    @Published var thumbnails: [Int: NSImage] = [:]
    @Published var waveform: [Double] = []
    @Published var musicWaveforms: [UUID: [Double]] = [:]
    @Published var notePreview: NSImage?
    @Published var busy = false
    @Published var playbackLoading = false
    @Published var progress: Double = 0
    @Published var busyLabel = ""
    @Published var error: String?
    @Published var toast: String?
    @Published var selectedNoteID: UUID?
    @Published var selectedClipID: UUID?
    @Published var selectedMusicID: UUID?
    @Published var selectedSubtitleID: UUID?
    @Published var showSubtitleReader = false
    @Published var subtitlePlaybackFollow = false
    @Published var activeTrack: NoteTrack = .camera
    @Published var showHelp = false
    @Published var showAnalysis = false
    @Published var showDeleteProject = false
    @Published var showImportOptions = false
    @Published var importURLs: [URL] = []
    @Published var showRename = false
    @Published var renameDraft = ""
    @Published var renamingID: UUID?
    @Published var showCapture = false
    @Published var captureStart = 0.0
    @Published var captureEnd = 0.0
    @Published var captureTitle = ""
    @Published var newSpaceTitle = "灵感混剪"
    @Published var captureTargetID: UUID?
    @Published var searchText = ""
    @Published var timelineZoom: Double = 1
    // Active only while a matching script reader has bidirectional follow on.
    @Published var scriptPlaybackFollow = false
    @Published var pendingIn: Double?
    @Published var mediaAvailable = false
    @Published var candidateCuts: [Double]?
    @Published var sensitivity = 0.32
    @Published var showContact = true
    @Published var focusReset = 0
    @Published var newNoteFocusID: UUID?
    let player = AVPlayer()
    private let persistent: Bool
    private var storageWritable = true
    private var operationToken = UUID()
    private var analyzingCuts = false
    private var cutSnapshot: [VideoClip]?
    private var segmentEnd: Double?
    private var waveformTask: Task<Void, Never>?
    private var musicWaveformTask: Task<Void, Never>?
    private var playerBuildTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var observer: Any?
    private var mediaTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var monitor: Any?
    private var loadToken = UUID()
    private var undoStack: [FilmProject] = []
    private var redoStack: [FilmProject] = []

    var project: FilmProject? { projects.first { $0.id == selectedID } }
    var shots: [StudyShot] { project?.shots ?? [] }
    var selectedShot: StudyShot? { shots.indices.contains(selectedShotIndex) ? shots[selectedShotIndex] : shots.first }
    var selectedNote: StudyNote? { project?.notes.first { $0.id == selectedNoteID } }
    var selectedClip: VideoClip? { project?.videoClips.first { $0.id == selectedClipID } }
    var selectedMusic: MusicClip? { project?.music.first { $0.id == selectedMusicID } }
    var visibleProjects: [FilmProject] { projects.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) } }
    var remixSpaces: [FilmProject] { projects.filter { $0.kind == .remix } }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasModal: Bool { showHelp || showAnalysis || showImportOptions || showRename || showCapture || showDeleteProject || error != nil }

    init(persistent: Bool = true) {
        self.persistent = persistent
        do { if persistent { projects = try ProjectPersistence.load() } }
        catch { storageWritable = false; self.error = "作品库读取失败，已停用自动保存，原文件仍保留。\n\(error.localizedDescription)" }
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0/30, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, let project = self.project, !self.playbackLoading else { return }
                let value = time.seconds
                guard value.isFinite else { return }
                if let end = self.segmentEnd, self.isPlaying, value >= end - 0.001 {
                    self.player.pause(); self.isPlaying = false; self.seek(end); return
                }
                if self.loopShot, self.isPlaying, let shot = self.selectedShot, value >= shot.end - min(0.001, shot.duration / 4) {
                    self.seek(shot.start, follow: false); self.player.playImmediately(atRate: self.rate); return
                }
                self.currentTime = max(0, min(value, project.duration))
                if !self.loopShot { self.selectedShotIndex = ProjectLogic.shotIndex(project, at: self.currentTime) }
                if value >= project.duration - 0.015 && !self.loopShot { self.isPlaying = false }
            }
        }
        if persistent, let remembered = UserDefaults.standard.string(forKey: "selectedProject"), let id = UUID(uuidString: remembered), projects.contains(where: {$0.id == id}) { select(id) }
        else if let first = projects.first { select(first.id) }
    }
    func dismissTextFocus() { focusReset += 1; NSApp?.keyWindow?.makeFirstResponder(nil) }
    func notify(_ text: String) {
        toast = text
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if toast == text { toast = nil } }
    }
    func persist() {
        guard persistent else { return }
        guard storageWritable else { self.error = "原作品库读取失败，为保留原数据，本次修改暂不自动保存。请先导出项目备份。"; return }
        saveTask?.cancel()
        saveTask = Task {
            do { try await Task.sleep(nanoseconds: 250_000_000); try ProjectPersistence.save(projects) }
            catch is CancellationError {} catch { self.error = "保存失败：\(error.localizedDescription)" }
        }
    }
    func flush() { guard persistent, storageWritable else { return }; do { try ProjectPersistence.save(projects) } catch { self.error = error.localizedDescription } }
    @discardableResult func update(_ value: FilmProject, recordUndo: Bool = true) -> Bool {
        guard let i = projects.firstIndex(where: {$0.id == value.id}) else { return false }
        do { _ = try ProjectPersistence.encodeProject(value) } catch { self.error = error.localizedDescription; return false }
        guard projects[i] != value else { return true }
        if projects[i].videoClips != value.videoClips { invalidateCutAnalysis() }
        if recordUndo && selectedID == value.id { undoStack.append(projects[i]); if undoStack.count > 60 { undoStack.removeFirst() }; redoStack.removeAll() }
        var updated = value; updated.updatedAt = Date(); projects[i] = updated; persist(); return true
    }
    /// Critical results remain available in memory for export even when the
    /// library cannot be written. A true result confirms the synchronous save.
    @discardableResult func updateAndSave(_ value: FilmProject) -> Bool {
        guard update(value) else { return false }
        saveTask?.cancel(); saveTask = nil
        guard persistent else { return true }
        guard storageWritable else {
            error = "原作品库读取失败，为保留原数据，本次结果尚未保存。请先导出备份。"
            return false
        }
        do {
            try ProjectPersistence.save(projects)
            error = nil
            return true
        } catch {
            self.error = "保存失败，本次结果仍保留在当前窗口，可先导出备份。\n\(error.localizedDescription)"
            return false
        }
    }
    func undo() {
        dismissTextFocus(); guard let old = undoStack.popLast(), let current = project else { return }
        redoStack.append(current); update(old, recordUndo: false); selectedShotIndex = ProjectLogic.shotIndex(old, at: currentTime)
        if old.videoClips != current.videoClips || old.music != current.music || old.originalVolume != current.originalVolume { reloadMedia() } else if old.cuts != current.cuts { rebuildThumbnails() }
        refreshNotePreview()
    }
    func redo() {
        dismissTextFocus(); guard let next = redoStack.popLast(), let current = project else { return }
        undoStack.append(current); update(next, recordUndo: false); selectedShotIndex = ProjectLogic.shotIndex(next, at: currentTime)
        if next.videoClips != current.videoClips || next.music != current.music || next.originalVolume != current.originalVolume { reloadMedia() } else if next.cuts != current.cuts { rebuildThumbnails() }
        refreshNotePreview()
    }
    func select(_ id: UUID) {
        guard projects.contains(where: {$0.id == id}) else { return }
        dismissTextFocus(); cancelAnalysis(); selectedID = id; currentTime = 0; selectedShotIndex = 0
        selectedNoteID = nil; selectedClipID = nil; selectedMusicID = nil; notePreview = nil
        isPlaying = false; loopShot = false; pendingIn = nil; segmentEnd = nil
        undoStack = []; redoStack = []; candidateCuts = nil
        if persistent { UserDefaults.standard.set(id.uuidString, forKey: "selectedProject") }
        reloadMedia(restoreTime: 0)
    }
    func reloadMedia(restoreTime: Double? = nil) {
        guard let item = project else { return }
        let position = min(item.duration, max(0, restoreTime ?? currentTime))
        player.pause(); isPlaying = false; mediaTask?.cancel(); waveformTask?.cancel(); musicWaveformTask?.cancel(); playerBuildTask?.cancel()
        loadToken = UUID(); let token = loadToken; currentTime = position
        thumbnails = [:]; waveform = []; musicWaveforms = [:]; mediaAvailable = false
        guard item.videoClips.allSatisfy({FileManager.default.fileExists(atPath: $0.sourcePath)}) else {
            player.replaceCurrentItem(with: nil); playbackLoading = false; notify("找不到部分原视频，请在素材详情中重新定位"); return
        }
        playbackLoading = true
        playerBuildTask = Task {
            do {
                let clips = item.videoClips
                let playerItem: AVPlayerItem
                if clips.count == 1, let clip = clips.first, clip.sourceIn == 0, abs(clip.sourceOut - clip.sourceDuration) < 0.00001, item.music.isEmpty, item.originalVolume == 1 {
                    playerItem = AVPlayerItem(url: URL(fileURLWithPath: clip.sourcePath))
                } else {
                    let result = try await CompositionBuilder.build(item)
                    try Task.checkCancellation()
                    playerItem = AVPlayerItem(asset: result.asset); playerItem.videoComposition = result.videoComposition; playerItem.audioMix = result.audioMix
                }
                guard token == loadToken, selectedID == item.id, !Task.isCancelled else { return }
                player.replaceCurrentItem(with: playerItem); player.isMuted = muted
                playbackLoading = false; mediaAvailable = true; seek(position)
            } catch is CancellationError {} catch {
                guard token == loadToken else { return }; playbackLoading = false; self.error = "预览准备失败：\(error.localizedDescription)"
            }
        }
        mediaTask = Task { await loadThumbnails(item, token: token) }
        waveformTask = Task {
            var cache: [String: [Double]] = [:]
            let bins = max(1200, min(20000, Int(item.duration * 60)))
            var combined = [Double](repeating: 0, count: bins)
            for placement in item.clipPlacements {
                if Task.isCancelled { return }; let clip = placement.clip
                let samples: [Double]
                if let found = cache[clip.sourcePath] { samples = found }
                else { samples = (try? await MediaAnalyzer.waveform(URL(fileURLWithPath: clip.sourcePath), bins: max(1200, min(20000, Int(clip.sourceDuration * 60))))) ?? []; cache[clip.sourcePath] = samples }
                guard !samples.isEmpty else { continue }
                let lower = max(0, Int(placement.start / item.duration * Double(bins)))
                let upper = min(bins, Int(ceil(placement.end / item.duration * Double(bins))))
                for bin in lower..<max(lower, upper) {
                    let time = Double(bin) / Double(bins) * item.duration
                    let source = min(clip.sourceOut, max(clip.sourceIn, time - placement.start + clip.sourceIn))
                    let index = min(samples.count - 1, max(0, Int(source / clip.sourceDuration * Double(samples.count))))
                    combined[bin] = samples[index] * item.originalVolume
                }
            }
            if token == loadToken, !Task.isCancelled { waveform = combined }
        }
        musicWaveformTask = Task {
            var cache: [String: [Double]] = [:]
            for music in item.music {
                if Task.isCancelled { return }
                let samples: [Double]
                if let found = cache[music.sourcePath] { samples = found }
                else { samples = (try? await MediaAnalyzer.waveform(URL(fileURLWithPath: music.sourcePath), bins: max(1200, min(20000, Int(music.sourceDuration * 60))))) ?? []; cache[music.sourcePath] = samples }
                if token == loadToken, !Task.isCancelled { musicWaveforms[music.id] = samples }
            }
        }
        refreshNotePreview()
    }
    func sourceFrame(_ item: FilmProject, at time: Double, width: CGFloat = 360, exact: Bool = false) async -> NSImage? {
        guard let placement = item.clipPlacements.last(where: {$0.start <= time}) ?? item.clipPlacements.first else { return nil }
        let clip = placement.clip
        let source = max(clip.sourceIn, min(clip.sourceOut - min(0.001, clip.duration / 2), time - placement.start + clip.sourceIn))
        return await MediaAnalyzer.thumbnail(URL(fileURLWithPath: clip.sourcePath), at: source, width: width, exact: exact)
    }
    private func loadThumbnails(_ item: FilmProject, token: UUID) async {
        for shot in item.shots.prefix(1200) {
            if Task.isCancelled || token != loadToken { return }
            if let image = await sourceFrame(item, at: shot.start + min(shot.duration * 0.3, 0.2)), token == loadToken { thumbnails[shot.index] = image }
        }
    }
    func rebuildThumbnails() {
        guard let item = project, mediaAvailable || playbackLoading else { return }
        mediaTask?.cancel(); let token = loadToken; thumbnails = [:]
        mediaTask = Task { await loadThumbnails(item, token: token) }
    }
    func refreshNotePreview() {
        previewTask?.cancel(); notePreview = nil
        guard let item = project, let note = selectedNote else { return }
        previewTask = Task { let image = await sourceFrame(item, at: note.start); if !Task.isCancelled, selectedID == item.id, selectedNoteID == note.id { notePreview = image } }
    }
    func openVideo() {
        dismissTextFocus(); let panel = NSOpenPanel(); panel.title = "导入一段或多段视频"; panel.allowedContentTypes = [.movie, .video]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { importURLs = panel.urls; if importURLs.count == 1, let url = importURLs.first { importVideo(url) } else if !importURLs.isEmpty { showImportOptions = true } }
    }
    func appendVideos() {
        dismissTextFocus(); let panel = NSOpenPanel(); panel.title = "追加视频到当前时间轴"; panel.allowedContentTypes = [.movie, .video]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { importURLs = panel.urls; performImport(.append) }
    }
    func importVideo(_ url: URL) { importURLs = [url]; performImport(.combined) }
    func acceptDroppedVideos(_ urls: [URL]) { guard !urls.isEmpty else { return }; importURLs = urls; if urls.count > 1 { showImportOptions = true } else { performImport(.combined) } }
    func performImport(_ mode: BatchImportMode) {
        guard !busy, !importURLs.isEmpty else { return }
        let urls = importURLs; let destinationID = selectedID
        showImportOptions = false; dismissTextFocus(); busy = true; busyLabel = "正在导入视频"; progress = 0; operationToken = UUID(); let operation = operationToken
        analysisTask = Task { [self] in
            do {
                var clips: [VideoClip] = []
                for (index, url) in urls.enumerated() {
                    let info: MediaInfo
                    do { info = try await MediaAnalyzer.inspect(url) } catch { throw StudioError.message("《\(url.lastPathComponent)》：\(error.localizedDescription)") }; try Task.checkCancellation()
                    clips.append(VideoClip(title: url.deletingPathExtension().lastPathComponent, sourcePath: url.path, sourceDuration: info.duration, sourceIn: 0, sourceOut: info.duration, frameRate: info.frameRate, width: info.width, height: info.height))
                    if operationToken == operation { progress = Double(index + 1) / Double(urls.count); busyLabel = "正在导入 \(index + 1)/\(urls.count)" }
                }
                guard operationToken == operation else { return }
                let targetID: UUID
                if mode == .append, let id = destinationID, var target = projects.first(where: {$0.id == id}) {
                    target.clips = target.videoClips + clips; target = SequenceLogic.recalculate(target)
                    _ = try ProjectPersistence.encodeProject(target); update(target); targetID = target.id
                } else {
                    let added: [FilmProject]
                    if mode == .separate { added = clips.map { SequenceLogic.makeProject(title: $0.title, clips: [$0]) } }
                    else { added = [SequenceLogic.makeProject(title: clips.count > 1 ? "\(clips[0].title) 等 \(clips.count) 段" : clips[0].title, clips: clips)] }
                    for item in added { _ = try ProjectPersistence.encodeProject(item) }
                    projects.insert(contentsOf: added, at: 0); persist(); targetID = added[0].id
                }
                busy = false; analysisTask = nil; importURLs = []; searchText = ""; select(targetID)
                notify(mode == .separate ? "已创建 \(clips.count) 个独立项目" : "已导入 \(clips.count) 段视频到同一时间轴")
            } catch is CancellationError { if operationToken == operation { busy = false } }
            catch { guard operationToken == operation else { return }; busy = false; self.error = "导入未完成：\(error.localizedDescription)" }
        }
    }
    func relink() {
        guard let item = project, let clip = selectedClip ?? item.videoClips.first(where: {!FileManager.default.fileExists(atPath: $0.sourcePath)}) ?? item.videoClips.first else { return }
        let panel = NSOpenPanel(); panel.title = "定位原视频：\(clip.title)"; panel.allowedContentTypes = [.movie, .video]
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    let info = try await MediaAnalyzer.inspect(url)
                    guard abs(info.duration - clip.sourceDuration) < max(0.15, 2 / clip.frameRate) else { throw StudioError.message("时长与原素材不同，请选择原视频，避免标记错位。") }
                    guard var latest = projects.first(where: {$0.id == item.id}) else { return }
                    latest.clips = latest.videoClips
                    for i in latest.clips.indices where latest.clips[i].sourcePath == clip.sourcePath { latest.clips[i].sourcePath = url.path }
                    latest = SequenceLogic.recalculate(latest); update(latest); if selectedID == item.id { reloadMedia() }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    func togglePlay() {
        dismissTextFocus(); guard mediaAvailable, let item = project else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else { if currentTime >= item.duration - 0.02 { seek(loopShot ? (selectedShot?.start ?? 0) : 0) }; player.playImmediately(atRate: rate); isPlaying = true }
    }
    func seek(_ time: Double, follow: Bool = true) {
        guard let item = project, time.isFinite else { return }
        let value = max(0, min(time, item.duration)); currentTime = value; segmentEnd = nil
        if follow && !loopShot { selectedShotIndex = ProjectLogic.shotIndex(item, at: value) }
        player.seek(to: CMTime(seconds: value, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func step(_ direction: Double) {
        dismissTextFocus(); guard let item = player.currentItem, item.status == .readyToPlay, let project else { return }
        player.pause(); isPlaying = false; segmentEnd = nil; let forward = direction > 0
        guard forward ? item.canStepForward : item.canStepBackward else { notify("此格式不支持该方向逐帧，请通过时间轴定位"); return }
        guard forward ? currentTime < project.duration : currentTime > 0 else { return }; item.step(byCount: forward ? 1 : -1)
    }
    func jumpShot(_ delta: Int) { guard !shots.isEmpty else { return }; chooseShot(max(0, min(selectedShotIndex + delta, shots.count - 1))) }
    func chooseShot(_ index: Int) { dismissTextFocus(); guard shots.indices.contains(index) else { return }; selectedShotIndex = index; selectedNoteID = nil; selectedClipID = nil; selectedMusicID = nil; seek(shots[index].start, follow: false) }
    func split() {
        dismissTextFocus(); guard let old = project else { return }; let new = ProjectLogic.split(old, at: currentTime)
        guard new.cuts != old.cuts else { notify("切点过近，或已在镜头边界"); return }; update(new); selectedShotIndex = ProjectLogic.shotIndex(new, at: currentTime); rebuildThumbnails(); notify("已拆分镜头")
    }
    func mergePrevious() {
        guard let item = project, let shot = selectedShot, shot.index > 0 else { return }
        if item.clipPlacements.dropFirst().contains(where: {abs($0.start - shot.start) < 0.0001}) { notify("这是两个素材的接缝，可在素材详情中调整顺序"); return }
        update(ProjectLogic.removeCut(item, at: shot.start)); selectedShotIndex = max(0, selectedShotIndex - 1); rebuildThumbnails()
    }
    func detectCuts() {
        dismissTextFocus(); guard let item = project, mediaAvailable, !busy else { return }
        player.pause(); isPlaying = false; busy = true; busyLabel = "正在分析画面变化"; progress = 0; candidateCuts = nil
        let id = item.id; operationToken = UUID(); let operation = operationToken; analyzingCuts = true; cutSnapshot = item.videoClips
        analysisTask = Task { [self] in
            do {
                var all = item.clipPlacements.dropFirst().map(\.start); var cache: [String: [Double]] = [:]
                let placements = item.clipPlacements
                for (index, placement) in placements.enumerated() {
                    try Task.checkCancellation(); let clip = placement.clip
                    let cuts: [Double]
                    if let found = cache[clip.sourcePath] { cuts = found }
                    else {
                        cuts = try await MediaAnalyzer.detectCuts(URL(fileURLWithPath: clip.sourcePath), sensitivity: sensitivity) { [weak self] value in
                            Task { @MainActor in if self?.selectedID == id && self?.operationToken == operation { self?.progress = (Double(index) + value) / Double(placements.count) } }
                        }; cache[clip.sourcePath] = cuts
                    }
                    all += cuts.filter {$0 > clip.sourceIn && $0 < clip.sourceOut}.map {$0 - clip.sourceIn + placement.start}
                }
                try Task.checkCancellation(); guard operationToken == operation else { return }
                guard project?.videoClips == item.videoClips else { invalidateCutAnalysis(); return }
                if selectedID == id { candidateCuts = ProjectLogic.normalizedCuts(all, in: item); showAnalysis = true }; busy = false; analyzingCuts = false
            } catch is CancellationError { if operationToken == operation { busy = false; analyzingCuts = false } }
            catch { guard operationToken == operation else { return }; busy = false; analyzingCuts = false; self.error = "切镜识别失败：\(error.localizedDescription)" }
        }
    }
    func applyCuts(replace: Bool) {
        guard var item = project, let cuts = candidateCuts else { return }
        guard cutSnapshot == item.videoClips else { invalidateCutAnalysis(); notify("素材已调整，请重新识别切镜"); return }
        item.cuts = ProjectLogic.normalizedCuts(replace ? cuts : item.cuts + cuts, in: item)
        update(item); selectedShotIndex = ProjectLogic.shotIndex(item, at: currentTime); rebuildThumbnails(); candidateCuts = nil; showAnalysis = false; notify("已更新镜头，可用 ⌘Z 撤销")
    }
    func cancelAnalysis() { operationToken = UUID(); analysisTask?.cancel(); analysisTask = nil; busy = false; progress = 0; analyzingCuts = false }
    private func invalidateCutAnalysis() { if analyzingCuts { cancelAnalysis() }; cutSnapshot = nil; candidateCuts = nil; showAnalysis = false }
    func setIn() { pendingIn = currentTime; notify("已设起点，按 O 创建区间标记，或点击“收集片段”") }
    func setOut() { guard let start = pendingIn else { setIn(); return }; addNote(track: activeTrack, start: min(start, currentTime), end: max(start, currentTime)); pendingIn = nil }
    func addNote(track: NoteTrack, start: Double? = nil, end: Double? = nil) {
        dismissTextFocus(); guard var item = project else { return }; player.pause(); isPlaying = false
        let s = start ?? currentTime
        let note = StudyNote(start: s, end: end ?? min(item.duration, max(s + 0.5, selectedShot?.end ?? s)), track: track, title: "", body: "", takeaway: "")
        item.notes.append(note); guard update(item) else { return }; selectedNoteID = note.id; selectedClipID = nil; selectedMusicID = nil; activeTrack = track; newNoteFocusID = note.id; refreshNotePreview(); notify("已创建\(track.title)标记，右侧可直接记录")
    }
    func playNote(_ note: StudyNote) {
        dismissTextFocus(); guard mediaAvailable else { return }; loopShot = false; seek(note.start); segmentEnd = note.end
        if note.end > note.start { player.playImmediately(atRate: rate); isPlaying = true } else { player.pause(); isPlaying = false }
    }
    func selectNote(_ note: StudyNote) { dismissTextFocus(); selectedNoteID = note.id; selectedClipID = nil; selectedMusicID = nil; activeTrack = note.track; seek(note.start); refreshNotePreview() }
    func editNote(_ transform: (inout StudyNote) -> Void) {
        guard var item = project, let i = item.notes.firstIndex(where: {$0.id == selectedNoteID}) else { return }
        let oldStart = item.notes[i].start; transform(&item.notes[i]); update(item); if oldStart != item.notes[i].start { refreshNotePreview() }
    }
    func removeNote() { guard var item = project, let id = selectedNoteID else { return }; item.notes.removeAll {$0.id == id}; update(item); selectedNoteID = nil; notePreview = nil; notify("已删除标记，可用 ⌘Z 撤销") }
    func rename(_ title: String) { guard var item = project else { return }; item.title = title.trimmingCharacters(in: .whitespacesAndNewlines); update(item) }
    func requestRename(_ id: UUID? = nil) { guard let item = projects.first(where: {$0.id == (id ?? selectedID)}) else { return }; dismissTextFocus(); renamingID = item.id; renameDraft = item.title; showRename = true }
    func applyRename() { guard var item = projects.first(where: {$0.id == renamingID}) else { return }; item.title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines); if update(item) { if selectedID == item.id && !searchText.isEmpty && !item.title.localizedCaseInsensitiveContains(searchText) { searchText = "" }; showRename = false; notify("项目名称已更新，原文件名保留") } }
    func deleteProject() {
        guard let id = selectedID else { return }; projects.removeAll {$0.id == id}; player.pause(); player.replaceCurrentItem(with: nil); mediaTask?.cancel(); waveformTask?.cancel(); musicWaveformTask?.cancel(); playerBuildTask?.cancel(); cancelAnalysis(); selectedID = nil; mediaAvailable = false; persist()
        if let first = projects.first { select(first.id) }; notify("已移出作品库，原素材文件保留")
    }
    func selectVideoClip(_ id: UUID) { dismissTextFocus(); guard let placement = project?.clipPlacements.first(where: {$0.id == id}) else { return }; selectedClipID = id; selectedMusicID = nil; selectedNoteID = nil; seek(placement.start) }
    func moveVideoClip(_ id: UUID, delta: Int) { guard let item = project else { return }; let next = SequenceLogic.moveClip(item, id: id, delta: delta); if update(next) { reloadMedia(restoreTime: next.clipPlacements.first(where: {$0.id == id})?.start ?? 0) } }
    func trimVideoClip(_ id: UUID, sourceIn: Double, sourceOut: Double) { guard let item = project, let clip = item.videoClips.first(where: {$0.id == id}) else { return }; guard sourceIn.isFinite, sourceOut.isFinite, sourceIn >= 0, sourceOut > sourceIn, sourceOut <= clip.sourceDuration else { error = "素材裁剪范围必须在原视频时长内，且终点大于起点"; return }; let next = SequenceLogic.trimClip(item, id: id, sourceIn: sourceIn, sourceOut: sourceOut); if update(next) { reloadMedia() } }
    func removeVideoClip(_ id: UUID) { guard let item = project, item.videoClips.count > 1 else { notify("请至少保留一个视频片段"); return }; if update(SequenceLogic.removeClip(item, id: id)) { selectedClipID = nil; reloadMedia() } }
    func requestCapture() {
        dismissTextFocus(); guard let item = project else { return }
        if let start = pendingIn, abs(start - currentTime) > 0.001 { captureStart = min(start, currentTime); captureEnd = max(start, currentTime) }
        else if let note = selectedNote, note.end > note.start { captureStart = note.start; captureEnd = note.end }
        else { captureStart = selectedShot?.start ?? 0; captureEnd = selectedShot?.end ?? item.duration }
        captureTitle = selectedNote?.displayTitle ?? "\(item.title) · 镜头 \(selectedShotIndex + 1)"; captureTargetID = nil; newSpaceTitle = "灵感混剪 \(remixSpaces.count + 1)"; showCapture = true
    }
    func captureToSpace() {
        guard let source = project else { return }
        guard captureStart.isFinite, captureEnd.isFinite, captureStart >= 0, captureEnd <= source.duration, captureEnd > captureStart else { error = "请选择原时间轴内的有效片段范围"; return }
        var clips = SequenceLogic.extract(source, start: captureStart, end: captureEnd)
        guard !clips.isEmpty else { error = "这个范围内没有可提取的视频"; return }
        for i in clips.indices { clips[i].title = (captureTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? source.title : String(captureTitle.prefix(400))) + (clips.count > 1 ? " · \(i + 1)" : "") }
        var destination: FilmProject
        let offset: Double
        if let id = captureTargetID, let existing = projects.first(where: {$0.id == id && $0.kind == .remix}) { destination = existing; offset = destination.duration; destination.clips = destination.videoClips + clips; destination = SequenceLogic.recalculate(destination) }
        else { offset = 0; destination = SequenceLogic.makeProject(title: newSpaceTitle.trimmingCharacters(in: .whitespacesAndNewlines), clips: clips, kind: .remix) }
        destination.cuts += source.cuts.filter {$0 > captureStart && $0 < captureEnd}.map {$0 - captureStart + offset}
        for note in source.notes where note.start < captureEnd && note.end >= captureStart {
            var copy = note; copy.id = UUID(); copy.start = max(note.start, captureStart) - captureStart + offset; copy.end = min(note.end, captureEnd) - captureStart + offset; destination.notes.append(copy)
        }
        destination = SequenceLogic.recalculate(destination)
        do { _ = try ProjectPersistence.encodeProject(destination) } catch { self.error = error.localizedDescription; return }
        var marked = source
        marked.notes.append(StudyNote(start: captureStart, end: captureEnd, track: .learning, title: "已收集 · \(String(captureTitle.prefix(450)))", body: "片段已放入灵感空间「\(destination.title)」，可在那里排序、裁剪和配乐。", takeaway: ""))
        guard update(marked) else { return }
        if projects.contains(where: {$0.id == destination.id}) { update(destination, recordUndo: false) } else { projects.insert(destination, at: 0); persist() }
        showCapture = false; pendingIn = nil; searchText = ""; select(destination.id); notify("片段已收进灵感空间，可以继续从其他项目收集")
    }
    func importMusic() {
        dismissTextFocus(); guard let item = project, !busy else { return }
        let panel = NSOpenPanel(); panel.title = "导入音乐或音效"; panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let position = currentTime >= item.duration - 0.05 ? 0 : currentTime
        busy = true; busyLabel = "正在读取音乐"; operationToken = UUID(); let operation = operationToken
        analysisTask = Task { [self] in
            do {
                let duration = try await CompositionBuilder.inspectAudio(url); try Task.checkCancellation()
                guard operationToken == operation, var latest = projects.first(where: {$0.id == item.id}) else { return }
                let music = MusicClip(title: url.deletingPathExtension().lastPathComponent, sourcePath: url.path, sourceDuration: duration, sourceIn: 0, sourceOut: min(duration, latest.duration - position), timelineStart: position)
                latest.music.append(music); guard update(latest) else { busy = false; return }; busy = false; selectedMusicID = music.id; selectedClipID = nil; selectedNoteID = nil; reloadMedia(); notify("音乐已加入。右侧可裁剪，时间轴可拖动位置")
            } catch is CancellationError { if operationToken == operation { busy = false } }
            catch { if operationToken == operation { busy = false; self.error = error.localizedDescription } }
        }
    }
    func selectMusic(_ id: UUID) { dismissTextFocus(); guard let music = project?.music.first(where: {$0.id == id}) else { return }; selectedMusicID = id; selectedClipID = nil; selectedNoteID = nil; seek(music.timelineStart) }
    func editMusic(_ id: UUID, sourceIn: Double, sourceOut: Double, timelineStart: Double, volume: Double) {
        guard var item = project, let i = item.music.firstIndex(where: {$0.id == id}) else { return }
        item.music[i].sourceIn = sourceIn; item.music[i].sourceOut = sourceOut; item.music[i].timelineStart = timelineStart; item.music[i].volume = volume
        if update(item) { reloadMedia() }
    }
    func moveMusic(_ id: UUID, to time: Double) { guard var item = project, let i = item.music.firstIndex(where: {$0.id == id}), time.isFinite else { return }; item.music[i].timelineStart = max(0, min(time, item.duration - item.music[i].duration)); if update(item) { reloadMedia() } }
    func splitSelectedMusic() { guard let item = project, let id = selectedMusicID else { return }; let next = SequenceLogic.splitMusic(item, id: id, at: currentTime); if next.music == item.music { notify("把播放头放在所选音乐片段内部再拆分"); return }; if update(next) { reloadMedia() } }
    func removeSelectedMusic() { guard var item = project, let id = selectedMusicID else { return }; item.music.removeAll {$0.id == id}; if update(item) { selectedMusicID = nil; reloadMedia() } }
    func setOriginalVolume(_ volume: Double) { guard var item = project else { return }; item.originalVolume = max(0, min(1, volume)); if update(item) { reloadMedia() } }
    func export(_ kind: String) {
        dismissTextFocus(); guard let item = project else { return }
        do {
            let data: Data; let ext: String
            switch kind { case "json": data = try ProjectPersistence.encodeProject(item); ext = "json"; case "prompt": data = Data(ProjectLogic.exportAnalysisPrompt(item).utf8); ext = "txt"; default: data = Data(ProjectLogic.exportMarkdown(item).utf8); ext = "md" }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "\(item.title)-\(kind == "prompt" ? "分析提问" : "拉片").\(ext)"
            if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic); notify("已导出到 \(url.lastPathComponent)") }
        } catch { self.error = "导出失败：\(error.localizedDescription)" }
    }
    func exportMovie() {
        dismissTextFocus(); guard let item = project, !busy else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(item.title)-混剪.mp4"; panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; busyLabel = "正在导出视频与音乐"; progress = 0; operationToken = UUID(); let operation = operationToken
        analysisTask = Task { [self] in
            do { try await CompositionBuilder.export(item, to: url) { [weak self] value in Task { @MainActor in if self?.operationToken == operation { self?.progress = value } } }; if operationToken == operation { busy = false; notify("混剪已导出：\(url.lastPathComponent)") } }
            catch is CancellationError { if operationToken == operation { busy = false } }
            catch { if operationToken == operation { busy = false; self.error = "导出未完成：\(error.localizedDescription)" } }
        }
    }
    func importProject() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.title = "导入镜读项目备份"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { var item = try ProjectPersistence.decodeProject(Data(contentsOf: url)); if projects.contains(where: {$0.id == item.id}) { item.id = UUID(); item.title = String(item.title.prefix(490)) + "（导入副本）" }; projects.insert(item, at: 0); persist(); select(item.id) }
        catch { self.error = "备份无法导入：\(error.localizedDescription)" }
    }
    func saveFrame() {
        guard let item = project, mediaAvailable else { return }; let time = currentTime
        Task {
            guard let image = await sourceFrame(item, at: time, width: CGFloat(max(item.width, item.height)), exact: true), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { error = "当前帧无法导出"; return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "\(item.title)-\(timecode(time).replacingOccurrences(of: ":", with: "-" )).png"; panel.allowedContentTypes = [.png]
            if panel.runModal() == .OK, let url = panel.url { do { try data.write(to: url); notify("关键帧已保存") } catch { self.error = error.localizedDescription } }
        }
    }
    func installShortcuts() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.hasModal, NSApp?.modalWindow == nil, NSApp?.keyWindow?.isSheet != true else { return event }
            if event.keyCode == 53 { self.dismissTextFocus(); return nil }
            guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option), NSApp.keyWindow?.firstResponder is NSTextView == false, self.project != nil else { return event }
            switch event.keyCode { case 49: self.togglePlay(); return nil; case 123: if event.modifierFlags.contains(.shift) { self.jumpShot(-1) } else { self.step(-1) }; return nil; case 124: if event.modifierFlags.contains(.shift) { self.jumpShot(1) } else { self.step(1) }; return nil; default: break }
            switch event.charactersIgnoringModifiers?.lowercased() { case "m": self.addNote(track: self.activeTrack); return nil; case "c": self.addNote(track: .camera); return nil; case "s": self.addNote(track: .sound); return nil; case "b": self.split(); return nil; case "i": self.setIn(); return nil; case "o": self.setOut(); return nil; case "l": self.loopShot.toggle(); return nil; default: return event }
        }
    }
}
enum StudioError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
