//
//  MangaStorage.swift
//  LifeManga
//
//  本地持久化：
//   - 工程列表       → Documents/projects.json
//   - 全部生成历史    → Documents/manga_index.json
//   - 输入/输出图片  → Documents/MangaImages/<uuid>_in_*.png  /  _out_*.png
//

import Foundation
import UIKit
import CoreLocation

actor DiaryWeatherService {
    static let shared = DiaryWeatherService()

    func weatherText(for coordinate: CLLocationCoordinate2D, at date: Date) async -> String? {
        let calendar = Calendar(identifier: .gregorian)
        let dayString = Self.dayFormatter.string(from: date)
        let nowDayString = Self.dayFormatter.string(from: Date())
        let endpoint: URL?

        if dayString == nowDayString {
            endpoint = URL(string:
                "https://api.open-meteo.com/v1/forecast?latitude=\(coordinate.latitude)&longitude=\(coordinate.longitude)&hourly=weather_code&timezone=auto&forecast_days=1"
            )
        } else {
            endpoint = URL(string:
                "https://archive-api.open-meteo.com/v1/archive?latitude=\(coordinate.latitude)&longitude=\(coordinate.longitude)&start_date=\(dayString)&end_date=\(dayString)&hourly=weather_code&timezone=auto"
            )
        }

        guard let endpoint else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: endpoint)
            let decoded = try JSONDecoder().decode(OpenMeteoHourlyResponse.self, from: data)
            guard let hourly = decoded.hourly else { return nil }
            let hour = calendar.component(.hour, from: date)
            if let index = hourly.time.firstIndex(where: { Self.extractHour(from: $0) == hour }) {
                return Self.label(for: hourly.weatherCode[safe: index] ?? -1)
            }
            if let first = hourly.weatherCode.first {
                return Self.label(for: first)
            }
        } catch {
            return nil
        }
        return nil
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func extractHour(from iso: String) -> Int? {
        guard let last = iso.split(separator: "T").last else { return nil }
        return Int(last.prefix(2))
    }

    private static func label(for code: Int) -> String? {
        switch code {
        case 0: return "晴"
        case 1, 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55, 56, 57: return "毛毛雨"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "雨"
        case 71, 73, 75, 77, 85, 86: return "雪"
        case 95, 96, 99: return "雷雨"
        default: return nil
        }
    }
}

private enum DiaryStampRenderer {
    static func apply(to output: Data,
                      stamp: DiaryStamp?,
                      style: MangaStyle,
                      isColor: Bool) -> Data {
        guard let stamp,
              let image = UIImage(data: output) else {
            return output
        }
        guard let rendered = renderedImage(from: image, stamp: stamp, style: style, isColor: isColor),
              let data = rendered.pngData() else {
            return output
        }
        return data
    }

