import Foundation

enum NoteTrack: String, Codable, CaseIterable, Identifiable {
    case story, camera, sound, learning

    var id: String { rawValue }
    var title: String {
        switch self {
        case .story: return "叙事逻辑"
        case .camera: return "镜头设计"
        case .sound: return "声音设计"
        case .learning: return "学习启发"
        }
    }
    var symbol: String {
        switch self {
        case .story: return "point.topleft.down.to.point.bottomright.curvepath"
        case .camera: return "camera"
        case .sound: return "waveform"
        case .learning: return "lightbulb"
        }
    }
}

struct StudyNote: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var track: NoteTrack
    var title: String
    var body: String
    var takeaway: String

    var hasContent: Bool {
        [title, body, takeaway].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var displayTitle: String {
        let explicit = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        for text in [body, takeaway] {
            if let line = text.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "\(track.title) · \(timecode(start))"
    }
}

enum ProjectKind: String, Codable { case study, remix }

struct VideoClip: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var sourcePath: String
    var sourceDuration: Double
    var sourceIn: Double
    var sourceOut: Double
    var frameRate: Double
    var width: Int
    var height: Int
    var sourceProjectID: UUID? = nil
    var sourceProjectTitle: String? = nil
    var duration: Double { sourceOut - sourceIn }
}

struct MusicClip: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var sourcePath: String
    var sourceDuration: Double
    var sourceIn: Double
    var sourceOut: Double
    var timelineStart: Double
    var volume: Double = 0.8
    var duration: Double { sourceOut - sourceIn }
}

struct ClipPlacement: Identifiable, Equatable {
    var clip: VideoClip
    var start: Double
    var end: Double { start + clip.duration }
    var id: UUID { clip.id }
}

struct ScriptDialogueCue: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

struct ScriptSegment: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var visual: String
    var action: String
    var dialogue: String
    var sound: String
    var camera: String
    var transition: String
    var reasoning: String
    var uncertainty: String
    var screenplay: String = ""
    var dialogueCues: [ScriptDialogueCue] = []
}

extension ScriptSegment {
    private enum CodingKeys: String, CodingKey {
        case id, start, end, visual, action, dialogue, sound, camera, transition, reasoning, uncertainty
        case screenplay, dialogueCues
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        visual = try c.decode(String.self, forKey: .visual)
        action = try c.decode(String.self, forKey: .action)
        dialogue = try c.decode(String.self, forKey: .dialogue)
        sound = try c.decode(String.self, forKey: .sound)
        camera = try c.decode(String.self, forKey: .camera)
        transition = try c.decode(String.self, forKey: .transition)
        reasoning = try c.decode(String.self, forKey: .reasoning)
        uncertainty = try c.decode(String.self, forKey: .uncertainty)
        screenplay = try c.decodeIfPresent(String.self, forKey: .screenplay) ?? ""
        dialogueCues = try c.decodeIfPresent([ScriptDialogueCue].self, forKey: .dialogueCues) ?? []
    }
}

struct ScriptAnalysis: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var modelID: String
    var sourceClips: [VideoClip]
    var rangeStart: Double
    var rangeEnd: Double
    var title: String
    var synopsis: String
    var structure: String
    var segments: [ScriptSegment]
    var caveats: String
    var inputMode: String
    var sourceMusic: [MusicClip] = []
    var originalVolume: Double = 1
    var timelineNoteIDs: [UUID] = []

    /// Compares content-affecting edits without invalidating results for renaming,
    /// note editing, or newly generated clip identities. No media file is opened.
    func isCurrent(for project: FilmProject) -> Bool {
        guard rangeStart.isFinite, rangeEnd.isFinite, rangeStart >= 0,
              rangeEnd > rangeStart, rangeEnd <= project.duration,
              originalVolume == project.originalVolume,
              sourceClips.count == project.videoClips.count,
              sourceMusic.count == project.music.count else { return false }
        let sameVideo = zip(sourceClips, project.videoClips).allSatisfy { old, current in
            old.sourcePath == current.sourcePath && old.sourceDuration == current.sourceDuration &&
            old.sourceIn == current.sourceIn && old.sourceOut == current.sourceOut &&
            old.frameRate == current.frameRate && old.width == current.width && old.height == current.height
        }
        let sameAudio = zip(sourceMusic, project.music).allSatisfy { old, current in
            old.sourcePath == current.sourcePath && old.sourceDuration == current.sourceDuration &&
            old.sourceIn == current.sourceIn && old.sourceOut == current.sourceOut &&
            old.timelineStart == current.timelineStart && old.volume == current.volume
        }
        return sameVideo && sameAudio
    }
}

extension ScriptAnalysis {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, modelID, sourceClips, rangeStart, rangeEnd, title, synopsis, structure
        case segments, caveats, inputMode, sourceMusic, originalVolume, timelineNoteIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modelID = try c.decode(String.self, forKey: .modelID)
        sourceClips = try c.decode([VideoClip].self, forKey: .sourceClips)
        rangeStart = try c.decode(Double.self, forKey: .rangeStart)
        rangeEnd = try c.decode(Double.self, forKey: .rangeEnd)
        title = try c.decode(String.self, forKey: .title)
        synopsis = try c.decode(String.self, forKey: .synopsis)
        structure = try c.decode(String.self, forKey: .structure)
        segments = try c.decode([ScriptSegment].self, forKey: .segments)
        caveats = try c.decode(String.self, forKey: .caveats)
        inputMode = try c.decode(String.self, forKey: .inputMode)
        sourceMusic = try c.decodeIfPresent([MusicClip].self, forKey: .sourceMusic) ?? []
        originalVolume = try c.decodeIfPresent(Double.self, forKey: .originalVolume) ?? 1
        timelineNoteIDs = try c.decodeIfPresent([UUID].self, forKey: .timelineNoteIDs) ?? []
    }
}

