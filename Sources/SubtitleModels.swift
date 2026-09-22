import Foundation

enum SubtitleLanguage: String, Codable, CaseIterable, Identifiable {
    case zh, en, ja, ko, es, fr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .zh: return "中文"
        case .en: return "英语"
        case .ja: return "日语"
        case .ko: return "韩语"
        case .es: return "西班牙语"
        case .fr: return "法语"
        }
    }
}

enum SubtitleExportMode: String, CaseIterable, Identifiable {
    case original, chinese, bilingual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "原文"
        case .chinese: return "中文"
        case .bilingual: return "双语"
        }
    }
}

struct SubtitleCue: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var language: SubtitleLanguage
    var text: String
    var chineseText: String

    func lines(mode: SubtitleExportMode) -> [String] {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chinese = chineseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if language == .zh { return [original] }
        switch mode {
        case .original: return [original]
        case .chinese: return [chinese]
        case .bilingual: return original == chinese ? [original] : [original, chinese]
        }
    }
}

struct SubtitleTrack: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var sourceClips: [VideoClip]
    var cues: [SubtitleCue]
    var sourceDescription: String

    /// Original speech belongs to the video sequence, independent of background
    /// music, playback volume, project names, notes, and generated clip IDs.
    func isCurrent(for project: FilmProject) -> Bool {
        let clips = project.videoClips
        guard !sourceClips.isEmpty, sourceClips.count == clips.count else { return false }
        return zip(sourceClips, clips).allSatisfy { old, current in
            old.sourcePath == current.sourcePath && old.sourceDuration == current.sourceDuration &&
            old.sourceIn == current.sourceIn && old.sourceOut == current.sourceOut &&
            old.frameRate == current.frameRate && old.width == current.width && old.height == current.height
        }
    }

    /// Cue ends are exclusive, including the final cue; silence has no caption.
    func activeCue(at time: Double) -> SubtitleCue? {
        guard time.isFinite else { return nil }
        return cues.first { time >= $0.start && time < $0.end }
    }

    func exportSRT(mode: SubtitleExportMode = .bilingual) throws -> String {
        try ProjectPersistence.validateSubtitleTrack(self)
        return try cues.enumerated().map { index, cue in
            let start = Int64((cue.start * 1000).rounded())
            let end = Int64((cue.end * 1000).rounded())
            guard end > start else {
                throw ProjectDataError.invalid("第 \(index + 1) 条字幕的区间不足 1 毫秒，无法准确导出 SRT。")
            }
            let lines = cue.lines(mode: mode).map { $0.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
            return "\(index + 1)\n\(Self.srtTime(start)) --> \(Self.srtTime(end))\n\(lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    private static func srtTime(_ milliseconds: Int64) -> String {
        String(format: "%02lld:%02lld:%02lld,%03lld", milliseconds / 3_600_000,
               milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
