import Foundation

/// Transport-independent JSON contract. The service must return one object with
/// title/synopsis/structure/segments/caveats. Segment start/end are relative seconds
/// from the submitted video's beginning, as are optional dialogue-cue times.
/// Local IDs, dates, source snapshots and linked note IDs never come from the model.
enum ScriptAnalysisParser {
    static let maximumResponseBytes = 4 * 1024 * 1024

    static func parse(_ data: Data, project: FilmProject, rangeStart: Double, rangeEnd: Double,
                      modelID: String, inputMode: String) throws -> ScriptAnalysis {
        guard data.count <= maximumResponseBytes, let text = String(data: data, encoding: .utf8) else {
            throw ScriptModelError.invalid("响应必须是 UTF-8 文本，且不能超过 4 MB。")
        }
        return try parse(text, project: project, rangeStart: rangeStart, rangeEnd: rangeEnd,
                         modelID: modelID, inputMode: inputMode)
    }

    static func parse(_ text: String, project: FilmProject, rangeStart: Double, rangeEnd: Double,
                      modelID: String, inputMode: String) throws -> ScriptAnalysis {
        guard text.utf8.count <= maximumResponseBytes else { throw ScriptModelError.invalid("响应超过 4 MB，请缩小分析范围。") }
        guard rangeStart.isFinite, rangeEnd.isFinite, rangeStart >= 0,
              rangeEnd > rangeStart, rangeEnd <= project.duration else {
            throw ScriptModelError.invalid("提交的分析范围必须在项目时间轴内，且终点大于起点。")
        }
        let json = try unwrap(text)
        guard let data = json.data(using: .utf8) else { throw ScriptModelError.invalid("响应不是有效的 UTF-8 文本。") }
        let payload: ScriptPayload
        do { payload = try JSONDecoder().decode(ScriptPayload.self, from: data) }
        catch let error as ScriptModelError { throw error }
        catch { throw ScriptModelError.invalid(decodingMessage(error)) }
        // Decoders commonly accept duplicated JSON keys and silently pick a value.
        // Reject them so ambiguous start/end values can never choose the timing.
        try rejectDuplicateKeys(data)
        let length = rangeEnd - rangeStart
        var previousEnd = 0.0
        var alignedDecimalEndpoint = false
        let segments = try payload.segments.enumerated().map { index, item -> ScriptSegment in
            guard item.start.isFinite, item.end.isFinite, item.start >= 0,
                  item.end > item.start, item.start >= previousEnd,
                  let normalizedEnd = normalizeEndpoint(item.end, maximum: length),
                  normalizedEnd.time > item.start else {
                throw ScriptModelError.invalid("第 \(index + 1) 段时间无效：实际 start=\(item.start)，end=\(item.end)，上一段 end=\(previousEnd)；须满足 0 ≤ start < end ≤ \(length)，按时间排列且不重叠。不修正起点、乱序或重叠。")
            }
            alignedDecimalEndpoint = alignedDecimalEndpoint || normalizedEnd.decimalRounded
            let end = min(rangeEnd, rangeStart + normalizedEnd.time)
            let start = min(rangeEnd, rangeStart + item.start)
            guard end > start else { throw ScriptModelError.invalid("第 \(index + 1) 段在分析范围内没有有效长度：实际 start=\(item.start)，end=\(item.end)，上一段 end=\(previousEnd)，选段终点=\(length)。") }
            var previousCueEnd = item.start
            let cues = try item.dialogueCues.enumerated().map { cueIndex, cue -> ScriptDialogueCue in
                guard cue.start.isFinite, cue.end.isFinite, cue.start >= item.start,
                      cue.end > cue.start, cue.end <= item.end + 0.000_000_1,
                      cue.start >= previousCueEnd,
                      let normalizedCueEnd = normalizeEndpoint(cue.end, maximum: normalizedEnd.time),
                      normalizedCueEnd.time > cue.start else {
                    throw ScriptModelError.invalid("第 \(index + 1) 段第 \(cueIndex + 1) 句台词时间无效：实际 start=\(cue.start)，end=\(cue.end)，上一句 end=\(previousCueEnd)；原始段落范围=\(item.start)–\(item.end)，归一后范围=\(item.start)–\(normalizedEnd.time)。台词须使用视频起点的相对秒数，位于本段内，按时间排列且不重叠。")
                }
                let cueStart = min(end, rangeStart + cue.start)
                let cueEnd = min(end, rangeStart + normalizedCueEnd.time)
                guard cueEnd > cueStart else { throw ScriptModelError.invalid("第 \(index + 1) 段第 \(cueIndex + 1) 句台词在对应段落内没有有效长度：实际 start=\(cue.start)，end=\(cue.end)，上一句 end=\(previousCueEnd)，归一后段落终点=\(normalizedEnd.time)。") }
                alignedDecimalEndpoint = alignedDecimalEndpoint || normalizedCueEnd.decimalRounded
                previousCueEnd = cue.end
                return ScriptDialogueCue(start: cueStart, end: cueEnd, speaker: cue.speaker, text: cue.text)
            }
            previousEnd = item.end
            return ScriptSegment(start: start, end: end, visual: item.visual, action: item.action,
                                 dialogue: item.dialogue, sound: item.sound, camera: item.camera,
                                 transition: item.transition, reasoning: item.reasoning, uncertainty: item.uncertainty,
                                 screenplay: item.screenplay, dialogueCues: cues)
        }
        let endpointNotice = "片尾小数时间已对齐实际选段终点"
        let caveats = alignedDecimalEndpoint
            ? [payload.caveats, endpointNotice].filter { !$0.isEmpty }.joined(separator: "\n")
            : payload.caveats
        let analysis = ScriptAnalysis(modelID: modelID, sourceClips: project.videoClips,
                                      rangeStart: rangeStart, rangeEnd: rangeEnd, title: payload.title,
                                      synopsis: payload.synopsis, structure: payload.structure,
                                      segments: segments, caveats: caveats, inputMode: inputMode,
                                      sourceMusic: project.music, originalVolume: project.originalVolume)
        try ProjectPersistence.validateScriptAnalysis(analysis)
        return analysis
    }