struct FilmProject: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var sourcePath: String
    var duration: Double
    var frameRate: Double
    var width: Int
    var height: Int
    var cuts: [Double]
    var notes: [StudyNote]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isDemo: Bool = false
    var kind: ProjectKind = .study
    var clips: [VideoClip] = []
    var music: [MusicClip] = []
    var originalVolume: Double = 1
    var scriptAnalyses: [ScriptAnalysis] = []
    var subtitleTrack: SubtitleTrack? = nil

    var videoClips: [VideoClip] {
        if !clips.isEmpty { return clips }
        guard duration.isFinite, duration > 0 else { return [] }
        return [VideoClip(id: id, title: title, sourcePath: sourcePath, sourceDuration: duration,
                          sourceIn: 0, sourceOut: duration, frameRate: frameRate, width: width, height: height,
                          sourceProjectID: id, sourceProjectTitle: title)]
    }

    var clipPlacements: [ClipPlacement] {
        var start = 0.0
        return videoClips.map { clip in
            let placement = ClipPlacement(clip: clip, start: start)
            start += clip.duration
            return placement
        }
    }

    var shots: [StudyShot] {
        guard duration.isFinite, duration > 0 else { return [] }
        let seams = clipPlacements.dropFirst().map(\.start).filter { $0.isFinite && $0 > 0 && $0 < duration }
        let interior = Set(ProjectLogic.normalizedCuts(cuts, in: self) + seams).sorted()
        let boundaries = [0.0] + interior + [duration]
        return (0..<(boundaries.count - 1)).map {
            StudyShot(index: $0, start: boundaries[$0], end: boundaries[$0 + 1])
        }
    }
}

// Putting the custom decoder in an extension preserves the synthesized memberwise
// initializer, including defaults for all fields added after version 1.0.1.
extension FilmProject {
    private enum CodingKeys: String, CodingKey {
        case id, title, sourcePath, duration, frameRate, width, height, cuts, notes
        case createdAt, updatedAt, isDemo, kind, clips, music, originalVolume, scriptAnalyses, subtitleTrack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        duration = try c.decode(Double.self, forKey: .duration)
        frameRate = try c.decode(Double.self, forKey: .frameRate)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        cuts = try c.decode([Double].self, forKey: .cuts)
        notes = try c.decode([StudyNote].self, forKey: .notes)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        isDemo = try c.decodeIfPresent(Bool.self, forKey: .isDemo) ?? false
        kind = try c.decodeIfPresent(ProjectKind.self, forKey: .kind) ?? .study
        clips = try c.decodeIfPresent([VideoClip].self, forKey: .clips) ?? []
        music = try c.decodeIfPresent([MusicClip].self, forKey: .music) ?? []
        originalVolume = try c.decodeIfPresent(Double.self, forKey: .originalVolume) ?? 1
        scriptAnalyses = try c.decodeIfPresent([ScriptAnalysis].self, forKey: .scriptAnalyses) ?? []
        subtitleTrack = try c.decodeIfPresent(SubtitleTrack.self, forKey: .subtitleTrack)
    }
}

struct StudyShot: Identifiable, Equatable {
    var index: Int
    var start: Double
    var end: Double
    var id: Int { index }
    var duration: Double { end - start }
}