    private static func renderedImage(from image: UIImage,
                                      stamp: DiaryStamp,
                                      style: MangaStyle,
                                      isColor: Bool) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let dateText = stamp.dateText
        let weatherText = stamp.weatherText?.trimmingCharacters(in: .whitespacesAndNewlines)

        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))

            let minEdge = min(image.size.width, image.size.height)
            let outerPadding = max(18, minEdge * 0.028)
            let innerPaddingX = max(14, minEdge * 0.018)
            let innerPaddingY = max(10, minEdge * 0.014)
            let cornerRadius = max(12, minEdge * 0.018)

            let palette = palette(for: style, isColor: isColor)
            let dateFont = UIFont.systemFont(ofSize: max(20, minEdge * 0.034), weight: .semibold)
            let weatherFont = UIFont.systemFont(ofSize: max(15, minEdge * 0.024), weight: .medium)

            let dateAttributes: [NSAttributedString.Key: Any] = [
                .font: dateFont,
                .foregroundColor: palette.textColor
            ]
            let weatherAttributes: [NSAttributedString.Key: Any] = [
                .font: weatherFont,
                .foregroundColor: palette.subtextColor
            ]

            let dateSize = (dateText as NSString).size(withAttributes: dateAttributes)
            let weatherSize = weatherText.map { ($0 as NSString).size(withAttributes: weatherAttributes) } ?? .zero
            let textWidth = max(dateSize.width, weatherSize.width)
            let textHeight = dateSize.height + (weatherText == nil ? 0 : weatherSize.height + innerPaddingY * 0.35)

            let cardRect = CGRect(
                x: outerPadding,
                y: outerPadding,
                width: textWidth + innerPaddingX * 2,
                height: textHeight + innerPaddingY * 2
            )

            let shadowPath = UIBezierPath(roundedRect: cardRect, cornerRadius: cornerRadius)
            UIColor.black.withAlphaComponent(0.12).setFill()
            let shadowRect = cardRect.offsetBy(dx: 0, dy: max(4, minEdge * 0.008))
            UIBezierPath(roundedRect: shadowRect, cornerRadius: cornerRadius).fill()

            palette.fillColor.setFill()
            shadowPath.fill()
            palette.borderColor.setStroke()
            shadowPath.lineWidth = max(1.5, minEdge * 0.0022)
            shadowPath.stroke()

            let accentRect = CGRect(
                x: cardRect.minX,
                y: cardRect.minY,
                width: max(8, minEdge * 0.01),
                height: cardRect.height
            )
            let accentPath = UIBezierPath(
                roundedRect: accentRect,
                byRoundingCorners: [.topLeft, .bottomLeft],
                cornerRadii: CGSize(width: cornerRadius, height: cornerRadius)
            )
            palette.accentColor.setFill()
            accentPath.fill()

            let dateOrigin = CGPoint(
                x: cardRect.minX + innerPaddingX + accentRect.width * 0.35,
                y: cardRect.minY + innerPaddingY
            )
            (dateText as NSString).draw(at: dateOrigin, withAttributes: dateAttributes)

            if let weatherText, !weatherText.isEmpty {
                let weatherOrigin = CGPoint(
                    x: dateOrigin.x,
                    y: dateOrigin.y + dateSize.height + innerPaddingY * 0.2
                )
                (weatherText as NSString).draw(at: weatherOrigin, withAttributes: weatherAttributes)
            }
        }
    }

    private static func palette(for style: MangaStyle, isColor: Bool) -> (
        fillColor: UIColor,
        borderColor: UIColor,
        accentColor: UIColor,
        textColor: UIColor,
        subtextColor: UIColor
    ) {
        if !isColor {
            return (
                fillColor: UIColor(white: 1.0, alpha: 0.92),
                borderColor: UIColor(white: 0.12, alpha: 0.9),
                accentColor: UIColor(white: 0.18, alpha: 0.95),
                textColor: UIColor(white: 0.08, alpha: 1.0),
                subtextColor: UIColor(white: 0.25, alpha: 0.95)
            )
        }

        switch style {
        case .navigationGuide:
            return (
                fillColor: UIColor(red: 0.96, green: 0.99, blue: 0.96, alpha: 0.94),
                borderColor: UIColor(red: 0.17, green: 0.47, blue: 0.41, alpha: 0.95),
                accentColor: UIColor(red: 0.28, green: 0.72, blue: 0.58, alpha: 0.96),
                textColor: UIColor(red: 0.10, green: 0.22, blue: 0.18, alpha: 1.0),
                subtextColor: UIColor(red: 0.22, green: 0.34, blue: 0.28, alpha: 0.96)
            )
        case .shojoRomance:
            return (
                fillColor: UIColor(red: 1.0, green: 0.98, blue: 0.99, alpha: 0.93),
                borderColor: UIColor(red: 0.77, green: 0.65, blue: 0.78, alpha: 0.95),
                accentColor: UIColor(red: 0.95, green: 0.78, blue: 0.86, alpha: 0.95),
                textColor: UIColor(red: 0.36, green: 0.27, blue: 0.36, alpha: 1.0),
                subtextColor: UIColor(red: 0.52, green: 0.41, blue: 0.5, alpha: 0.98)
            )
        case .nostalgicChildhood, .shogakukanKids, .youth4Koma, .chibi4Koma:
            return (
                fillColor: UIColor(red: 0.99, green: 0.96, blue: 0.88, alpha: 0.94),
                borderColor: UIColor(red: 0.55, green: 0.41, blue: 0.21, alpha: 0.95),
                accentColor: UIColor(red: 0.93, green: 0.74, blue: 0.34, alpha: 0.96),
                textColor: UIColor(red: 0.27, green: 0.2, blue: 0.11, alpha: 1.0),
                subtextColor: UIColor(red: 0.42, green: 0.31, blue: 0.16, alpha: 0.95)
            )
        case .darkSeinen, .retroGekiga, .horrorJunjiIto:
            return (
                fillColor: UIColor(white: 1.0, alpha: 0.9),
                borderColor: UIColor(white: 0.08, alpha: 0.95),
                accentColor: UIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 0.98),
                textColor: UIColor(white: 0.05, alpha: 1.0),
                subtextColor: UIColor(white: 0.22, alpha: 0.95)
            )
        default:
            return (
                fillColor: UIColor(white: 1.0, alpha: 0.92),
                borderColor: UIColor(red: 0.16, green: 0.16, blue: 0.2, alpha: 0.92),
                accentColor: UIColor(red: 0.32, green: 0.43, blue: 0.95, alpha: 0.95),
                textColor: UIColor(red: 0.09, green: 0.1, blue: 0.14, alpha: 1.0),
                subtextColor: UIColor(red: 0.24, green: 0.26, blue: 0.34, alpha: 0.95)
            )
        }
    }
}

private struct OpenMeteoHourlyResponse: Decodable {
    struct Hourly: Decodable {
        let time: [String]
        let weatherCode: [Int]

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
        }
    }

    let hourly: Hourly?
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - JobStore：任务管理（运行中 / 完成 / 失败）

enum JobKind: String, Codable {
    case simpleImage     // 普通模式：照片→单张漫画
    case storyScript     // 故事模式 第 1 步：编剧本（可选追踪）
    case storyRender     // 故事模式 第 2 步：分镜作画
    case characterViews  // 角色库：从真人照片生成多视图角色立绘
}

enum JobPhase: Codable, Equatable {
    case running                          // 上传 / OpenAI 处理中（统一标）
    case timeoutUnknown(message: String)  // 客户端超时，OpenAI 可能仍在跑，结果未知
    case done(itemId: UUID)
    case failed(message: String)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isDone:    Bool { if case .done    = self { return true }; return false }
    var isFailed:  Bool { if case .failed  = self { return true }; return false }
    var isTimeoutUnknown: Bool {
        if case .timeoutUnknown = self { return true }; return false
    }
    /// 终态（不会再变化）—— done / failed 算终态，timeoutUnknown 也算终态（不能自动重试）
    var isFinal: Bool { isDone || isFailed || isTimeoutUnknown }
}

struct Job: Identifiable, Codable, Equatable {
    let id: UUID
    /// 漫画任务对应的工程；角色任务为 nil
    let projectId: UUID?
    let projectName: String
    let style: MangaStyle
    let kind: JobKind
    let createdAt: Date
    var finishedAt: Date?
    var phase: JobPhase
    var stageMessage: String
    /// 副标题（比如剧本标题、或角色一句话设定）
    var subtitle: String?
    /// 角色任务专用：关联的角色 id / 名字
    var characterId: UUID?
    var characterName: String?
    /// 角色设定稿专用：使用的艺术风格（用于"重新生成"按钮还原参数）
    var artStyle: CharacterArtStyle?

