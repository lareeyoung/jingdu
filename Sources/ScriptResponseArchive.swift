import Foundation

/// A response is saved before interpretation so parser failures do not require
/// another paid request. Contains response text and media context, never credentials.
struct ScriptResponseRecord: Codable, Identifiable {
    var id = UUID()
    var receivedAt = Date()
    var project: FilmProject
    var rangeStart: Double
    var rangeEnd: Double
    var modelID: String
    var inputMode: String
    var text: String
    var isIncomplete: Bool? = nil

    init(project: FilmProject, rangeStart: Double, rangeEnd: Double, modelID: String, inputMode: String, text: String) {
        self.project = project
        self.project.notes = []; self.project.scriptAnalyses = []
        self.rangeStart = rangeStart; self.rangeEnd = rangeEnd
        self.modelID = modelID; self.inputMode = inputMode; self.text = text
    }

    func parse() throws -> ScriptAnalysis {
        guard isIncomplete != true else { throw ScriptModelError.invalid("模型回复尚未完成，原文可导出查看；不能作为完整脚本保存。") }
        var result = try ScriptAnalysisParser.parse(text, project: project, rangeStart: rangeStart,
            rangeEnd: rangeEnd, modelID: modelID, inputMode: inputMode)
        result.id = id; result.createdAt = receivedAt
        return result
    }
}

struct ScriptResponseArchive {
    static let limit = 20
    let directory: URL

    init(directory: URL? = nil) {
        if let directory { self.directory = directory; return }
        let override = ProcessInfo.processInfo.environment["JINGDU_LIBRARY_DIRECTORY"] ?? ""
        let root = override.hasPrefix("/") && !override.contains("\0")
            ? URL(fileURLWithPath: override, isDirectory: true)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jingdu", isDirectory: true)
        self.directory = root.appendingPathComponent("ScriptResponses", isDirectory: true)
    }

    func load() -> [ScriptResponseRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.compactMap { url -> ScriptResponseRecord? in
            guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
                  let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(ScriptResponseRecord.self, from: data),
                  record.text.utf8.count <= ScriptAnalysisParser.maximumResponseBytes else { return nil }
            return record
        }.sorted { $0.receivedAt > $1.receivedAt }.prefix(Self.limit).map { $0 }
    }

    func save(_ record: ScriptResponseRecord) throws {
        guard record.text.utf8.count <= ScriptAnalysisParser.maximumResponseBytes else { throw ScriptModelError.invalid("回复超过本地保存上限。") }
        let data = try JSONEncoder().encode(record)
        guard data.count <= 8 * 1024 * 1024 else { throw ScriptModelError.invalid("回复及素材信息超过本地保存上限。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
        let retained = Set(load().map { $0.id.uuidString + ".json" })
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil && !retained.contains(url.lastPathComponent) {
            // Leave unreadable or externally added files alone.
            if let data = try? Data(contentsOf: url), (try? JSONDecoder().decode(ScriptResponseRecord.self, from: data)) != nil {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