    /// Preserve every in-range endpoint. An overshoot is accepted only when it
    /// is the known bound rounded to 2/3/4 decimals (at most 10 ms), or falls in
    /// the existing sub-microsecond binary-arithmetic tolerance. This does not
    /// normalize starts, reorder items, repair overlaps, or round internal cuts.
    private static func normalizeEndpoint(_ value: Double, maximum: Double) -> (time: Double, decimalRounded: Bool)? {
        guard value.isFinite, maximum.isFinite else { return nil }
        if value <= maximum { return (value, false) }
        let overshoot = value - maximum
        if overshoot <= 0.000_000_1 { return (maximum, false) }
        guard overshoot <= 0.01 else { return nil }
        for scale in [100.0, 1_000.0, 10_000.0] {
            let roundedBound = (maximum * scale).rounded() / scale
            let binaryTolerance = max(value.ulp, roundedBound.ulp) * 2
            if roundedBound > maximum, abs(value - roundedBound) <= binaryTolerance {
                return (maximum, true)
            }
        }
        return nil
    }

    private static func unwrap(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScriptModelError.invalid("模型返回了空内容。") }
        guard trimmed.hasPrefix("```") else { return trimmed }
        let lines = trimmed.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.count >= 3,
              ["```", "```json"].contains(lines[0].trimmingCharacters(in: .whitespaces).lowercased()),
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
            throw ScriptModelError.invalid("只接受一个完整的 JSON 代码围栏，围栏外不能夹带说明文字。")
        }
        return lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodingMessage(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            let path = (context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
            return "缺少必需字段“\(path)”。时间必须由模型明确给出，其余文字字段未知时可为空。"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "字段“\(path)”类型不正确。start/end 必须是数值秒，描述字段必须是字符串，不能用 null 或时间码代替。"
        case DecodingError.dataCorrupted:
            return "内容不是完整有效的 JSON，或包含无法表示的数值。请让模型只返回约定结构。"
        default: return error.localizedDescription
        }
    }

    private static func rejectDuplicateKeys(_ data: Data) throws {
        struct Frame { var isObject: Bool; var expectsKey = true; var keys: Set<String> = [] }
        let bytes = [UInt8](data)
        var stack: [Frame] = []
        var index = 0
        // Syntax was already decoded successfully, so this scan only tracks
        // containers and fully escaped string tokens, never interpreting values.
        while index < bytes.count {
            switch bytes[index] {
            case 123: stack.append(Frame(isObject: true)) // {
            case 91: stack.append(Frame(isObject: false)) // [
            case 125, 93: if !stack.isEmpty { stack.removeLast() }
            case 58: if !stack.isEmpty { stack[stack.count - 1].expectsKey = false }
            case 44: if !stack.isEmpty, stack[stack.count - 1].isObject { stack[stack.count - 1].expectsKey = true }
            case 34:
                let begin = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }
                    index += 1
                }
                if let frame = stack.last, frame.isObject && frame.expectsKey {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[begin...index]))
                    guard !frame.keys.contains(key) else { throw ScriptModelError.invalid("JSON 字段“\(key)”重复，无法确定应使用哪个值。") }
                    stack[stack.count - 1].keys.insert(key)
                }
            default: break
            }
            index += 1
        }
    }
}