    // MARK: - 漫画任务"重新生成"所需的输入快照
    // 这些字段都是可选的，老数据没有，不会破坏解码
    /// 输入图保存的文件名列表（位于 Documents/PendingJobInputs/<jobId>/）
    var inputImageFiles: [String]?
    /// "前一张"参考图保存的文件名（可选）
    var previousPageFile: String?
    /// 任务发起时载入的角色 id（重试时再用 CharacterStore 解析回 UIImage）
    var characterIds: [UUID]?
    /// 对每个角色实际选中的参考图快照
    var characterSelections: [CharacterReferenceSelection]?
    /// 用户额外补充描述
    var userPromptText: String?
    /// 气泡文字模式 "chinese" / "japanese" / "english" / "empty" / "none"
    var bubbleMode: String?
    /// 是否彩色
    var wasColorOn: Bool?
    /// 一次生成几张
    var imageCount: Int?
    /// "1024x1536" 等
    var imageSizeStr: String?
    /// "low" / "medium" / "high" 等
    var imageQualityStr: String?
    /// 故事模式渲染时保留剧本快照，便于后台恢复
    var storyScriptSnapshot: MangaStoryScript?
    /// 角色相关任务生成出的视图标签（如"动作合集 2"）
    var outputLabel: String?
    /// VPS 后端任务 id（用于重启后继续轮询）
    var backendTaskId: String?

    // MARK: - 防重复请求 / 计费追踪
    /// 请求指纹（输入图 + prompt + 参数 hash），用于"60秒内同样请求拦截"
    var requestHash: String?
    /// 用户手动「重新生成」的次数（自动重试永远是 0，因为禁止）
    var manualRetryCount: Int = 0
    /// 错误代码（如 "URL_TIMEOUT" / "WALLCLOCK_TIMEOUT" / "HTTP_500" / "SAFETY"）
    var errorCode: String?
    /// 上传完成、OpenAI 开始 GPU 工作的大致时刻（用首字节延迟前的时间）
    var openaiStartedAt: Date?

    /// 给 UI 展示用：角色任务用角色名，其它用工程名
    var displayName: String {
        if let n = characterName, !n.isEmpty { return n }
        return projectName
    }

    /// 是否可以"重新生成"——只允许用户手动按按钮触发（绝不自动）。
    /// 失败 / 超时未知 都允许；done / running 不允许。
    var canRetry: Bool {
        switch phase {
        case .failed, .timeoutUnknown:
            break
        case .done, .running:
            return false
        }
        switch kind {
        case .characterViews:
            return artStyle != nil && characterId != nil
        case .simpleImage:
            return (inputImageFiles?.isEmpty == false)
        default:
            return false
        }
    }

    init(id: UUID = UUID(),
         projectId: UUID? = nil,
         projectName: String = "",
         style: MangaStyle,
         kind: JobKind,
         stageMessage: String = "排队中…",
         subtitle: String? = nil,
         characterId: UUID? = nil,
         characterName: String? = nil,
         artStyle: CharacterArtStyle? = nil,
         inputImageFiles: [String]? = nil,
         previousPageFile: String? = nil,
         characterIds: [UUID]? = nil,
         characterSelections: [CharacterReferenceSelection]? = nil,
         userPromptText: String? = nil,
         bubbleMode: String? = nil,
         wasColorOn: Bool? = nil,
         imageCount: Int? = nil,
         imageSizeStr: String? = nil,
         imageQualityStr: String? = nil,
         storyScriptSnapshot: MangaStoryScript? = nil,
         outputLabel: String? = nil,
         backendTaskId: String? = nil,
         requestHash: String? = nil,
         manualRetryCount: Int = 0) {
        self.id = id
        self.projectId = projectId
        self.projectName = projectName
        self.style = style
        self.kind = kind
        self.createdAt = Date()
        self.phase = .running
        self.stageMessage = stageMessage
        self.subtitle = subtitle
        self.characterId = characterId
        self.characterName = characterName
        self.artStyle = artStyle
        self.inputImageFiles = inputImageFiles
        self.previousPageFile = previousPageFile
        self.characterIds = characterIds
        self.characterSelections = characterSelections
        self.userPromptText = userPromptText
        self.bubbleMode = bubbleMode
        self.wasColorOn = wasColorOn
        self.imageCount = imageCount
        self.imageSizeStr = imageSizeStr
        self.imageQualityStr = imageQualityStr
        self.storyScriptSnapshot = storyScriptSnapshot
        self.outputLabel = outputLabel
        self.backendTaskId = backendTaskId
        self.requestHash = requestHash
        self.manualRetryCount = manualRetryCount
    }
}

@MainActor
final class JobStore: ObservableObject {

    static let shared = JobStore()

    @Published private(set) var jobs: [Job] = []

    /// 任务日志（仅内存，不持久化）—— App 重启会清空
    @Published private(set) var logs: [UUID: [JobLogEntry]] = [:]

