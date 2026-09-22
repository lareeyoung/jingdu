import Foundation

/// A reader cue keeps legacy paragraph-level timing distinct from sentence
/// timing supplied by a new analysis. This is a display value, never persisted.
struct ScriptReadingCue: Identifiable, Equatable {
    let id: UUID
    let segmentID: UUID
    let start: Double
    let end: Double
    let speaker: String
    let text: String
    let isParagraphFallback: Bool
}

enum ScriptReading {
    private static let dialogueLineCache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 512
        cache.totalCostLimit = 2_000_000
        return cache
    }()

    /// Display/export formatting only: never rewrites a cue or infers a
    /// translation. Explicit line breaks (including blank lines) take priority.
    /// For legacy single-line text, split only one unambiguous Chinese/English
    /// clause boundary. Names, code-switching, and uncertain cases stay intact.
    static func dialogueLines(_ text: String) -> [String] {
        if let cached = dialogueLineCache.object(forKey: text as NSString) as? [String] { return cached }
        let lines = uncachedDialogueLines(text)
        dialogueLineCache.setObject(lines as NSArray, forKey: text as NSString, cost: text.utf16.count)
        return lines
    }

    private static func uncachedDialogueLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let explicit = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
        guard explicit.count == 1 else { return explicit }
        guard containsHan(text) else { return [text] }

        let boundaries = matches(#"[\t \u00A0\u3000]+|(?<=[。！？.!?])(?=[\p{Han}\p{Latin}“\"‘'])"#, in: text)
        var candidates: [[String]] = []
        for boundary in boundaries {
            guard let range = Range(boundary.range, in: text) else { continue }
            let left = String(text[..<range.lowerBound])
            let right = String(text[range.upperBound...])
            if isShortBilingualPair(left, right) || isShortBilingualPair(right, left) ||
                (isChineseClause(left) && isEnglishClause(right)) ||
                (isEnglishClause(left) && isChineseClause(right)) {
                candidates.append([left, right])
                if candidates.count > 1 { return [text] }
            }
        }
        return candidates.first ?? [text]
    }

    /// Short conversational pairs have too little grammar for the general rule.
    /// Require both known halves so an English product name remains untouched.
    private static func isShortBilingualPair(_ chinese: String, _ english: String) -> Bool {
        let trimming = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let chinese = chinese.trimmingCharacters(in: trimming)
        let english = english.trimmingCharacters(in: trimming).lowercased()
        let pairs: [String: Set<String>] = [
            "hi": ["嗨", "嘿", "你好"], "hello": ["你好", "嗨"],
            "what now": ["又怎么了", "怎么了", "现在怎么办"],
            "seriously": ["认真的吗", "真的吗", "真的嘛"],
            "oh crap": ["坏了", "糟了", "糟糕"], "oh you": ["噢是你", "哦是你", "是你"],
            "wait": ["等等", "等一下"], "no way": ["不可能", "没门"],
            "thank you": ["谢谢", "谢谢你"]
        ]
        return pairs[english]?.contains(chinese) == true
    }

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func containsHan(_ text: String) -> Bool {
        !matches(#"\p{Han}"#, in: text).isEmpty
    }

    private static func latinWords(_ text: String) -> [String] {
        matches(#"\p{Latin}+(?:['’]\p{Latin}+)?"#, in: text).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func isChineseClause(_ text: String) -> Bool {
        guard matches(#"\p{Han}"#, in: text).count >= 2,
              latinWords(text).count <= 3 else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // Neither half of the English sentence may be absorbed into the Chinese line.
        guard containsHan(String(value.prefix(1))), containsHan(String(value.suffix(1))) else { return false }
        // These endings usually introduce a quoted English expression or name,
        // rather than finish the Chinese half of a bilingual sentence pair.
        let introductions = ["说", "写", "读", "叫", "叫做", "名叫", "名为", "英文", "英语",
                             "单词", "词语", "字幕", "台词", "对白", "对话", "标题", "代码", "变量",
                             "输入", "搜索", "点击", "打开", "选择", "使用", "比如", "例如", "的", "是"]
        return !introductions.contains(where: { value.hasSuffix($0) })
    }

    private static func isEnglishClause(_ text: String) -> Bool {
        guard !containsHan(text) else { return false }
        let words = latinWords(text)
        guard words.count >= 2 else { return false }
        // A title-cased multiword product/name is deliberately left alone.
        guard !words.allSatisfy({ $0.first?.isUppercase == true }) else { return false }
        var tokens = words.map { $0.lowercased().replacingOccurrences(of: "’", with: "'") }
        if ["today", "tomorrow", "yesterday", "now", "then"].contains(tokens[0]), tokens.count > 3 {
            tokens.removeFirst()
        }
        let first = tokens[0]
        let auxiliaries: Set<String> = ["am", "is", "are", "was", "were", "have", "has", "had",
            "can", "can't", "cannot", "could", "couldn't", "will", "won't", "would", "wouldn't",
            "should", "shouldn't", "must", "mustn't", "do", "does", "did", "don't", "doesn't", "didn't",
            "isn't", "aren't", "wasn't", "weren't", "haven't", "hasn't", "hadn't"]
        let imperatives: Set<String> = ["please", "let", "let's", "look", "listen", "stop", "go", "come",
            "get", "give", "take", "tell", "keep", "leave", "wait", "watch", "forget", "remember", "thank"]
        if auxiliaries.contains(first) || imperatives.contains(first) { return true }
        let subjects: Set<String> = ["i", "you", "we", "they", "he", "she", "it", "this", "that",
            "these", "those", "there", "who", "what", "why", "how", "where", "when"]
        let contractions: Set<String> = ["i'm", "i've", "i'll", "i'd", "you're", "you've", "you'll", "you'd",
            "we're", "we've", "we'll", "we'd", "they're", "they've", "they'll", "they'd",
            "he's", "he'll", "he'd", "she's", "she'll", "she'd", "it's", "it'll", "that's", "there's", "what's"]
        if contractions.contains(first) { return true }
        guard subjects.contains(first) else { return false }
        let verbs: Set<String> = ["know", "knows", "think", "thinks", "want", "wants", "need", "needs",
            "like", "likes", "love", "loves", "see", "sees", "saw", "say", "says", "said",
            "feel", "feels", "felt", "look", "looks", "mean", "means", "make", "makes", "made",
            "get", "gets", "got", "go", "goes", "went", "come", "comes", "came", "take", "takes", "took",
            "give", "gives", "gave", "understand", "believe", "remember", "lower", "lowered", "wait", "waits", "choose", "chooses", "bite", "bites", "eat", "eats", "pick", "picks"]
        return tokens.dropFirst().contains { token in
            auxiliaries.contains(token) || verbs.contains(token) || (token.count > 4 && token.hasSuffix("ed"))
        }
    }

    static func displayCues(for segment: ScriptSegment) -> [ScriptReadingCue] {
        if !segment.dialogueCues.isEmpty {
            return segment.dialogueCues.map {
                ScriptReadingCue(id: $0.id, segmentID: segment.id, start: $0.start, end: $0.end,
                                 speaker: $0.speaker, text: $0.text, isParagraphFallback: false)
            }
        }
        guard hasDialogue(segment.dialogue) else { return [] }
        return [ScriptReadingCue(id: segment.id, segmentID: segment.id, start: segment.start,
                                 end: segment.end, speaker: "", text: segment.dialogue,
                                 isParagraphFallback: true)]
    }

    /// A current subtitle track is shared with the script as a read-only view.
    /// Both snapshots must still describe the current project; this does not
    /// migrate model dialogue or write subtitle text into an analysis.
    static func usableSubtitleTrack(for analysis: ScriptAnalysis, project: FilmProject) -> SubtitleTrack? {
        guard analysis.isCurrent(for: project), let track = project.subtitleTrack,
              track.isCurrent(for: project) else { return nil }
        return matchingSubtitleTrack(track, for: analysis)
    }

    /// Callers with a project use usableSubtitleTrack first. Exports only have
    /// analysis/track snapshots, so also reject an accidentally mismatched track.
    static func matchingSubtitleTrack(_ subtitles: SubtitleTrack?, for analysis: ScriptAnalysis) -> SubtitleTrack? {
        guard let subtitles, analysis.rangeStart.isFinite, analysis.rangeEnd.isFinite,
              analysis.rangeStart >= 0, analysis.rangeEnd > analysis.rangeStart,
              !analysis.sourceClips.isEmpty, subtitles.sourceClips.count == analysis.sourceClips.count,
              analysis.rangeEnd <= analysis.sourceClips.reduce(0, { $0 + $1.duration }),
              zip(subtitles.sourceClips, analysis.sourceClips).allSatisfy({ subtitle, script in
                  subtitle.sourcePath == script.sourcePath && subtitle.sourceDuration == script.sourceDuration &&
                  subtitle.sourceIn == script.sourceIn && subtitle.sourceOut == script.sourceOut &&
                  subtitle.frameRate == script.frameRate && subtitle.width == script.width && subtitle.height == script.height
              }), (try? ProjectPersistence.validateSubtitleTrack(subtitles)) != nil else { return nil }
        return subtitles
    }

    static func displayCues(for segment: ScriptSegment, in analysis: ScriptAnalysis,
                            subtitles: SubtitleTrack? = nil) -> [ScriptReadingCue] {
        guard matchingSubtitleTrack(subtitles, for: analysis) != nil else { return displayCues(for: segment) }
        return cues(in: analysis, subtitles: subtitles).filter { $0.segmentID == segment.id }
    }

    static func cues(in analysis: ScriptAnalysis, subtitles: SubtitleTrack? = nil) -> [ScriptReadingCue] {
        guard let track = matchingSubtitleTrack(subtitles, for: analysis) else {
            return analysis.segments.flatMap { displayCues(for: $0) }
        }
        // Stable ordering gives equal-overlap/equal-distance ties to the earlier
        // narrative segment. Each subtitle is assigned exactly once, even in gaps.
        let segments = analysis.segments.enumerated().filter {
            $0.element.start.isFinite && $0.element.end.isFinite && $0.element.end > $0.element.start
        }.sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        let ordered = zip(segments, segments.dropFirst()).allSatisfy { $0.end <= $1.start }
        return track.cues.compactMap { cue in
            let start = max(analysis.rangeStart, cue.start)
            let end = min(analysis.rangeEnd, cue.end)
            guard end > start else { return nil }
            var owner: ScriptSegment?
            var largestOverlap = -1.0
            var shortestDistance = Double.infinity
            var candidates = segments.startIndex..<segments.endIndex
            if ordered && !segments.isEmpty {
                // Locate the first possibly intersecting segment, then include
                // its immediate neighbours for gap ownership. Avoid scanning an
                // entire long script for every subtitle on every reader update.
                var lower = 0, upper = segments.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if segments[middle].end <= start { lower = middle + 1 } else { upper = middle }
                }
                var last = lower
                while last < segments.count && segments[last].start < end { last += 1 }
                candidates = max(0, lower - 1)..<min(segments.count, max(lower + 1, last))
            }
            for index in candidates {
                let segment = segments[index]
                let overlap = max(0, min(end, segment.end) - max(start, segment.start))
                let distance = max(0, max(segment.start - end, start - segment.end))
                if overlap > largestOverlap || (overlap == largestOverlap && distance < shortestDistance) {
                    owner = segment; largestOverlap = overlap; shortestDistance = distance
                }
            }
            // A malformed legacy analysis with no narrative segments can still
            // expose its real subtitles in the dialogue reader/export.
            return ScriptReadingCue(id: cue.id, segmentID: owner?.id ?? analysis.id,
                                    start: start, end: end, speaker: "",
                                    text: cue.lines(mode: .bilingual).joined(separator: "\n"),
                                    isParagraphFallback: false)
        }
    }

    /// Suppress only whole-value placeholders. Substrings such as “无” or
    /// “待核对” can occur in genuine dialogue and must never act as filters.
    static func hasDialogue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let punctuation = CharacterSet(charactersIn: ".。；;：:")
        let value = trimmed.trimmingCharacters(in: punctuation).lowercased()
        let placeholders: Set<String> = [
            "无", "暂无", "无台词", "无对白", "无对话", "无字幕", "暂无台词", "暂无对白", "无可见字幕",
            "未见字幕", "未提供", "不适用", "未知", "待核对", "待确认", "—", "-", "n/a", "none", "null",
            "待核对：未取得可靠语音转写", "待核对:未取得可靠语音转写",
            "待核对：未取得可靠音频证据", "待核对:未取得可靠音频证据",
            "未取得可靠语音转写", "未取得可靠音频证据"
        ]
        return !placeholders.contains(value)
    }

    static func narrative(for segment: ScriptSegment) -> String {
        if !segment.screenplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return segment.screenplay
        }
        // Old analyses remain readable without requiring another model call.
        // Keep original wording and provenance; do not invent connecting events.
        var seen = Set<String>()
        return [segment.visual, segment.action, segment.camera, segment.sound, segment.transition]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
            .joined(separator: "\n\n")
    }

    static func segment(at time: Double, in analysis: ScriptAnalysis) -> ScriptSegment? {
        guard time.isFinite else { return nil }
        return analysis.segments.first { time >= $0.start && time < $0.end }
            ?? analysis.segments.last.flatMap { time == $0.end ? $0 : nil }
    }

    static func cue(at time: Double, in analysis: ScriptAnalysis, subtitles: SubtitleTrack? = nil) -> ScriptReadingCue? {
        guard time.isFinite else { return nil }
        let items = cues(in: analysis, subtitles: subtitles)
        if matchingSubtitleTrack(subtitles, for: analysis) != nil {
            // Keep the subtitle track's half-open interval contract, including
            // its final endpoint; following a line is separate from active speech.
            return items.first { time >= $0.start && time < $0.end }
        }
        return items.first { time >= $0.start && time < $0.end }
            ?? items.last.flatMap { time == $0.end ? $0 : nil }
    }

    /// A scroll destination, not an active-dialogue indicator. Silent passages
    /// lead into the next line; after the final line the reader stays nearby.
    /// Every comparison uses absolute project time, including legacy paragraphs.
    static func followCue(at time: Double, in analysis: ScriptAnalysis, subtitles: SubtitleTrack? = nil) -> ScriptReadingCue? {
        guard time.isFinite, time >= analysis.rangeStart, time <= analysis.rangeEnd else { return nil }
        let items = cues(in: analysis, subtitles: subtitles)
        return items.first { time >= $0.start && time < $0.end }
            ?? items.first { time < $0.start }
            ?? items.last
    }

    static func range(for cue: ScriptReadingCue) -> ClosedRange<Double> { cue.start...cue.end }
    static func range(for segment: ScriptSegment) -> ClosedRange<Double> { segment.start...segment.end }
}