enum ScriptModelError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return "脚本结果无法读取：\(reason)" }
    }
}

private struct ScriptPayload: Decodable {
    let title: String
    let synopsis: String
    let structure: String
    let segments: [ScriptSegmentPayload]
    let caveats: String
    private enum CodingKeys: String, CodingKey { case title, synopsis, structure, segments, caveats }
    init(from decoder: Decoder) throws {
        try rejectUnknownFields(decoder, allowing: ["title", "synopsis", "structure", "segments", "caveats", "timelineNoteIDs"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        synopsis = try c.decode(String.self, forKey: .synopsis)
        structure = try c.decode(String.self, forKey: .structure)
        segments = try c.decode([ScriptSegmentPayload].self, forKey: .segments)
        caveats = try c.decode(String.self, forKey: .caveats)
    }
}

private struct ScriptSegmentPayload: Decodable {
    let start: Double
    let end: Double
    let visual: String
    let action: String
    let dialogue: String
    let sound: String
    let camera: String
    let transition: String
    let reasoning: String
    let uncertainty: String
    let screenplay: String
    let dialogueCues: [ScriptDialogueCuePayload]
    private enum CodingKeys: String, CodingKey { case start, end, visual, action, dialogue, sound, camera, transition, reasoning, uncertainty, screenplay, dialogueCues }
    init(from decoder: Decoder) throws {
        try rejectUnknownFields(decoder, allowing: ["start", "end", "visual", "action", "dialogue", "sound", "camera", "transition", "reasoning", "uncertainty", "screenplay", "dialogueCues"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
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
        // Missing fields are compatible with old responses; explicit null or a
        // wrong type still indicates a broken response contract.
        screenplay = c.contains(.screenplay) ? try c.decode(String.self, forKey: .screenplay) : ""
        dialogueCues = c.contains(.dialogueCues) ? try c.decode([ScriptDialogueCuePayload].self, forKey: .dialogueCues) : []
    }
}

private struct ScriptDialogueCuePayload: Decodable {
    let start: Double
    let end: Double
    let speaker: String
    let text: String
    private enum CodingKeys: String, CodingKey { case start, end, speaker, text }
    init(from decoder: Decoder) throws {
        try rejectUnknownFields(decoder, allowing: ["start", "end", "speaker", "text"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        speaker = try c.decode(String.self, forKey: .speaker)
        text = try c.decode(String.self, forKey: .text)
    }
}

private struct ScriptJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownFields(_ decoder: Decoder, allowing fields: Set<String>) throws {
    let c = try decoder.container(keyedBy: ScriptJSONKey.self)
    if let unknown = c.allKeys.map(\.stringValue).filter({ !fields.contains($0) }).sorted().first {
        throw ScriptModelError.invalid("出现未约定字段“\(unknown)”，请使用脚本分析 JSON 结构。")
    }
}

extension ScriptAnalysis {
    func exportMarkdown(frameRate: Double? = nil, subtitles: SubtitleTrack? = nil) -> String {
        let rate = frameRate ?? sourceClips.first?.frameRate ?? 30
        let shared = ScriptReading.matchingSubtitleTrack(subtitles, for: self)
        let dialogue = ScriptReading.cues(in: self, subtitles: shared)
        let groupedDialogue = Dictionary(grouping: dialogue, by: \.segmentID)
        let dialogueNotice = shared.map { subtitleDialogueSource($0) }
            ?? "台词 / 字幕为模型转写，待核对；逐句时间为估计，旧记录标为段落定位。未取得可靠音频证据时，不能由画面推断原声。"
        var lines = [
            "# \(scriptHeading(title)) · 视频脚本", "",
            "- 分析范围：\(timecode(rangeStart, frameRate: rate))–\(timecode(rangeEnd, frameRate: rate))（项目绝对时间）",
            "- 模型：\(scriptHeading(modelID)) · 输入方式：\(scriptHeading(inputMode))",
            "- 生成时间：\(ISO8601DateFormatter().string(from: createdAt))",
            "- 原声音量：\(String(format: "%.0f", originalVolume * 100))% · 配乐素材：\(sourceMusic.count) 个", "",
            dialogueNotice + "设计解释属于推测，不代表原作者实际意图。", "",
            "## 故事梗概", "", synopsis, "",
            "## 完整脚本", ""
        ]
        for (index, segment) in segments.enumerated() {
            lines += ["### \(index + 1) · \(timecode(segment.start, frameRate: rate))–\(timecode(segment.end, frameRate: rate))", "",
                      ScriptReading.narrative(for: segment), ""]
            for cue in groupedDialogue[segment.id] ?? [] {
                lines += scriptDialogueLines(cue, rate: rate)
            }
            // New prose is the primary reading experience. Preserve every
            // original observation as a supplemental record for review/export.
            if !segment.screenplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let observations = [("画面（模型观察）", segment.visual), ("动作", segment.action),
                                    ("镜头", segment.camera), ("声音", segment.sound), ("转场", segment.transition)]
                for (label, value) in observations where !value.isEmpty {
                    lines += ["**\(label)**", "", value, ""]
                }
            }
            if shared == nil && !segment.dialogueCues.isEmpty && !segment.dialogue.isEmpty {
                lines += ["**原始模型台词记录（不随人工修订更新）**", "", segment.dialogue, ""]
            } else if shared == nil && ScriptReading.displayCues(for: segment).isEmpty && !segment.dialogue.isEmpty {
                lines += ["**台词状态**", "", segment.dialogue, ""]
            }
            if !segment.reasoning.isEmpty { lines += ["**设计解释（推测）**", "", segment.reasoning, ""] }
            if !segment.uncertainty.isEmpty { lines += ["**不确定性**", "", segment.uncertainty, ""] }
        }
        let segmentIDs = Set(segments.map(\.id))
        let unassigned = dialogue.filter { !segmentIDs.contains($0.segmentID) }
        if !unassigned.isEmpty {
            lines += ["### 台词 / 字幕", ""]
            for cue in unassigned { lines += scriptDialogueLines(cue, rate: rate) }
        }
        lines += ["## 结构分析（解释）", "", structure, "",
                  "## 限制与待确认", "", caveats.isEmpty ? "未单独列出；仍需对照原视频核对模型输出。" : caveats,
                  "", "## 分析时的素材快照", ""]
        for (index, clip) in sourceClips.enumerated() {
            lines.append("- \(index + 1). \(scriptHeading(clip.title)) · 源区间 \(timecode(clip.sourceIn, frameRate: clip.frameRate))–\(timecode(clip.sourceOut, frameRate: clip.frameRate)) · \(scriptHeading(clip.sourcePath))")
        }
        for clip in sourceMusic {
            lines.append("- 音乐：\(scriptHeading(clip.title)) · 从项目 \(timecode(clip.timelineStart, frameRate: rate)) 开始 · 源区间 \(String(format: "%.3f", clip.sourceIn))–\(String(format: "%.3f", clip.sourceOut)) 秒 · 音量 \(String(format: "%.0f", clip.volume * 100))% · \(scriptHeading(clip.sourcePath))")
        }
        lines += ["", "此记录保留生成时的素材与声音设置；后来修改剪辑或配乐后，应重新分析再用于当前版本。", ""]
        return lines.joined(separator: "\n")
    }

    func exportDialogueMarkdown(frameRate: Double? = nil, subtitles: SubtitleTrack? = nil) -> String {
        let rate = frameRate ?? sourceClips.first?.frameRate ?? 30
        let shared = ScriptReading.matchingSubtitleTrack(subtitles, for: self)
        let notice = shared.map { subtitleDialogueSource($0) }
            ?? "台词取自脚本记录；逐句时间为估计，标为“段落定位”的旧记录只对应整段画面。请回看原片核对。"
        var lines = ["# \(scriptHeading(title)) · 台词摘录", "",
                     "分析范围：\(timecode(rangeStart, frameRate: rate))–\(timecode(rangeEnd, frameRate: rate))（项目绝对时间）", "",
                     notice, ""]
        let cues = ScriptReading.cues(in: self, subtitles: shared)
        if cues.isEmpty { lines += ["本脚本没有可提取的台词 / 字幕。", ""] }
        for cue in cues { lines += scriptDialogueLines(cue, rate: rate) }
        return lines.joined(separator: "\n")
    }
}

private func subtitleDialogueSource(_ track: SubtitleTrack) -> String {
    "台词来源：当前素材的字幕轨。外语原文与中文译文分行，中文字幕只保留原文；字幕时间为语音识别估计，请回看原片核对。来源记录：\(scriptHeading(track.sourceDescription))。叙事与分析仍保留生成时的记录。"
}

private func scriptDialogueLines(_ cue: ScriptReadingCue, rate: Double) -> [String] {
    let position = cue.isParagraphFallback ? " · 段落定位" : " · 逐句定位（估计）"
    let speaker = cue.speaker.isEmpty ? "台词 / 字幕" : scriptHeading(cue.speaker)
    let quote = ScriptReading.dialogueLines(cue.text)
        .map { "> " + $0 }.joined(separator: "  \n")
    return ["**\(speaker)** · \(timecode(cue.start, frameRate: rate))–\(timecode(cue.end, frameRate: rate))\(position)", "", quote, ""]
}

private func scriptHeading(_ text: String) -> String {
    text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
}