    /// 运行中任务的 Swift Task 引用 —— 用于支持取消
    /// 注意：这些不持久化；App 重启后所有任务都被 sweep 成失败
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    private let fileManager = FileManager.default
    private var documents: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    private var indexURL: URL { documents.appendingPathComponent("jobs.json") }
    /// 用于保存"未完成任务的输入图"，给重试用
    private var pendingInputsRoot: URL {
        let dir = documents.appendingPathComponent("PendingJobInputs", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        load()
        // 把"启动前残留为 running"的任务标为失败（因为它们其实早死了）
        sweepStaleRunningJobs()
    }

    // MARK: - 计算属性

    var runningCount: Int { jobs.filter { $0.phase.isRunning }.count }
    var hasAny: Bool { !jobs.isEmpty }

    // MARK: - 增改

    @discardableResult
    func startJob(id: UUID = UUID(),
                  projectId: UUID? = nil,
                  projectName: String = "",
                  style: MangaStyle,
                  kind: JobKind,
                  stageMessage: String = "已开始…",
                  subtitle: String? = nil,
                  characterId: UUID? = nil,
                  characterName: String? = nil,
                  artStyle: CharacterArtStyle? = nil,
                  inputImageFiles: [String]? = nil,
                  previousPageFile: String? = nil,
                  characterIds: [UUID]? = nil,
                  characterSelections: [CharacterReferenceSelection]? = nil,
                  userPromptText: String? = nil,
                  bubbleMode: String? = nil,
                  wasColorOn: Bool? = nil,
                  imageCount: Int? = nil,
                  imageSizeStr: String? = nil,
                  imageQualityStr: String? = nil,
                  storyScriptSnapshot: MangaStoryScript? = nil,
                  outputLabel: String? = nil,
                  backendTaskId: String? = nil,
                  requestHash: String? = nil,
                  manualRetryCount: Int = 0) -> UUID {
        let job = Job(id: id,
                      projectId: projectId,
                      projectName: projectName,
                      style: style,
                      kind: kind,
                      stageMessage: stageMessage,
                      subtitle: subtitle,
                      characterId: characterId,
                      characterName: characterName,
                      artStyle: artStyle,
                      inputImageFiles: inputImageFiles,
                      previousPageFile: previousPageFile,
                      characterIds: characterIds,
                      characterSelections: characterSelections,
                      userPromptText: userPromptText,
                      bubbleMode: bubbleMode,
                      wasColorOn: wasColorOn,
                      imageCount: imageCount,
                      imageSizeStr: imageSizeStr,
                      imageQualityStr: imageQualityStr,
                      storyScriptSnapshot: storyScriptSnapshot,
                      outputLabel: outputLabel,
                      backendTaskId: backendTaskId,
                      requestHash: requestHash,
                      manualRetryCount: manualRetryCount)
        jobs.insert(job, at: 0)
        save()
        return job.id
    }

    // MARK: - 防重复请求

    /// 找出最近 N 秒内同 hash 且仍未完结 / 刚完成的任务（避免重复扣费）
    func recentJob(matchingHash hash: String, withinSeconds: TimeInterval = 60) -> Job? {
        let cutoff = Date().addingTimeInterval(-withinSeconds)
        return jobs.first { j in
            guard j.requestHash == hash else { return false }
            // 仍在跑 → 拦截
            if j.phase.isRunning { return true }
            // 终态但发生时间很近 → 也拦截
            return (j.finishedAt ?? j.createdAt) > cutoff
        }
    }

    // MARK: - 终态转移：超时未知（OpenAI 可能仍在处理 → 不允许自动重试）

    func markTimeoutUnknown(_ jobId: UUID, message: String, errorCode: String? = nil) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].phase = .timeoutUnknown(message: message)
        jobs[i].finishedAt = Date()
        jobs[i].stageMessage = "⏳ 客户端超时（OpenAI 可能仍在生成）"
        jobs[i].errorCode = errorCode
        activeTasks.removeValue(forKey: jobId)
        // 注意：故意不清 PendingJobInputs，让用户能手动重试
        save()
    }

    /// 标记 OpenAI 已经开始处理（从首字节日志触发）
    func markOpenAIStarted(_ jobId: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        if jobs[i].openaiStartedAt == nil {
            jobs[i].openaiStartedAt = Date()
            save()
        }
    }

    // MARK: - 重试用：把任务输入图临时存到磁盘

    /// 给指定 jobId 的目录（需要时自动创建）
    private func pendingDir(_ jobId: UUID) -> URL {
        let dir = pendingInputsRoot.appendingPathComponent(jobId.uuidString, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 把一组输入图 + 可选的"前一张"图保存到 jobId 对应目录。
    /// 返回相对文件名列表，用来塞到 Job 里。
    @discardableResult
    func savePendingInputs(jobId: UUID,
                           inputs: [UIImage],
                           previousPage: UIImage?) -> (inputs: [String], previous: String?) {
        let dir = pendingDir(jobId)
        var inputNames: [String] = []
        for (i, img) in inputs.enumerated() {
            let name = "in_\(i).jpg"
            if let data = img.jpegData(compressionQuality: 0.85) {
                try? data.write(to: dir.appendingPathComponent(name))
                inputNames.append(name)
            }
        }
        var prevName: String? = nil
        if let p = previousPage, let data = p.jpegData(compressionQuality: 0.85) {
            let name = "prev.jpg"
            try? data.write(to: dir.appendingPathComponent(name))
            prevName = name
        }
        return (inputNames, prevName)
    }

    /// 重试时根据 Job 里保存的文件名读回原图
    func loadPendingImage(_ filename: String, jobId: UUID) -> UIImage? {
        let url = pendingDir(jobId).appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 任务彻底用不到了再清掉（done / 用户手动 remove）
    func clearPendingInputs(jobId: UUID) {
        let dir = pendingInputsRoot.appendingPathComponent(jobId.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: dir)
    }

    func updateStage(_ jobId: UUID, _ message: String) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].stageMessage = message
        save()
    }

    func updateSubtitle(_ jobId: UUID, _ subtitle: String) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].subtitle = subtitle
        save()
    }

    func updateBackendTaskId(_ jobId: UUID, _ backendTaskId: String) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].backendTaskId = backendTaskId
        save()
    }

    func complete(_ jobId: UUID, with itemId: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].phase = .done(itemId: itemId)
        jobs[i].finishedAt = Date()
        jobs[i].stageMessage = "已完成"
        activeTasks.removeValue(forKey: jobId)
        // 任务已成功，重试用的临时输入图可以清掉
        clearPendingInputs(jobId: jobId)
        save()
    }

    func fail(_ jobId: UUID, message: String, errorCode: String? = nil) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].phase = .failed(message: message)
        jobs[i].finishedAt = Date()
        jobs[i].stageMessage = "失败"
        jobs[i].errorCode = errorCode
        activeTasks.removeValue(forKey: jobId)
        save()
    }

    /// 注册 Task 引用，让任务可被外部取消
    func attachTask(_ task: Task<Void, Never>, to jobId: UUID) {
        activeTasks[jobId] = task
    }

    // MARK: - 日志

    /// 给某个任务追加一条日志（限制最近 200 条避免无限增长）
    func log(_ jobId: UUID, _ message: String, level: JobLogEntry.Level = .info) {
        var arr = logs[jobId] ?? []
        arr.append(JobLogEntry(level: level, message: message))
        if arr.count > 200 { arr.removeFirst(arr.count - 200) }
        logs[jobId] = arr
    }

    /// 跨 actor 安全调用版本
    nonisolated static func log(_ jobId: UUID?,
                                _ message: String,
                                level: JobLogEntry.Level = .info) {
        guard let id = jobId else { return }
        Task { @MainActor in
            JobStore.shared.log(id, message, level: level)
        }
    }

    func entries(for jobId: UUID) -> [JobLogEntry] {
        logs[jobId] ?? []
    }

    func clearLogs(for jobId: UUID) {
        logs.removeValue(forKey: jobId)
    }

    /// 取消运行中的任务
    func cancel(_ jobId: UUID) {
        activeTasks[jobId]?.cancel()
        activeTasks.removeValue(forKey: jobId)
        // Task 自己 catch 到 cancellation 后会调 fail()，所以这里不用直接改状态
        // 但万一 Task 没及时响应取消，给个兜底
        if let i = jobs.firstIndex(where: { $0.id == jobId && $0.phase.isRunning }) {
            jobs[i].phase = .failed(message: "已取消")
            jobs[i].finishedAt = Date()
            jobs[i].stageMessage = "已取消"
            save()
        }
    }

    // MARK: - 删除

    func remove(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        logs.removeValue(forKey: job.id)
        clearPendingInputs(jobId: job.id)
        save()
    }

    func clearFinished() {
        let toRemove = jobs.filter { $0.phase.isRunning == false }
        for j in toRemove { clearPendingInputs(jobId: j.id) }
        jobs.removeAll { $0.phase.isRunning == false }
        save()
    }

    // MARK: - 启动期清理

    /// App 上次运行时还在 .running，但 App 重启意味着客户端进程已经死了。
    /// 此时**不能**判定 OpenAI 端是否完成 / 仍在跑 / 失败，所以归到 timeoutUnknown，
    /// 让用户自己决定是否手动重试，避免无脑自动重发导致重复扣费。
    private func sweepStaleRunningJobs() {
        var changed = false
        for i in jobs.indices where jobs[i].phase.isRunning {
            if jobs[i].backendTaskId?.isEmpty == false {
                continue
            }
            jobs[i].phase = .timeoutUnknown(
                message: "App 重启时任务还在跑。OpenAI 端可能已生成（图片在后台 dashboard 可查），" +
                         "也可能因为客户端断开被中止。如要再次生成，请确认账户没有重复扣费后手动点「重新生成」。"
            )
            jobs[i].finishedAt = Date()
            jobs[i].stageMessage = "⏳ 客户端中断（结果未知）"
            jobs[i].errorCode = "APP_RESTART"
            changed = true
        }
        if changed { save() }
    }

    // MARK: - 持久化

    private func save() {
        do {
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("⚠️ JobStore save error:", error)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Job].self, from: data) else {
            return
        }
        self.jobs = decoded
    }
}