/// Non-drop-frame timecode. Invalid inputs display the start of the film.
func timecode(_ seconds: Double, frameRate: Double = 30) -> String {
    let rate = validFrameRate(frameRate)
    let nominalRate = Int(rate.rounded())
    let frameValue = (max(0, seconds.isFinite ? seconds : 0) * rate).rounded()
    // The cap avoids integer overflow for malformed values passed directly by callers.
    let frames = Int(min(frameValue, Double(Int.max / 2)))
    let totalSeconds = frames / nominalRate
    return String(format: "%02d:%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, frames % nominalRate)
}

private func validFrameRate(_ rate: Double) -> Double {
    rate.isFinite && rate >= 1 && rate <= 240 ? rate : 30
}

enum SequenceLogic {
    /// Reconcile derived sequence length without moving existing timeline edits.
    /// Reordering/trimming must use the dedicated operations below to remap edits.
    static func recalculate(_ project: FilmProject) -> FilmProject {
        var result = project
        if !result.clips.isEmpty {
            guard result.clips.allSatisfy({ $0.duration.isFinite && $0.duration > 0 }) else { return project }
            let total = result.clips.reduce(0) { $0 + $1.duration }
            guard total.isFinite, total > 0 else { return project }
            result.duration = total
            result.sourcePath = result.clips[0].sourcePath
        }
        guard result.duration.isFinite, result.duration > 0 else { return result }
        result.cuts = ProjectLogic.normalizedCuts(result.cuts, in: result)
        result.notes = clampedNotes(result.notes, duration: result.duration)
        result.music = result.music.compactMap { clip in
            guard clip.timelineStart.isFinite, clip.sourceIn.isFinite, clip.sourceOut.isFinite,
                  clip.sourceDuration.isFinite else { return nil }
            var item = clip
            // Moving audio left of zero discards its inaudible prefix, preserving
            // the source sample that should be heard at sequence time zero.
            if item.timelineStart < 0 {
                item.sourceIn -= item.timelineStart
                item.timelineStart = 0
            }
            guard item.timelineStart < result.duration else { return nil }
            item.sourceIn = max(0, item.sourceIn)
            item.sourceOut = min(item.sourceOut, item.sourceDuration,
                                 item.sourceIn + result.duration - item.timelineStart)
            return item.duration > 0 ? item : nil
        }
        return result
    }

    static func extract(_ project: FilmProject, start: Double, end: Double) -> [VideoClip] {
        guard start.isFinite, end.isFinite, end > start else { return [] }
        let lower = max(0, start), upper = min(project.duration, end)
        guard upper > lower else { return [] }
        return project.clipPlacements.compactMap { placement in
            let from = max(lower, placement.start), to = min(upper, placement.end)
            guard to > from else { return nil }
            var clip = placement.clip
            clip.id = UUID()
            clip.sourceIn = max(placement.clip.sourceIn, min(placement.clip.sourceOut, placement.clip.sourceIn + from - placement.start))
            clip.sourceOut = min(placement.clip.sourceOut, placement.clip.sourceIn + to - placement.start)
            clip.sourceProjectID = clip.sourceProjectID ?? project.id
            clip.sourceProjectTitle = clip.sourceProjectTitle ?? project.title
            return clip
        }
    }

    static func makeProject(title: String, clips: [VideoClip], kind: ProjectKind = .study) -> FilmProject {
        let first = clips.first
        let project = FilmProject(title: title, sourcePath: first?.sourcePath ?? "",
                                  duration: clips.reduce(0) { $0 + $1.duration },
                                  frameRate: first?.frameRate ?? 30,
                                  width: first?.width ?? 1920, height: first?.height ?? 1080,
                                  cuts: [], notes: [], kind: kind, clips: clips)
        return recalculate(project)
    }

    static func moveClip(_ project: FilmProject, id: UUID, delta: Int) -> FilmProject {
        var clips = project.videoClips
        guard let index = clips.firstIndex(where: { $0.id == id }), clips.count > 1 else { return project }
        let destination = max(0, min(clips.count - 1, index + max(-clips.count, min(clips.count, delta))))
        guard destination != index else { return project }
        let moved = clips.remove(at: index)
        clips.insert(moved, at: destination)
        return remap(project, to: clips)
    }

    static func trimClip(_ project: FilmProject, id: UUID, sourceIn: Double, sourceOut: Double) -> FilmProject {
        var clips = project.videoClips
        guard let index = clips.firstIndex(where: { $0.id == id }),
              sourceIn.isFinite, sourceOut.isFinite,
              sourceIn >= 0, sourceOut > sourceIn, sourceOut <= clips[index].sourceDuration else { return project }
        guard clips[index].sourceIn != sourceIn || clips[index].sourceOut != sourceOut else { return project }
        clips[index].sourceIn = sourceIn
        clips[index].sourceOut = sourceOut
        return remap(project, to: clips)
    }

    static func removeClip(_ project: FilmProject, id: UUID) -> FilmProject {
        let original = project.videoClips
        guard original.count > 1, original.contains(where: { $0.id == id }) else { return project }
        return remap(project, to: original.filter { $0.id != id })
    }

    static func splitMusic(_ project: FilmProject, id: UUID, at time: Double) -> FilmProject {
        guard time.isFinite, let index = project.music.firstIndex(where: { $0.id == id }) else { return project }
        let clip = project.music[index]
        guard time > clip.timelineStart, time < clip.timelineStart + clip.duration else { return project }
        let sourceTime = clip.sourceIn + time - clip.timelineStart
        var left = clip, right = clip
        left.sourceOut = sourceTime
        right.id = UUID()
        right.sourceIn = sourceTime
        right.timelineStart = time
        var result = project
        result.music.replaceSubrange(index...index, with: [left, right])
        return result
    }

    private static func clampedNotes(_ notes: [StudyNote], duration: Double) -> [StudyNote] {
        notes.compactMap { note in
            guard note.start.isFinite, note.end.isFinite else { return nil }
            let lower = min(note.start, note.end), upper = max(note.start, note.end)
            guard note.hasContent || (upper >= 0 && lower <= duration) else { return nil }
            var result = note
            result.start = min(duration, max(0, lower))
            result.end = min(duration, max(0, upper))
            return result
        }
    }

    /// Anchors cuts and note fragments to source-time coordinates in stable clip
    /// identities. Background music remains anchored to the sequence timeline.
    private static func remap(_ project: FilmProject, to clips: [VideoClip]) -> FilmProject {
        guard Set(clips.map(\.id)).count == clips.count,
              Set(project.videoClips.map(\.id)).count == project.videoClips.count else { return project }
        let oldPlacements = project.clipPlacements
        var result = project
        result.clips = clips
        result.duration = clips.reduce(0) { $0 + $1.duration }
        let newPlacements = result.clipPlacements
        let byID = Dictionary(uniqueKeysWithValues: newPlacements.map { ($0.id, $0) })
        result.cuts = ProjectLogic.normalizedCuts(project.cuts, in: project).compactMap { cut in
            guard let old = oldPlacements.first(where: { cut > $0.start && cut < $0.end }),
                  let new = byID[old.id] else { return nil }
            let source = old.clip.sourceIn + cut - old.start
            guard source > new.clip.sourceIn, source < new.clip.sourceOut else { return nil }
            return new.start + source - new.clip.sourceIn
        }
        result.notes = project.notes.flatMap { note -> [StudyNote] in
            var fragments: [StudyNote] = []
            for old in oldPlacements {
                let point = note.start == note.end
                if point {
                    // A seam point belongs to the next clip, except at film end.
                    guard note.start >= old.start,
                          note.start < old.end || (note.start == project.duration && old.id == oldPlacements.last?.id) else { continue }
                } else {
                    guard note.start < old.end && note.end > old.start else { continue }
                }
                let sourceStart = old.clip.sourceIn + max(note.start, old.start) - old.start
                let sourceEnd = old.clip.sourceIn + min(note.end, old.end) - old.start
                var fragment = note
                if let new = byID[old.id] {
                    let from = max(sourceStart, new.clip.sourceIn)
                    let to = min(sourceEnd, new.clip.sourceOut)
                    let retained = point ? (from == to && from >= new.clip.sourceIn && from <= new.clip.sourceOut) : to > from
                    if retained {
                        fragment.start = new.start + from - new.clip.sourceIn
                        fragment.end = new.start + to - new.clip.sourceIn
                    } else {
                        guard note.hasContent else { continue }
                        let sourceBoundary = min(new.clip.sourceOut, max(new.clip.sourceIn, sourceStart))
                        fragment.start = new.start + sourceBoundary - new.clip.sourceIn
                        fragment.end = fragment.start
                        fragment = orphaned(fragment)
                    }
                } else {
                    guard note.hasContent else { continue }
                    // When removing a clip, the join is the sum of retained clips
                    // preceding it in the old sequence, not its former absolute time.
                    let preceding = oldPlacements.prefix { $0.id != old.id }
                    let boundary = preceding.reduce(0.0) { $0 + (byID[$1.id]?.clip.duration ?? 0) }
                    fragment.start = min(result.duration, boundary)
                    fragment.end = fragment.start
                    fragment = orphaned(fragment)
                }
                fragments.append(fragment)
            }
            if fragments.isEmpty, note.hasContent {
                var retained = note
                retained.start = min(result.duration, max(0, note.start))
                retained.end = retained.start
                fragments = [orphaned(retained)]
            }
            fragments.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            for index in fragments.indices { fragments[index].id = index == 0 ? note.id : UUID() }
            return fragments
        }
        return recalculate(result)
    }

    private static func orphaned(_ note: StudyNote) -> StudyNote {
        var result = note
        let explanation = "[原标记对应的画面已裁切或移除；笔记保留在素材边界，供回顾。]"
        if !result.body.contains(explanation) {
            result.body += result.body.isEmpty ? explanation : "\n\n" + explanation
        }
        return result
    }
}

enum ProjectLogic {
    /// Snap within each source clip's own frame grid. Clip seams are implicit
    /// boundaries and must never drift onto the sequence's nominal frame grid.
    static func normalizedCuts(_ cuts: [Double], in project: FilmProject) -> [Double] {
        guard !project.clips.isEmpty else {
            return normalizedCuts(cuts, duration: project.duration, frameRate: project.frameRate)
        }
        let placements = project.clipPlacements
        var result: [Double] = []
        for value in cuts where value.isFinite && value > 0 && value < project.duration {
            guard let placement = placements.first(where: { value >= $0.start && value < $0.end }) else { continue }
            let rate = validFrameRate(placement.clip.frameRate)
            let source = ((placement.clip.sourceIn + value - placement.start) * rate).rounded() / rate
            let time = placement.start + source - placement.clip.sourceIn
            guard time > placement.start + 0.000_000_1, time < placement.end - 0.000_000_1 else { continue }
            result.append(time)
        }
        return Set(result).sorted()
    }

    /// Cut points are frame boundaries inside the clip; clip edges are implicit.
    static func normalizedCuts(_ cuts: [Double], duration: Double, frameRate: Double) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let rate = validFrameRate(frameRate)
        let snapped = cuts.compactMap { value -> Double? in
            guard value.isFinite, value > 0, value < duration else { return nil }
            let frame = (value * rate).rounded()
            guard frame.isFinite else { return nil }
            let time = frame / rate
            return time > 0 && time < duration ? time : nil
        }.sorted()
        var result: [Double] = []
        for value in snapped {
            if let last = result.last, abs(value - last) < 0.000_000_1 { continue }
            result.append(value)
        }
        return result
    }

    static func split(_ project: FilmProject, at time: Double) -> FilmProject {
        var result = project
        result.cuts = normalizedCuts(project.cuts + [time], in: project)
        return result
    }

    static func removeCut(_ project: FilmProject, at time: Double) -> FilmProject {
        var result = project
        let normalized = normalizedCuts(project.cuts, in: project)
        let target = normalizedCuts([time], in: project).first
        result.cuts = normalized.filter { cut in
            guard let target = target else { return true }
            return abs(cut - target) >= 0.000_000_1
        }
        return result
    }

    static func shotIndex(_ project: FilmProject, at time: Double) -> Int {
        let shots = project.shots
        guard !shots.isEmpty, !time.isNaN, time > 0 else { return 0 }
        if time >= project.duration { return shots.count - 1 }
        // A cut belongs to the shot beginning at that cut, matching playback.
        return shots.lastIndex(where: { $0.start <= time }) ?? 0
    }

    static func exportMarkdown(_ project: FilmProject) -> String {
        let rate = project.frameRate
        var lines = [
            "# \(heading(project.title)) · 拉片笔记", "",
            "- 时长：\(timecode(project.duration, frameRate: rate))",
            "- 画面：\(project.width) × \(project.height) · \(String(format: "%.3f", rate)) fps",
            "- 镜头：\(project.shots.count) 个 · 笔记：\(project.notes.count) 条",
            "- 类型：\(project.kind == .remix ? "混剪练习" : "拉片学习")",
            "- 原声音量：\(String(format: "%.0f", project.originalVolume * 100))%",
            "- 时间码：时:分:秒:帧（非丢帧；时间轴按项目帧率，素材入出点按各自帧率）", "",
            "## 素材与来源", "",
            "| 顺序 | 素材 | 时间轴范围 | 源视频入点–出点 | 来源项目 | 本机源文件 |",
            "| --- | --- | --- | --- | --- | --- |"
        ]
        for (index, placement) in project.clipPlacements.enumerated() {
            let clip = placement.clip
            let provenance = clip.sourceProjectTitle ?? (clip.sourceProjectID?.uuidString ?? "本机导入")
            lines.append("| \(index + 1) | \(tableCell(clip.title)) | \(timecode(placement.start, frameRate: rate))–\(timecode(placement.end, frameRate: rate)) | \(timecode(clip.sourceIn, frameRate: clip.frameRate))–\(timecode(clip.sourceOut, frameRate: clip.frameRate)) | \(tableCell(provenance)) | \(tableCell(clip.sourcePath)) |")
        }
        lines += ["", "## 音乐编排", ""]
        if project.music.isEmpty { lines.append("未添加独立音乐素材。") }
        else {
            lines += ["| 音乐 | 时间轴范围 | 源音频入点–出点 | 音量 | 本机源文件 |", "| --- | --- | --- | --- | --- |"]
            for clip in project.music.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                lines.append("| \(tableCell(clip.title)) | \(timecode(clip.timelineStart, frameRate: rate))–\(timecode(clip.timelineStart + clip.duration, frameRate: rate)) | \(String(format: "%.3f", clip.sourceIn))–\(String(format: "%.3f", clip.sourceOut)) 秒 | \(String(format: "%.0f", clip.volume * 100))% | \(tableCell(clip.sourcePath)) |")
            }
        }
        lines += ["", "## 镜头结构", "", "| 镜头 | 入点 | 出点 | 时长 | 覆盖的笔记 |", "| --- | --- | --- | --- | --- |"]
        for shot in project.shots {
            let notes = orderedNotes(project.notes).filter { note in
                if note.start == note.end {
                    return shotIndex(project, at: note.start) == shot.index
                }
                return note.start < shot.end && note.end > shot.start
            }
            let labels = notes.map { "\($0.track.title)：\(tableCell($0.displayTitle))" }.joined(separator: "；")
            lines.append("| \(String(format: "%02d", shot.index + 1)) | \(timecode(shot.start, frameRate: rate)) | \(timecode(shot.end, frameRate: rate)) | \(String(format: "%.2f", shot.duration)) 秒 | \(labels.isEmpty ? "待观察" : labels) |")
        }
        for track in NoteTrack.allCases {
            lines += ["", "## \(track.title)", ""]
            let notes = orderedNotes(project.notes.filter { $0.track == track })
            if notes.isEmpty { lines.append("暂未记录。") }
            for note in notes {
                lines += [
                    "### \(timecode(note.start, frameRate: rate))–\(timecode(note.end, frameRate: rate)) · \(heading(note.displayTitle))", "",
                    note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（待补充观察）" : note.body, ""
                ]
                if !note.takeaway.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines += ["**复用启发**", "", note.takeaway, ""]
                }
            }
        }
        lines += ["", "## 可复用的创作启发", ""]
        let takeaways = orderedNotes(project.notes).filter { !$0.takeaway.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if takeaways.isEmpty { lines.append("回看关键镜头后，记录下一次创作中可以亲自验证的做法。") }
        for note in takeaways {
            lines += ["### \(heading(note.displayTitle)) · \(timecode(note.start, frameRate: rate))", "", note.takeaway, ""]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func exportAnalysisPrompt(_ project: FilmProject) -> String {
        return """
        请作为我的短视频拉片学习教练，分析我实际提交的视频《\(heading(project.title))》。

        必须先确认我已向你提交真实视频文件，且你可以读取对应画面和音轨。本提示词、时间码和人工笔记不包含视频或音频数据；若未收到视频，请要求我上传，不能根据标题、文件路径或笔记臆测内容。如果只能看画面或静音视频，必须明确说明声音无法判断，不得编造音乐、拟音、环境声或声音转场。

        如果记录包含多个素材或独立音乐，请以按下列时间轴实际合成并提交的完整视频为准；单个源素材不能代表整条混剪的剪辑节奏或混音结果。来源项目仅用于追溯素材，不能作为未提交媒体的内容证据。

        学习目的：理解镜头前后如何建立逻辑，镜头设计如何服务表达，以及声音如何引导注意力。请区分“可直接观察的事实”“有依据的解释”“待验证的假设”；人工笔记是我的初步观察，不能当作已经证实的事实。

        请以实际视频的时间码为依据，逐镜头提供：
        1. 叙事逻辑：本镜头承担的信息、与前后镜头的关系、铺垫与回收、情绪和节奏变化。
        2. 镜头设计：景别、角度、构图、视线、运动、光色、主体调度和转场；说明设计怎样影响观感，不要仅罗列术语。
        3. 声音设计：在确实听到音轨时，指出对白、音乐、环境声、拟音、静默的入点与出点，节拍关系、声画同步或错位及其作用。无证据处写“无法判断”。
        4. 学习启发：提炼可复用的设计原则、适用场景、容易失败的条件，并给一个可以自己动手完成的小练习。

        输出一个按镜头排序的表格（时间段 / 可观察事实 / 前后逻辑 / 镜头原理 / 声音作用 / 可复用做法），再给出全片节奏分析和三条优先练习。对疑似 AI 生成痕迹只描述具体画面证据，不能凭风格断言模型、提示词或生成流程。人工切点可能不准确，请依据实际视频说明修正建议。

        以下是镜读导出的人工学习记录，供参考：

        \(exportMarkdown(project))
        """
    }

    private static func orderedNotes(_ notes: [StudyNote]) -> [StudyNote] {
        notes.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func heading(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private static func tableCell(_ value: String) -> String {
        heading(value).replacingOccurrences(of: "|", with: "\\|")
    }
}

enum ProjectDataError: LocalizedError {
    case invalid(String)
    case unreadable(String)
    case unwritable(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "项目数据无效：\(reason)"
        case .unreadable(let reason): return "无法读取项目：\(reason)"
        case .unwritable(let reason): return "无法保存项目：\(reason)"
        }
    }
}

enum ProjectPersistence {
    /// Set JINGDU_LIBRARY_DIRECTORY to a nonempty absolute directory to run an
    /// isolated app/test library. The default is unchanged for ordinary launches.
    /// This overrides only library.json, never the referenced source media.
    private static var libraryURL: URL {
        if let directory = ProcessInfo.processInfo.environment["JINGDU_LIBRARY_DIRECTORY"],
           !directory.isEmpty, directory.hasPrefix("/"), !directory.contains("\0") {
            return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("library.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jingdu", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    static func load() throws -> [FilmProject] {
        let url = libraryURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ProjectDataError.unreadable(error.localizedDescription) }
        do {
            let projects = try decoder().decode([FilmProject].self, from: data)
            return try validatedLibrary(projects)
        } catch let error as ProjectDataError { throw error }
        catch { throw ProjectDataError.unreadable(decodingMessage(error)) }
    }

    /// Saves the complete library with one atomic replacement; source video files are never changed.
    static func save(_ projects: [FilmProject]) throws {
        let validated = try validatedLibrary(projects)
        let data: Data
        do { data = try encoder().encode(validated) }
        catch { throw ProjectDataError.unwritable(error.localizedDescription) }
        let url = libraryURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { throw ProjectDataError.unwritable(error.localizedDescription) }
    }

    static func decodeProject(_ data: Data) throws -> FilmProject {
        guard data.count <= 20 * 1024 * 1024 else {
            throw ProjectDataError.invalid("项目文件超过 20 MB，请检查是否误选了视频文件。")
        }
        do {
            return try validate(decoder().decode(FilmProject.self, from: data))
        } catch let error as ProjectDataError { throw error }
        catch { throw ProjectDataError.invalid(decodingMessage(error)) }
    }

    static func encodeProject(_ project: FilmProject) throws -> Data {
        let validated = try validate(project)
        do { return try encoder().encode(validated) }
        catch { throw ProjectDataError.invalid("项目无法转换为 JSON：\(error.localizedDescription)") }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func validatedLibrary(_ projects: [FilmProject]) throws -> [FilmProject] {
        guard Set(projects.map(\.id)).count == projects.count else {
            throw ProjectDataError.invalid("作品库内出现重复的项目 ID。请保留原文件并检查导入内容。")
        }
        return try projects.map(validate)
    }

    private static func validate(_ project: FilmProject) throws -> FilmProject {
        guard !project.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectDataError.invalid("项目名称不能为空。")
        }
        guard project.title.count <= 500 else { throw ProjectDataError.invalid("项目名称不能超过 500 字。") }
        guard project.duration.isFinite, project.duration > 0, project.duration <= 86_400 else {
            throw ProjectDataError.invalid("视频时长必须大于 0 且不超过 24 小时。")
        }
        guard project.frameRate.isFinite, (1...240).contains(project.frameRate) else {
            throw ProjectDataError.invalid("视频帧率必须在 1–240 fps 之间。")
        }
        guard (1...16_384).contains(project.width), (1...16_384).contains(project.height) else {
            throw ProjectDataError.invalid("画面宽高必须在 1–16384 像素之间。")
        }
        guard (project.isDemo && project.sourcePath.isEmpty) || (project.sourcePath.hasPrefix("/") && !project.sourcePath.contains("\0")) else {
            throw ProjectDataError.invalid("源视频必须使用本机绝对路径；项目文件不会包含或复制视频。")
        }
        guard project.createdAt.timeIntervalSince1970.isFinite, project.updatedAt.timeIntervalSince1970.isFinite else {
            throw ProjectDataError.invalid("创建或更新时间无效。")
        }
        guard project.originalVolume.isFinite, (0...1).contains(project.originalVolume) else {
            throw ProjectDataError.invalid("原声音量必须在 0–100% 之间。")
        }
        guard project.clips.count <= 10_000, project.music.count <= 10_000 else {
            throw ProjectDataError.invalid("视频片段或音乐素材过多，最多支持各 10000 个。")
        }
        guard Set(project.clips.map(\.id)).count == project.clips.count else {
            throw ProjectDataError.invalid("视频片段 ID 重复，无法安全跟随素材移动笔记。")
        }
        guard Set(project.music.map(\.id)).count == project.music.count else {
            throw ProjectDataError.invalid("音乐素材 ID 重复。")
        }
        for (index, clip) in project.clips.enumerated() {
            let label = "第 \(index + 1) 个视频片段"
            try validateSource(title: clip.title, path: clip.sourcePath, duration: clip.sourceDuration,
                               start: clip.sourceIn, end: clip.sourceOut, label: label)
            guard clip.frameRate.isFinite, (1...240).contains(clip.frameRate),
                  (1...16_384).contains(clip.width), (1...16_384).contains(clip.height) else {
                throw ProjectDataError.invalid("\(label)的帧率或宽高超出支持范围。")
            }
            guard (clip.sourceProjectTitle?.count ?? 0) <= 500 else {
                throw ProjectDataError.invalid("\(label)的来源项目名称不能超过 500 字。")
            }
        }
        if let first = project.clips.first {
            let total = project.clips.reduce(0) { $0 + $1.duration }
            guard total.isFinite, abs(total - project.duration) <= max(0.000_001, total * 0.000_000_001) else {
                throw ProjectDataError.invalid("项目时长与视频片段总时长不一致，请重新计算时间轴。")
            }
            guard project.sourcePath == first.sourcePath else {
                throw ProjectDataError.invalid("项目源路径与首个视频片段不一致，请重新计算时间轴。")
            }
        }
        for (index, clip) in project.music.enumerated() {
            let label = "第 \(index + 1) 个音乐素材"
            try validateSource(title: clip.title, path: clip.sourcePath, duration: clip.sourceDuration,
                               start: clip.sourceIn, end: clip.sourceOut, label: label)
            guard clip.timelineStart.isFinite, clip.timelineStart >= 0,
                  clip.timelineStart + clip.duration <= project.duration + 0.000_000_1 else {
                throw ProjectDataError.invalid("\(label)的时间轴范围必须在视频时长之内。")
            }
            guard clip.volume.isFinite, (0...1).contains(clip.volume) else {
                throw ProjectDataError.invalid("\(label)的音量必须在 0–100% 之间。")
            }
        }
        guard project.cuts.count <= 100_000, project.notes.count <= 100_000 else {
            throw ProjectDataError.invalid("镜头切点或笔记数量过多，最多支持各 100000 个。")
        }
        guard project.cuts.allSatisfy({ $0.isFinite }) else {
            throw ProjectDataError.invalid("镜头切点包含无效时间。")
        }
        guard Set(project.notes.map(\.id)).count == project.notes.count else {
            throw ProjectDataError.invalid("笔记 ID 重复，无法安全区分笔记。")
        }
        for (index, note) in project.notes.enumerated() {
            guard note.start.isFinite, note.end.isFinite, note.start >= 0, note.end >= note.start, note.end <= project.duration else {
                throw ProjectDataError.invalid("第 \(index + 1) 条笔记的时间必须满足 0 ≤ 开始 ≤ 结束 ≤ 视频时长。")
            }
            guard note.title.count <= 500, note.body.count <= 200_000, note.takeaway.count <= 200_000 else {
                throw ProjectDataError.invalid("第 \(index + 1) 条笔记过长（标题最多 500 字，正文与启发各最多 200000 字）。")
            }
        }
        guard project.scriptAnalyses.count <= 20 else {
            throw ProjectDataError.invalid("每个项目最多保留 20 份脚本分析，请先移除较旧的分析记录。")
        }
        guard Set(project.scriptAnalyses.map(\.id)).count == project.scriptAnalyses.count else {
            throw ProjectDataError.invalid("脚本分析 ID 重复。")
        }
        // Historical results are checked against their original snapshots, not
        // the current edit. Shortening a project must not destroy old analyses.
        for analysis in project.scriptAnalyses { try validateScriptAnalysis(analysis) }
        // A stale track remains exportable against its original video snapshot;
        // callers use isCurrent(for:) before showing it over an edited project.
        if let track = project.subtitleTrack { try validateSubtitleTrack(track) }
        var normalized = project
        normalized.cuts = ProjectLogic.normalizedCuts(project.cuts, in: project)
        return normalized
    }

    static func validateSubtitleTrack(_ track: SubtitleTrack) throws {
        guard track.createdAt.timeIntervalSince1970.isFinite,
              !track.sourceDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              track.sourceDescription.count <= 5_000 else {
            throw ProjectDataError.invalid("字幕的创建时间或来源说明无效，来源说明不能为空且最多 5000 字。")
        }
        guard !track.sourceClips.isEmpty, track.sourceClips.count <= 10_000,
              Set(track.sourceClips.map(\.id)).count == track.sourceClips.count else {
            throw ProjectDataError.invalid("字幕的视频素材快照缺失、数量过多或存在重复 ID。")
        }
        for clip in track.sourceClips {
            try validateSource(title: clip.title, path: clip.sourcePath, duration: clip.sourceDuration,
                               start: clip.sourceIn, end: clip.sourceOut, label: "字幕的视频快照")
            guard clip.frameRate.isFinite, (1...240).contains(clip.frameRate),
                  (1...16_384).contains(clip.width), (1...16_384).contains(clip.height),
                  (clip.sourceProjectTitle?.count ?? 0) <= 500 else {
                throw ProjectDataError.invalid("字幕的视频快照参数无效。")
            }
        }
        let duration = track.sourceClips.reduce(0) { $0 + $1.duration }
        guard duration.isFinite, duration > 0, duration <= 86_400 else {
            throw ProjectDataError.invalid("字幕素材快照的总时长必须大于 0 且不超过 24 小时。")
        }
        guard track.cues.count <= 5_000, Set(track.cues.map(\.id)).count == track.cues.count else {
            throw ProjectDataError.invalid("每份字幕最多包含 5000 句，字幕 ID 不能重复。")
        }
        var previousEnd = 0.0
        for (index, cue) in track.cues.enumerated() {
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= previousEnd,
                  cue.end > cue.start, cue.end <= duration else {
                throw ProjectDataError.invalid("第 \(index + 1) 条字幕时间无效：须在原素材快照内按时间排列且不重叠。")
            }
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let chinese = cue.chineseText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, cue.text.count <= 5_000, cue.chineseText.count <= 5_000,
                  !cue.text.contains("\0"), !cue.chineseText.contains("\0") else {
                throw ProjectDataError.invalid("第 \(index + 1) 条字幕原文不能为空，原文与中文各最多 5000 字且不能包含空字符。")
            }
            if cue.language == .zh {
                guard chinese.isEmpty || chinese == text else {
                    throw ProjectDataError.invalid("第 \(index + 1) 条中文字幕无需另写不同译文，请保留原文。")
                }
            } else {
                guard !chinese.isEmpty, chinese.range(of: #"\p{Han}"#, options: .regularExpression) != nil else {
                    throw ProjectDataError.invalid("第 \(index + 1) 条非中文字幕必须同时包含中文译文。")
                }
            }
            previousEnd = cue.end
        }
    }

    static func validateScriptAnalysis(_ analysis: ScriptAnalysis) throws {
        guard analysis.createdAt.timeIntervalSince1970.isFinite,
              !analysis.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, analysis.modelID.count <= 200,
              !analysis.inputMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, analysis.inputMode.count <= 100 else {
            throw ProjectDataError.invalid("脚本分析的日期、模型名称或输入方式无效。")
        }
        guard !analysis.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, analysis.title.count <= 500,
              analysis.synopsis.count <= 200_000, analysis.structure.count <= 200_000, analysis.caveats.count <= 200_000 else {
            throw ProjectDataError.invalid("脚本分析标题不能为空且最多 500 字，概述、结构和说明各最多 200000 字。")
        }
        guard !analysis.sourceClips.isEmpty, analysis.sourceClips.count <= 10_000, analysis.sourceMusic.count <= 10_000,
              Set(analysis.sourceClips.map(\.id)).count == analysis.sourceClips.count,
              Set(analysis.sourceMusic.map(\.id)).count == analysis.sourceMusic.count else {
            throw ProjectDataError.invalid("脚本分析的素材快照缺失、数量过多或存在重复 ID。")
        }
        for clip in analysis.sourceClips {
            try validateSource(title: clip.title, path: clip.sourcePath, duration: clip.sourceDuration,
                               start: clip.sourceIn, end: clip.sourceOut, label: "脚本分析的视频快照")
            guard clip.frameRate.isFinite, (1...240).contains(clip.frameRate),
                  (1...16_384).contains(clip.width), (1...16_384).contains(clip.height),
                  (clip.sourceProjectTitle?.count ?? 0) <= 500 else {
                throw ProjectDataError.invalid("脚本分析的视频快照参数无效。")
            }
        }
        let duration = analysis.sourceClips.reduce(0) { $0 + $1.duration }
        guard duration.isFinite, duration > 0, duration <= 86_400,
              analysis.rangeStart.isFinite, analysis.rangeEnd.isFinite,
              analysis.rangeStart >= 0, analysis.rangeEnd > analysis.rangeStart, analysis.rangeEnd <= duration else {
            throw ProjectDataError.invalid("脚本分析范围必须在原素材快照的时间轴内，且结束时间大于开始时间。")
        }
        guard analysis.originalVolume.isFinite, (0...1).contains(analysis.originalVolume) else {
            throw ProjectDataError.invalid("脚本分析的原声音量快照无效。")
        }
        for music in analysis.sourceMusic {
            try validateSource(title: music.title, path: music.sourcePath, duration: music.sourceDuration,
                               start: music.sourceIn, end: music.sourceOut, label: "脚本分析的音乐快照")
            guard music.timelineStart.isFinite, music.timelineStart >= 0,
                  music.timelineStart + music.duration <= duration + 0.000_000_1,
                  music.volume.isFinite, (0...1).contains(music.volume) else {
                throw ProjectDataError.invalid("脚本分析的音乐快照超出原时间轴或音量范围。")
            }
        }
        guard !analysis.segments.isEmpty, analysis.segments.count <= 2_000,
              Set(analysis.segments.map(\.id)).count == analysis.segments.count else {
            throw ProjectDataError.invalid("脚本分析需包含 1–2000 个片段，片段 ID 不能重复。")
        }
        var previousEnd = analysis.rangeStart
        var cueIDs = Set<UUID>()
        var cueCount = 0
        var textBytes = analysis.title.utf8.count + analysis.synopsis.utf8.count + analysis.structure.utf8.count + analysis.caveats.utf8.count
        for (index, segment) in analysis.segments.enumerated() {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= analysis.rangeStart,
                  segment.end > segment.start, segment.end <= analysis.rangeEnd, segment.start >= previousEnd else {
                throw ProjectDataError.invalid("脚本第 \(index + 1) 段时间无效：必须按顺序排列、不重叠，并处于分析范围之内。")
            }
            let descriptions = [segment.screenplay, segment.visual, segment.action, segment.dialogue, segment.sound,
                                segment.camera, segment.transition, segment.reasoning, segment.uncertainty]
            guard descriptions.allSatisfy({ $0.count <= 20_000 }) else {
                throw ProjectDataError.invalid("脚本第 \(index + 1) 段的单项描述不能超过 20000 字。")
            }
            textBytes += descriptions.reduce(0) { $0 + $1.utf8.count }
            guard segment.dialogueCues.count <= 200 else {
                throw ProjectDataError.invalid("脚本第 \(index + 1) 段最多包含 200 句台词。")
            }
            var previousCueEnd = segment.start
            for cue in segment.dialogueCues {
                guard cue.start.isFinite, cue.end.isFinite, cue.start >= segment.start,
                      cue.end > cue.start, cue.end <= segment.end, cue.start >= previousCueEnd,
                      cueIDs.insert(cue.id).inserted else {
                    throw ProjectDataError.invalid("脚本第 \(index + 1) 段的台词时间无效：须在本段内按时间排列且不重叠，台词 ID 不能重复。")
                }
                guard cue.speaker.count <= 200, cue.text.count <= 5_000,
                      !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ProjectDataError.invalid("台词内容不能为空且最多 5000 字，说话人最多 200 字。")
                }
                textBytes += cue.speaker.utf8.count + cue.text.utf8.count
                previousCueEnd = cue.end
                cueCount += 1
            }
            previousEnd = segment.end
        }
        guard cueCount <= 10_000 else {
            throw ProjectDataError.invalid("一份脚本最多保留 10000 句台词。")
        }
        guard textBytes <= 4 * 1024 * 1024 else {
            throw ProjectDataError.invalid("单份脚本分析文字超过 4 MB，请缩小分析范围。")
        }
        guard analysis.timelineNoteIDs.count <= 100_000,
              Set(analysis.timelineNoteIDs).count == analysis.timelineNoteIDs.count else {
            throw ProjectDataError.invalid("脚本分析关联的时间轴笔记 ID 重复或数量过多。")
        }
    }

    private static func validateSource(title: String, path: String, duration: Double,
                                       start: Double, end: Double, label: String) throws {
        guard title.count <= 500 else { throw ProjectDataError.invalid("\(label)的名称不能超过 500 字。") }
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw ProjectDataError.invalid("\(label)必须使用本机绝对路径。")
        }
        guard duration.isFinite, duration > 0, duration <= 86_400 else {
            throw ProjectDataError.invalid("\(label)的源文件时长必须大于 0 且不超过 24 小时。")
        }
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= duration else {
            throw ProjectDataError.invalid("\(label)的源区间必须满足 0 ≤ 入点 < 出点 ≤ 源文件时长。")
        }
    }

    private static func decodingMessage(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _):
            return "文件缺少必需字段“\(key.stringValue)”，请使用镜读导出的完整项目 JSON。"
        case DecodingError.typeMismatch(_, let context):
            return "字段“\(context.codingPath.map(\.stringValue).joined(separator: "."))”的格式不正确。"
        case DecodingError.valueNotFound(_, let context):
            return "字段“\(context.codingPath.map(\.stringValue).joined(separator: "."))”不能为空。"
        case DecodingError.dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "文件不是有效的镜读项目 JSON。" : "字段“\(path)”内容无效，请检查 ID、轨道名称和日期格式。"
        default: return error.localizedDescription
        }
    }
}