// MARK: - CharacterStore：角色库

@MainActor
final class CharacterStore: ObservableObject {

    static let shared = CharacterStore()

    @Published private(set) var characters: [Character] = []

    private let fileManager = FileManager.default

    private var documents: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    private var indexURL: URL { documents.appendingPathComponent("characters.json") }
    private var imagesDir: URL {
        let dir = documents.appendingPathComponent("CharacterImages", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() { load() }

    // MARK: 公共方法

    @discardableResult
    func create(name: String,
                bio: String?,
                ageGroup: CharacterAgeGroup,
                gender: CharacterGender,
                sourcePhoto: Data?) -> Character {
        var sourcePhotoName: String? = nil
        let id = UUID()
        if let data = sourcePhoto {
            let n = "\(id.uuidString)_source.png"
            try? data.write(to: imagesDir.appendingPathComponent(n))
            sourcePhotoName = n
        }
        let c = Character(id: id,
                          name: name.isEmpty ? "未命名角色" : name,
                          bio: bio,
                          ageGroup: ageGroup,
                          gender: gender,
                          sourcePhotoName: sourcePhotoName,
                          views: [])
        characters.insert(c, at: 0)
        save()
        return c
    }

    func delete(_ character: Character) {
        // 清掉关联图片
        if let n = character.sourcePhotoName {
            try? fileManager.removeItem(at: imagesDir.appendingPathComponent(n))
        }
        for v in character.views {
            try? fileManager.removeItem(at: imagesDir.appendingPathComponent(v.imageName))
        }
        characters.removeAll { $0.id == character.id }
        save()
    }

    func rename(_ character: Character, name: String) {
        guard let i = characters.firstIndex(where: { $0.id == character.id }) else { return }
        characters[i].name = name
        characters[i].updatedAt = Date()
        save()
    }

    /// 添加（或附加）若干个新视图到角色
    func addViews(to characterId: UUID, views: [(label: String, imageData: Data)]) {
        guard let i = characters.firstIndex(where: { $0.id == characterId }) else { return }
        for v in views {
            let name = "\(UUID().uuidString)_view.png"
            try? v.imageData.write(to: imagesDir.appendingPathComponent(name))
            characters[i].views.append(CharacterView(label: v.label, imageName: name))
        }
        characters[i].updatedAt = Date()
        save()
    }

    func removeView(characterId: UUID, viewId: UUID) {
        guard let i = characters.firstIndex(where: { $0.id == characterId }) else { return }
        if let vi = characters[i].views.firstIndex(where: { $0.id == viewId }) {
            let name = characters[i].views[vi].imageName
            try? fileManager.removeItem(at: imagesDir.appendingPathComponent(name))
            characters[i].views.remove(at: vi)
        }
        characters[i].updatedAt = Date()
        save()
    }

    func image(named name: String) -> UIImage? {
        let url = imagesDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func imageData(named name: String) -> Data? {
        try? Data(contentsOf: imagesDir.appendingPathComponent(name))
    }

    func imageURL(named name: String) -> URL {
        imagesDir.appendingPathComponent(name)
    }

    // MARK: 持久化

    private func save() {
        do {
            let data = try JSONEncoder().encode(characters)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("⚠️ CharacterStore save error:", error)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Character].self, from: data) else {
            return
        }
        self.characters = decoded
    }
}

struct SyncedCharacterLibraryPayload: Encodable {
    struct CharacterRecord: Encodable {
        struct ViewRecord: Encodable {
            var id: UUID
            var label: String
            var imageName: String
            var createdAt: Date
            var uploadName: String
        }

        var id: UUID
        var name: String
        var bio: String?
        var ageGroup: String
        var gender: String
        var sourcePhotoName: String?
        var sourcePhotoUploadName: String?
        var views: [ViewRecord]
        var createdAt: Date
        var updatedAt: Date
    }

    var syncedAt: Date
    var deviceName: String
    var appBundle: String
    var characters: [CharacterRecord]
}

enum CharacterSyncError: LocalizedError {
    case backendNotConfigured
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "还没有配置后台地址或后台 API Key。"
        case .invalidResponse:
            return "服务器返回格式异常。"
        }
    }
}

final class CharacterSyncService {
    static let shared = CharacterSyncService()
    private init() {}

    private static let maxSyncImageBytes = 2_800_000
    private static let maxSyncImageLongSide: CGFloat = 1800

    private struct BackendConfig {
        var baseURL: URL
        var apiKey: String
    }

    private struct SyncUploadFile {
        var uploadName: String
        var fileName: String
        var data: Data
        var mime: String
    }

    private struct PreparedSyncImage {
        var fileName: String
        var data: Data
        var mime: String
    }

    @MainActor
    func syncAllCharacters() async throws -> Int {
        let store = CharacterStore.shared
        let characters = store.characters
        let config = try requireBackendConfig()

        var payloadCharacters: [SyncedCharacterLibraryPayload.CharacterRecord] = []
        var uploadFiles: [SyncUploadFile] = []

        for character in characters {
            let sourceUploadName: String?
            let syncedSourcePhotoName: String?
            if let sourcePhotoName = character.sourcePhotoName,
               let data = store.imageData(named: sourcePhotoName) {
                let prepared = prepareSyncImage(data: data, preferredBaseName: "\(character.id.uuidString)_source")
                let uploadName = "\(character.id.uuidString)__source__\(prepared.fileName)"
                uploadFiles.append(.init(uploadName: uploadName,
                                         fileName: uploadName,
                                         data: prepared.data,
                                         mime: prepared.mime))
                sourceUploadName = uploadName
                syncedSourcePhotoName = prepared.fileName
            } else {
                sourceUploadName = nil
                syncedSourcePhotoName = nil
            }

            let views = character.views.compactMap { view -> SyncedCharacterLibraryPayload.CharacterRecord.ViewRecord? in
                guard let data = store.imageData(named: view.imageName) else { return nil }
                let prepared = prepareSyncImage(data: data, preferredBaseName: "\(view.id.uuidString)_view")
                let uploadName = "\(character.id.uuidString)__view__\(prepared.fileName)"
                uploadFiles.append(.init(uploadName: uploadName,
                                         fileName: uploadName,
                                         data: prepared.data,
                                         mime: prepared.mime))
                return .init(id: view.id,
                             label: view.label,
                             imageName: prepared.fileName,
                             createdAt: view.createdAt,
                             uploadName: uploadName)
            }

            payloadCharacters.append(.init(id: character.id,
                                           name: character.name,
                                           bio: character.bio,
                                           ageGroup: character.ageGroup.rawValue,
                                           gender: character.gender.rawValue,
                                           sourcePhotoName: syncedSourcePhotoName,
                                           sourcePhotoUploadName: sourceUploadName,
                                           views: views,
                                           createdAt: character.createdAt,
                                           updatedAt: character.updatedAt))
        }

        let payload = SyncedCharacterLibraryPayload(syncedAt: Date(),
                                                    deviceName: UIDevice.current.name,
                                                    appBundle: Bundle.main.bundleIdentifier ?? "LifeManga",
                                                    characters: payloadCharacters)
        let metadata = try JSONEncoder().encode(payload)
        let boundary = "Boundary-\(UUID().uuidString)"

        var body = Data()
        func appendField(_ name: String, _ value: Data, fileName: String? = nil, mime: String? = nil) {
            body.appendString("--\(boundary)\r\n")
            if let fileName {
                body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
                body.appendString("Content-Type: \(mime ?? "application/octet-stream")\r\n\r\n")
                body.append(value)
                body.appendString("\r\n")
            } else {
                body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                body.append(value)
                body.appendString("\r\n")
            }
        }

        appendField("metadata", metadata)
        for file in uploadFiles {
            appendField("files", file.data, fileName: file.fileName, mime: file.mime)
        }
        body.appendString("--\(boundary)--\r\n")

        var request = try makeBackendRequest(config: config, path: "/api/library/characters/sync")
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 240

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CharacterSyncError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CharacterSync", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: text
            ])
        }

        struct SyncResponse: Decodable { let syncedCharacterCount: Int? }
        let decoded = try? JSONDecoder().decode(SyncResponse.self, from: data)
        return decoded?.syncedCharacterCount ?? characters.count
    }

    private func prepareSyncImage(data: Data, preferredBaseName: String) -> PreparedSyncImage {
        let safeBaseName = sanitizedFileBaseName(preferredBaseName)
        guard let source = UIImage(data: data) else {
            return .init(fileName: "\(safeBaseName).bin",
                         data: data,
                         mime: "application/octet-stream")
        }

        var targetLongSide = Self.maxSyncImageLongSide
        var image = renderedForSync(source, maxLongSide: targetLongSide)
        var quality: CGFloat = 0.86
        var output = image.jpegData(compressionQuality: quality) ?? data

        while output.count > Self.maxSyncImageBytes && quality > 0.58 {
            quality -= 0.08
            output = image.jpegData(compressionQuality: quality) ?? output
        }

        while output.count > Self.maxSyncImageBytes && targetLongSide > 900 {
            targetLongSide *= 0.82
            image = renderedForSync(source, maxLongSide: targetLongSide)
            quality = 0.76
            output = image.jpegData(compressionQuality: quality) ?? output
        }

        return .init(fileName: "\(safeBaseName).jpg",
                     data: output,
                     mime: "image/jpeg")
    }

    private func renderedForSync(_ image: UIImage, maxLongSide: CGFloat) -> UIImage {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return image }

        let longSide = max(originalSize.width, originalSize.height)
        let scale = min(1, maxLongSide / longSide)
        let targetSize = CGSize(width: max(CGFloat(1), originalSize.width * scale),
                                height: max(CGFloat(1), originalSize.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func sanitizedFileBaseName(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "[^A-Za-z0-9_-]",
                                                 with: "_",
                                                 options: .regularExpression)
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }

    private func requireBackendConfig() throws -> BackendConfig {
        let rawURL = UserDefaults.standard.string(forKey: AppSettings.backendBaseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (rawURL?.isEmpty == false ? rawURL! : "https://manga.areu.pro")
        guard let key = KeychainService.shared.loadBackendAPIKey(),
              !key.isEmpty,
              let url = URL(string: base) else {
            throw CharacterSyncError.backendNotConfigured
        }
        return BackendConfig(baseURL: url, apiKey: key)
    }

    private func makeBackendRequest(config: BackendConfig, path: String) throws -> URLRequest {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = config.baseURL.appending(path: cleanPath)
        var request = URLRequest(url: url)
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        return request
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        append(data)
    }
}

// MARK: - ProjectStore

@MainActor
final class ProjectStore: ObservableObject {

    static let shared = ProjectStore()

    @Published private(set) var projects: [MangaProject] = []

    private let fileManager = FileManager.default
    private var documents: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    private var indexURL: URL { documents.appendingPathComponent("projects.json") }

    private init() {
        load()
        // 启动期迁移：把没有工程的旧数据归到"原有作品"工程
        MangaStorage.shared.migrateOrphansIfNeeded(into: ensureDefaultProject())
    }

    // MARK: - 增删改

    @discardableResult
    func create(name: String, mode: ProjectMode = .comicLife) -> MangaProject {
        let p = MangaProject(name: name.isEmpty ? "未命名工程" : name, mode: mode)
        projects.insert(p, at: 0)
        save()
        return p
    }

    func rename(_ project: MangaProject, to newName: String) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx].name = newName.isEmpty ? "未命名工程" : newName
        projects[idx].updatedAt = Date()
        save()
    }

    func delete(_ project: MangaProject) {
        // 删除工程下的所有作品
        let items = MangaStorage.shared.items(in: project.id)
        for it in items { MangaStorage.shared.delete(it) }
        projects.removeAll { $0.id == project.id }
        save()
    }

    func touch(_ projectId: UUID, coverItemId: UUID? = nil) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].updatedAt = Date()
        if let cover = coverItemId {
            projects[idx].coverItemId = cover
        }
        save()
    }

    // MARK: - 默认工程（用于迁移和"用户没建工程就来到首页"的兜底）

    @discardableResult
    func ensureDefaultProject() -> MangaProject {
        if let existing = projects.first(where: { $0.name == "原有作品" }) {
            return existing
        }
        // 仅当根本没有任何工程时，才需要兜底
        if projects.isEmpty {
            return create(name: "我的第一个漫画")
        }
        // 否则，如果有任何 orphan 数据，建一个"原有作品"
        let hasOrphans = MangaStorage.shared.items(in: MangaItem.orphanProjectId).isEmpty == false
        if hasOrphans {
            let p = MangaProject(name: "原有作品")
            projects.append(p)
            save()
            return p
        }
        return projects[0]
    }

    // MARK: - 持久化

    private func save() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("⚠️ ProjectStore save error:", error)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MangaProject].self, from: data) else {
            return
        }
        self.projects = decoded
    }
}

// MARK: - MangaStorage（已升级为按工程过滤）

@MainActor
final class MangaStorage: ObservableObject {

    static let shared = MangaStorage()

    @Published private(set) var allItems: [MangaItem] = []

    private let fileManager = FileManager.default
    private init() { load() }

    private var documents: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    private var indexURL: URL { documents.appendingPathComponent("manga_index.json") }
    private var imagesDir: URL {
        let dir = documents.appendingPathComponent("MangaImages", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - 查询

    /// 当前工程下所有作品（按时间倒序）
    func items(in projectId: UUID) -> [MangaItem] {
        allItems.filter { $0.projectId == projectId }
    }

    func image(named name: String) -> UIImage? {
        let url = imagesDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func imageURL(named name: String) -> URL {
        imagesDir.appendingPathComponent(name)
    }

    // MARK: - 增删改

    @discardableResult
    func add(projectId: UUID,
             style: MangaStyle,
             inputs: [Data],
             outputs: [Data],
             userPrompt: String?,
             storyScript: MangaStoryScript? = nil,
             previousPage: Data? = nil,
             loadedCharacterIds: [UUID]? = nil,
             loadedCharacterSelections: [CharacterReferenceSelection]? = nil,
             bubbleTextMode: String? = nil,
             isColorOutput: Bool? = nil,
             imageCount: Int? = nil,
             imageSize: String? = nil,
             imageQuality: String? = nil,
             diaryStamp: DiaryStamp? = nil,
             applyDiaryOverlay: Bool? = nil) -> MangaItem {

        let id = UUID()
        var inputNames: [String] = []
        var outputNames: [String] = []
        var previousPageName: String? = nil
        let shouldApplyDiaryOverlay = applyDiaryOverlay
            ?? UserDefaults.standard.object(forKey: AppSettings.diaryOverlayAssistKey) as? Bool
            ?? true
        let finalOutputs = outputs.map {
            shouldApplyDiaryOverlay
            ? DiaryStampRenderer.apply(
                to: $0,
                stamp: diaryStamp,
                style: style,
                isColor: isColorOutput ?? true
            )
            : $0
        }

        for (i, d) in inputs.enumerated() {
            let name = "\(id.uuidString)_in_\(i).png"
            try? d.write(to: imagesDir.appendingPathComponent(name))
            inputNames.append(name)
        }
        for (i, d) in finalOutputs.enumerated() {
            let name = "\(id.uuidString)_out_\(i).png"
            try? d.write(to: imagesDir.appendingPathComponent(name))
            outputNames.append(name)
        }
        if let previousPage {
            let name = "\(id.uuidString)_prev.png"
            try? previousPage.write(to: imagesDir.appendingPathComponent(name))
            previousPageName = name
        }

        let item = MangaItem(id: id,
                             projectId: projectId,
                             createdAt: Date(),
                             style: style,
                             inputImageNames: inputNames,
                             outputImageNames: outputNames,
                             userPrompt: userPrompt,
                             storyScript: storyScript,
                             isFavorite: false,
                             previousPageImageName: previousPageName,
                             loadedCharacterIds: loadedCharacterIds,
                             loadedCharacterSelections: loadedCharacterSelections,
                             bubbleTextMode: bubbleTextMode,
                             isColorOutput: isColorOutput,
                             imageCount: imageCount,
                             imageSize: imageSize,
                             imageQuality: imageQuality,
                             diaryStamp: diaryStamp)
        allItems.insert(item, at: 0)
        save()
        // 同时刷新工程的 updatedAt 和封面（首张作品自动作为封面）
        ProjectStore.shared.touch(projectId, coverItemId: item.id)
        return item
    }

    func toggleFavorite(_ item: MangaItem) {
        guard let idx = allItems.firstIndex(where: { $0.id == item.id }) else { return }
        allItems[idx].isFavorite.toggle()
        save()
    }

    func applyFeedback(_ item: MangaItem, state: MangaFeedbackState, tags: [MangaFeedbackTag]) {
        guard let idx = allItems.firstIndex(where: { $0.id == item.id }) else { return }
        allItems[idx].feedbackState = state
        allItems[idx].feedbackTags = tags.filter { $0.sentiment == state }
        if state == .liked {
            allItems[idx].isFavorite = true
        }
        save()
    }

    func clearFeedback(_ item: MangaItem) {
        guard let idx = allItems.firstIndex(where: { $0.id == item.id }) else { return }
        allItems[idx].feedbackState = nil
        allItems[idx].feedbackTags = []
        save()
    }

    func refreshedItem(id: UUID) -> MangaItem? {
        allItems.first { $0.id == id }
    }

    func tasteMemoryPrompt(for style: MangaStyle, extraDislikes: [MangaFeedbackTag] = []) -> String? {
        let feedbackItems = allItems.filter { $0.feedbackState != nil }
        let styleScoped = feedbackItems.filter { $0.style == style }
        let pool = styleScoped.count >= 2 ? styleScoped : feedbackItems
        let liked = topTags(in: pool, state: .liked, limit: 4)
        let disliked = topTags(in: pool, state: .disliked, limit: 4)
        let mergedDislikes = uniqueTags(disliked + extraDislikes.filter { $0.sentiment == .disliked })

        guard !liked.isEmpty || !mergedDislikes.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("USER PREFERENCE MEMORY:")
        if !liked.isEmpty {
            let text = liked.map(\.promptCue).joined(separator: "; ")
            lines.append("The user often responds well to: \(text).")
        }
        if !mergedDislikes.isEmpty {
            let text = mergedDislikes.map(\.promptCue).joined(separator: "; ")
            lines.append("Avoid these common dissatisfaction points: \(text).")
        }
        lines.append("When uncertain, prioritize clear storytelling, stable faces, and polished composition over flashy but messy choices.")
        return lines.joined(separator: "\n")
    }

    func delete(_ item: MangaItem) {
        guard let idx = allItems.firstIndex(where: { $0.id == item.id }) else { return }
        let previous = allItems[idx].previousPageImageName.map { [$0] } ?? []
        for n in allItems[idx].inputImageNames + allItems[idx].outputImageNames + previous {
            try? fileManager.removeItem(at: imagesDir.appendingPathComponent(n))
        }
        allItems.remove(at: idx)
        save()
    }

    // MARK: - 旧数据迁移

    /// 把没有 projectId 的旧记录绑定到指定工程
    func migrateOrphansIfNeeded(into project: MangaProject) {
        var changed = false
        for i in allItems.indices where allItems[i].projectId == MangaItem.orphanProjectId {
            allItems[i].projectId = project.id
            changed = true
        }
        if changed { save() }
    }

    // MARK: - 持久化

    private func save() {
        do {
            let data = try JSONEncoder().encode(allItems)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("⚠️ MangaStorage save error:", error)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MangaItem].self, from: data) else {
            return
        }
        self.allItems = decoded
    }

    private func topTags(in items: [MangaItem],
                         state: MangaFeedbackState,
                         limit: Int) -> [MangaFeedbackTag] {
        let tags = items
            .filter { $0.feedbackState == state }
            .flatMap(\.feedbackTags)
            .filter { $0.sentiment == state }

        guard !tags.isEmpty else { return [] }

        let counts = Dictionary(tags.map { ($0, 1) }, uniquingKeysWith: +)
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key.rawValue < rhs.key.rawValue
                }
                return lhs.value > rhs.value
            }
            .prefix(limit)
            .map(\.key)
    }

    private func uniqueTags(_ tags: [MangaFeedbackTag]) -> [MangaFeedbackTag] {
        var seen: Set<MangaFeedbackTag> = []
        return tags.filter { seen.insert($0).inserted }
    }
}
