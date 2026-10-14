//
//  OpenAIService.swift
//  LifeManga
//
//  封装 OpenAI 图像 + 文本接口：
//
//  【普通模式】 generateManga()
//      - 直接调 `/v1/images/edits` (gpt-image-2)，把照片 + 风格 prompt 给模型
//
//  【故事模式】 generateStory()
//      第一步：调 `/v1/chat/completions` (gpt-5.4-mini)，让 vision 模型读图编剧本
//      第二步：把剧本作为详细 prompt 再调 `/v1/images/edits` 渲染多格漫画页
//

import Foundation
import UIKit
import UserNotifications

// MARK: - 背景 URLSession 调度器
//
// 用 URLSessionConfiguration.background 把网络请求交给 iOS 系统层。
// 锁屏 / 切应用 / 暂停时系统都会继续传输；响应回来后主动唤醒 App 投递事件。
// 关键设计：
//   - 单例持有一个 background 配置的 URLSession
//   - 每次请求 multipart 都先写到临时文件，再用 uploadTask 提交
//   - URLSessionDataDelegate 累计响应数据，task 完成时 resume continuation

final class BackgroundTaskRunner: NSObject, URLSessionDataDelegate {

    static let shared = BackgroundTaskRunner()

    // 改了 timeout 之后变更 identifier，让系统拿全新的 URLSession（避免 iOS 复用旧 cfg）
    static let sessionIdentifier = "com.lifemanga.background-urlsession.v2"

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.allowsCellularAccess = true
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        // gpt-image-2 + 多张参考图实际生成耗时 150~300s，且这段时间 OpenAI 不会回任何数据。
        // URLSession 给足空间，**不允许它自己 timeout 之后又被自动 retry**——
        // 那会让 OpenAI 端重新跑一次 GPU 任务，重复扣费。
        cfg.timeoutIntervalForRequest  = 300        // 单次请求 300s 无新数据才算停滞
        cfg.timeoutIntervalForResource = 600        // 整个请求最长 600 秒
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private struct Pending {
        var continuation: CheckedContinuation<(Data, URLResponse), Error>
        var data: Data
        var bodyFileURL: URL?  // 完成后用来清理临时文件
        var jobId: UUID?       // 用于打日志
        var firstByteLogged: Bool = false
        var uploadCompleteLogged: Bool = false   // 防止 didSendBodyData 重复触发刷屏
        var totalSent: Int64 = 0
        var totalExpected: Int64 = 0
        var heartbeatTask: Task<Void, Never>?    // 上传完成后的"等待 OpenAI"心跳
    }

    private struct TaskMetadata: Codable {
        var jobId: UUID
        var url: String
    }

    private struct OrphanBuffer {
        var metadata: TaskMetadata
        var data: Data = Data()
    }

    private struct RecoveredResponse: Codable {
        var jobId: UUID
        var url: String
        var statusCode: Int?
        var data: Data?
        var errorMessage: String?
        var recordedAt: Date = Date()
    }

    private var pending: [Int: Pending] = [:]
    private var orphanBuffers: [Int: OrphanBuffer] = [:]
    private let lock = NSLock()
    private let fileManager = FileManager.default

    private var recoveredResponsesDir: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = documents.appendingPathComponent("RecoveredBackgroundResponses", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 把 multipart / JSON body 先写到临时文件，再用 uploadTask 提交。
    /// 等待响应完成（即使 App 进了后台，系统也会继续）。
    /// 支持 Swift Task 取消 —— 如果外层 Task 被取消，URLSessionTask 也会被取消。
    func upload(_ request: URLRequest,
                body bodyData: Data,
                jobId: UUID? = nil) async throws -> (Data, URLResponse) {
        // 1. 写临时文件
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload_\(UUID().uuidString).bin")
        try bodyData.write(to: tmpURL, options: .atomic)

        let urlPath = request.url?.absoluteString ?? "?"
        let kb = bodyData.count / 1024
        JobStore.log(jobId, "→ POST \(urlPath)")
        JobStore.log(jobId, "请求体已写入临时文件 (\(kb) KB)", level: .detail)

        // 2. 创建 task（先创建，后面 cancellation handler 也能引用）
        let urlTask = session.uploadTask(with: request, fromFile: tmpURL)
        if let jobId, let url = request.url?.absoluteString {
            let metadata = TaskMetadata(jobId: jobId, url: url)
            if let data = try? JSONEncoder().encode(metadata),
               let json = String(data: data, encoding: .utf8) {
                urlTask.taskDescription = json
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                pending[urlTask.taskIdentifier] = Pending(continuation: cont,
                                                          data: Data(),
                                                          bodyFileURL: tmpURL,
                                                          jobId: jobId)
                lock.unlock()
                JobStore.log(jobId, "提交 URLSession 上传任务，等待网络…", level: .detail)
                urlTask.resume()
            }
        } onCancel: {
            // 外层 Task 被取消 → 取消底层 URLSessionTask（delegate 会收到错误）
            JobStore.log(jobId, "收到 Task 取消信号，正在终止 URLSession", level: .warning)
            urlTask.cancel()
        }
    }

    /// 处理 background URLSession 启动 App 后系统传来的回调（在 AppDelegate / SceneDelegate 里调用）
    var backgroundCompletionHandler: (() -> Void)?

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        var jobIdToLog: UUID?
        var shouldStartHeartbeat = false
        let taskId = task.taskIdentifier
        lock.lock()
        if var entry = pending[taskId] {
            entry.totalSent = totalBytesSent
            entry.totalExpected = totalBytesExpectedToSend
            if !entry.uploadCompleteLogged
                && totalBytesExpectedToSend > 0
                && totalBytesSent == totalBytesExpectedToSend {
                entry.uploadCompleteLogged = true
                shouldStartHeartbeat = true
                jobIdToLog = entry.jobId
            }
            pending[taskId] = entry
        }
        lock.unlock()
        if shouldStartHeartbeat {
            JobStore.log(jobIdToLog,
                "上传完成 (\(totalBytesSent / 1024) KB)，等待 OpenAI 处理…",
                level: .info)
            startHeartbeat(taskId: taskId, jobId: jobIdToLog)
        }
    }

    /// 上传完成后启动一个心跳，每 30 秒在日志里报告还在等。
    /// 等收到首字节 / 任务完成 / 取消时，心跳被停掉。
    private func startHeartbeat(taskId: Int, jobId: UUID?) {
        let hb = Task { [weak self] in
            var sec = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30s
                if Task.isCancelled { return }
                sec += 30
                // 检查 task 是否还在 pending（没收到首字节也没完成）
                guard let self else { return }
                self.lock.lock()
                let stillWaiting = self.pending[taskId]?.firstByteLogged == false
                self.lock.unlock()
                if !stillWaiting { return }
                JobStore.log(jobId,
                    "已提交 OpenAI \(sec) 秒，仍未收到响应（gpt-image-2 多参考图常 150~300 秒）",
                    level: .detail)
            }
        }
        lock.lock()
        if var entry = pending[taskId] {
            entry.heartbeatTask = hb
            pending[taskId] = entry
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        var jobIdToLog: UUID?
        var shouldLogFirstByte = false
        var hbToCancel: Task<Void, Never>?
        if var entry = pending[dataTask.taskIdentifier] {
            if !entry.firstByteLogged {
                entry.firstByteLogged = true
                shouldLogFirstByte = true
                jobIdToLog = entry.jobId
                hbToCancel = entry.heartbeatTask
                entry.heartbeatTask = nil
            }
            entry.data.append(data)
            pending[dataTask.taskIdentifier] = entry
        } else if let metadata = taskMetadata(for: dataTask) {
            var orphan = orphanBuffers[dataTask.taskIdentifier] ?? OrphanBuffer(metadata: metadata)
            orphan.data.append(data)
            orphanBuffers[dataTask.taskIdentifier] = orphan
        }
        lock.unlock()
        hbToCancel?.cancel()
        if shouldLogFirstByte {
            JobStore.log(jobIdToLog, "收到 OpenAI 首字节响应 ✓", level: .success)
            // 记录"OpenAI 已开始 GPU 工作"的时刻——出现在 task 状态里
            if let id = jobIdToLog {
                Task { @MainActor in JobStore.shared.markOpenAIStarted(id) }
            }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        let orphan = orphanBuffers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        // 停掉心跳
        entry?.heartbeatTask?.cancel()

        // 清掉临时文件
        if let url = entry?.bodyFileURL {
            try? FileManager.default.removeItem(at: url)
        }

        guard let entry else {
            if let orphan {
                persistRecoveredResponse(
                    RecoveredResponse(
                        jobId: orphan.metadata.jobId,
                        url: orphan.metadata.url,
                        statusCode: (task.response as? HTTPURLResponse)?.statusCode,
                        data: orphan.data,
                        errorMessage: error?.localizedDescription
                    )
                )
            } else if let metadata = taskMetadata(for: task) {
                persistRecoveredResponse(
                    RecoveredResponse(
                        jobId: metadata.jobId,
                        url: metadata.url,
                        statusCode: (task.response as? HTTPURLResponse)?.statusCode,
                        data: nil,
                        errorMessage: error?.localizedDescription
                    )
                )
            }
            return
        }

        if let error {
            JobStore.log(entry.jobId,
                "URLSession 任务失败: \(error.localizedDescription)",
                level: .error)
            entry.continuation.resume(throwing: error)
        } else if let response = task.response as? HTTPURLResponse {
            // 整数除法不要让 600 字节显示为 0 KB
            let bytes = entry.data.count
            let sizeStr: String
            if bytes >= 1024 * 1024 {
                sizeStr = String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
            } else if bytes >= 1024 {
                sizeStr = "\(bytes / 1024) KB"
            } else {
                sizeStr = "\(bytes) 字节"
            }
            JobStore.log(entry.jobId,
                "传输完成: HTTP \(response.statusCode), 收到 \(sizeStr)",
                level: response.statusCode < 300 ? .success : .warning)
            entry.continuation.resume(returning: (entry.data, response))
        } else {
            entry.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }

    @MainActor
    func recoverPersistedResponses() {
        let urls = (try? fileManager.contentsOfDirectory(at: recoveredResponsesDir,
                                                         includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let response = try? JSONDecoder().decode(RecoveredResponse.self, from: data) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            recover(response)
            try? fileManager.removeItem(at: url)
        }
    }

    @MainActor
    private func recover(_ response: RecoveredResponse) {
        guard let job = JobStore.shared.jobs.first(where: { $0.id == response.jobId }) else {
            return
        }
        guard !job.phase.isFinal else { return }

        if let errorMessage = response.errorMessage {
            JobStore.shared.markTimeoutUnknown(
                job.id,
                message: "后台任务在 App 重启后返回，但原始等待链路已丢失：\(errorMessage)",
                errorCode: "BG_RECOVERY_ERROR"
            )
            return
        }

        guard let statusCode = response.statusCode,
              (200..<300).contains(statusCode),
              let payload = response.data else {
            let message = response.statusCode.map { "HTTP \($0)" } ?? "未知状态"
            JobStore.shared.markTimeoutUnknown(
                job.id,
                message: "后台任务在 App 重启后返回，但响应无法自动恢复（\(message)）。",
                errorCode: "BG_RECOVERY_INVALID"
            )
            return
        }

        switch job.kind {
        case .simpleImage, .storyRender:
            recoverMangaJob(job, payload: payload)
        case .characterViews:
            recoverCharacterJob(job, payload: payload)
        case .storyScript:
            JobStore.shared.markTimeoutUnknown(
                job.id,
                message: "编剧结果在 App 重启后返回，当前版本不会自动接回编辑界面。",
                errorCode: "BG_RECOVERY_UNSUPPORTED"
            )
        }
    }

    @MainActor
    private func recoverMangaJob(_ job: Job, payload: Data) {
        guard let outputs = decodeImagesEditResponse(payload),
              let inputFiles = job.inputImageFiles else {
            JobStore.shared.markTimeoutUnknown(
                job.id,
                message: "后台图片任务已完成，但自动恢复解析失败。",
                errorCode: "BG_RECOVERY_DECODE"
            )
            return
        }
        let inputDatas = inputFiles.compactMap {
            JobStore.shared.loadPendingImage($0, jobId: job.id)?.pngData()
        }
        guard !inputDatas.isEmpty else {
            JobStore.shared.markTimeoutUnknown(
                job.id,
                message: "后台图片任务已完成，但输入图快照已缺失，无法自动落库。",
                errorCode: "BG_RECOVERY_INPUT_MISSING"
            )
            return
        }
        let projectId = job.projectId ?? ProjectStore.shared.ensureDefaultProject().id
        let saved = MangaStorage.shared.add(
            projectId: projectId,
            style: job.style,
            inputs: inputDatas,
            outputs: outputs,
            userPrompt: job.userPromptText,
            storyScript: job.storyScriptSnapshot,
            previousPage: job.previousPageFile.flatMap {
                JobStore.shared.loadPendingImage($0, jobId: job.id)?.pngData()
            },
            loadedCharacterIds: job.characterIds,
            loadedCharacterSelections: job.characterSelections,
            bubbleTextMode: job.bubbleMode,
            isColorOutput: job.wasColorOn,
            imageCount: job.imageCount,
            imageSize: job.imageSizeStr,
            imageQuality: job.imageQualityStr
        )
        JobStore.shared.complete(job.id, with: saved.id)
    }

    @MainActor
    private func recoverCharacterJob(_ job: Job, payload: Data) {
        guard let outputs = decodeImagesEditResponse(payload),
              let first = outputs.first,
              let characterId = job.characterId else {
            JobStore.shared.markTimeoutUnknown(
                job.id,
                message: "后台角色任务已完成，但自动恢复解析失败。",
                errorCode: "BG_RECOVERY_DECODE"
            )
            return
        }
        let label = job.outputLabel ?? job.artStyle?.displayName
        guard let label else {
            JobStore.shared.markTimeoutUnknown(
                job.id,
                message: "后台角色任务已完成，但缺少视图标签，无法自动写回角色库。",
                errorCode: "BG_RECOVERY_LABEL_MISSING"
            )
            return
        }
        CharacterStore.shared.addViews(to: characterId, views: [(label, first)])
        JobStore.shared.complete(job.id, with: characterId)
    }

    private func taskMetadata(for task: URLSessionTask) -> TaskMetadata? {
        guard let taskDescription = task.taskDescription,
              let data = taskDescription.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(TaskMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }

    private func persistRecoveredResponse(_ response: RecoveredResponse) {
        let url = recoveredResponsesDir.appendingPathComponent("\(response.jobId.uuidString).json")
        guard let data = try? JSONEncoder().encode(response) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func decodeImagesEditResponse(_ data: Data) -> [Data]? {
        struct Resp: Decodable {
            struct Item: Decodable {
                let b64_json: String?
            }
            let data: [Item]
        }
        guard let response = try? JSONDecoder().decode(Resp.self, from: data) else {
            return nil
        }
        let outputs: [Data] = response.data.compactMap { (item: Resp.Item) -> Data? in
            guard let b64 = item.b64_json else { return nil }
            return Data(base64Encoded: b64)
        }
        return outputs.isEmpty ? nil : outputs
    }
}

// MARK: - 任务硬性超时熔断

struct TaskTimeoutError: LocalizedError {
    let seconds: Int
    var errorDescription: String? {
        let m = seconds / 60
        let s = seconds % 60
        let dur = s == 0 ? "\(m) 分钟" : "\(m) 分 \(s) 秒"
        return "任务运行超过 \(dur)，已自动终止（OpenAI 持续没响应，跟咱们代码无关，可点重新生成）"
    }
}

/// 给一段 async 工作设个硬性截止时间。超过 → 抛 TaskTimeoutError + 取消所有内嵌 URLSession。
/// 注意：图像接口已经禁用了这个保险栓（见 MangaGeneratorViewModel），
///       仅留给那些"快接口必须按时返回"的场景使用。
func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                _ work: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await work()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TaskTimeoutError(seconds: Int(seconds))
        }
        // 谁先返回（成功或抛错）就用谁，并 cancelAll 杀掉另一个
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// 把任何"提交了 OpenAI 但客户端没拿到结果"的错误都归为 timeoutUnknown，避免无脑标 failed。
/// 调度规则：
///   - URLError 网络层错误（timedOut / cancelled / connection lost / dns / 等） → timeoutUnknown
///   - TaskTimeoutError（外层墙钟）                                                 → timeoutUnknown
///   - CancellationError                                                            → failed("已取消")
///   - OpenAIError 4xx safety / 5xx                                                 → failed
///   - 其它未知                                                                     → timeoutUnknown
@MainActor
func resolveJobError(_ error: Error, jobId: UUID, label: String? = nil) {
    let prefix = label.map { "「\($0)」" } ?? ""
    if let url = error as? URLError {
        switch url.code {
        case .timedOut, .networkConnectionLost, .cancelled, .notConnectedToInternet,
             .badServerResponse, .resourceUnavailable, .dnsLookupFailed:
            JobStore.shared.markTimeoutUnknown(
                jobId,
                message: "\(prefix)客户端 \(url.code) 中断。OpenAI 端可能仍在生成，" +
                         "也可能确实失败。如要再次生成，请确认账户没有重复扣费后手动点「重新生成」。",
                errorCode: "URL_\(url.code.rawValue)"
            )
            LocalNotifier.notifyFailure(message: "生成时间较长 / 网络中断。请稍后查看任务列表。")
            return
        default: break
        }
    }
    if let t = error as? TaskTimeoutError {
        JobStore.shared.markTimeoutUnknown(jobId, message: "\(prefix)\(t.localizedDescription)",
                                            errorCode: "WALLCLOCK_TIMEOUT")
        LocalNotifier.notifyFailure(message: t.localizedDescription)
        return
    }
    if error is CancellationError {
        JobStore.shared.fail(jobId, message: "已取消", errorCode: "CANCELLED")
        return
    }
    if let oa = error as? OpenAIError {
        let code: String = {
            switch oa {
            case .missingAPIKey: return "MISSING_API_KEY"
            case .invalidImage:  return "INVALID_IMAGE"
            case .decodingFailed: return "DECODING_FAILED"
            case .requestFailed(let s, _): return oa.isSafetyBlocked ? "SAFETY" : "HTTP_\(s)"
            case .unknown: return "UNKNOWN"
            }
        }()
        JobStore.shared.fail(jobId, message: "\(prefix)\(oa.localizedDescription)", errorCode: code)
        LocalNotifier.notifyFailure(message: oa.localizedDescription)
        return
    }
    JobStore.shared.markTimeoutUnknown(jobId, message: "\(prefix)\(error.localizedDescription)",
                                        errorCode: "UNKNOWN")
    LocalNotifier.notifyFailure(message: error.localizedDescription)
}

// MARK: - 本地通知：完成时弹个通知

enum LocalNotifier {

    /// App 启动时调用一次，用户首次会看到权限请求
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    /// 在生成成功时调用
    static func notifyDone(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// 失败时也通知一下，避免用户在锁屏期间错过
    static func notifyFailure(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "漫画生成失败"
        content.body = message
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Errors

enum OpenAIError: LocalizedError {
    case missingAPIKey
    case invalidImage
    case requestFailed(status: Int, body: String)
    case decodingFailed
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未配置漫画后端地址或后端 API Key，请先到「设置」中填入。"
        case .invalidImage:
            return "图片读取失败，请重新选择。"
        case .requestFailed(let status, let body):
            return prettyError(status: status, body: body)
        case .decodingFailed:
            return "OpenAI 返回内容解析失败。"
        case .unknown(let msg):
            // 把"请求超时"翻译成更友好的提示
            if msg.contains("超时") || msg.lowercased().contains("timed out") || msg.lowercased().contains("timeout") {
                return "请求超时：OpenAI 服务在 6 分钟内没返回结果（可能是高峰期排队 / 网络抖动）。已自动重试 3 次仍失败。\n\n建议：\n• 稍候 1~2 分钟再试\n• 检查 status.openai.com 看是否服务异常\n• 如果是角色多动作生成，可以先试少一些（每次 3~5 个）"
            }
            return msg
        }
    }

    /// 把 502 那种 HTML 大块内容化简成一句人话
    private func prettyError(status: Int, body: String) -> String {
        // 500 是 OpenAI 自己抛的错——信息明确告诉用户这是服务端问题
        if status == 500 {
            // 提取 request ID 给用户排查
            var ridLine = ""
            if let r = body.range(of: #"req_[a-f0-9]{20,}"#, options: .regularExpression) {
                ridLine = "\n\nRequest ID: \(String(body[r]))"
            }
            return "OpenAI 服务器内部错误 (HTTP 500)\n\n这是 OpenAI 后端处理时崩了，跟你的输入图片或 prompt 通常无关。\n\n建议：\n• 等 5~10 分钟再试（多数是临时故障）\n• 检查 status.openai.com 是否有 incident\n• 试着换一张参考图（极少数情况是图片触发边界）\n\n📌 OpenAI 政策：HTTP 500 失败一般不扣费。\(ridLine)"
        }
        // 如果是 HTML（Cloudflare 错误页）→ 简化
        if body.contains("<html") || body.contains("<!DOCTYPE") {
            let hint: String
            switch status {
            case 502: hint = "Cloudflare 报告 OpenAI 后端 502 Bad Gateway（云端临时故障，常见于高峰期）"
            case 503: hint = "OpenAI 服务暂不可用 (503)"
            case 504: hint = "OpenAI 网关超时 (504)"
            case 524: hint = "OpenAI 处理时间超过 Cloudflare 限制 (524)"
            default:  hint = "上游网关错误 \(status)"
            }
            return "OpenAI 请求失败：\(hint)\n\n建议：稍候 10~30 秒再试一次。这类 5xx 通常是临时故障。"
        }

        // 尝试把 JSON error.message 提出来
        var underlying = body
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err  = json["error"] as? [String: Any],
           let msg  = err["message"] as? String {
            underlying = msg
        }
        let lower = underlying.lowercased()

        // ⚠️ 内容安全系统拦截 —— 给出明确建议
        if status == 400, lower.contains("safety system")
                       || lower.contains("rejected")
                       || lower.contains("moderation")
                       || lower.contains("content policy") {
            return """
            OpenAI 安全系统拒绝了这次请求。

            可能原因有 3 种：
            ① 照片里确实有可识别的婴儿 / 儿童（OpenAI 严格禁止用真人小孩做参考图）
            ② 成年人被误判为儿童 —— 安全分类器常见误报，尤其是亚洲面孔、看起来年轻的成年人、自拍仰拍角度（V 脸）、休闲穿着
            ③ 照片被判为其它敏感内容

            如果是成年人被误判（最常见）：
            • 换一张更明显成年特征的照片（半身或全身、避免下巴朝上的仰拍角度）
            • 选择正式服装 / 工作场景 / 更成熟表情的照片
            • 在「一句话设定」里明确写"30 岁成年人"
            • 直接重新生成一次 —— 分类器有随机性，下次可能就过

            如果照片确实是儿童：
            • 改用风景 / 食物 / 物品类素材
            • 想让角色是小孩 → 不传照片，让 AI 凭空虚构
            """
        }

        // 配额不足
        if status == 429 || lower.contains("quota") || lower.contains("billing") {
            return "OpenAI 额度 / 速率限制 (HTTP \(status))：\(underlying)\n\n请检查 OpenAI 账户余额或稍后再试。"
        }

        // organization verification
        if status == 403 && (lower.contains("verify") || lower.contains("organization")) {
            return "OpenAI 拒绝调用 gpt-image-2：你的账户尚未完成 organization 验证。\n\n请到 platform.openai.com → Settings → Organization 完成验证后再试。"
        }

        return "后端请求失败 (HTTP \(status))：\(underlying)"
    }

    /// 是否值得自动重试（5xx / 网关 / 限流 / 网络）
    var isTransient: Bool {
        switch self {
        case .requestFailed(let status, _):
            return status == 408 || status == 500 ||
                   status == 502 || status == 503 || status == 504 || status == 524
        case .unknown: return true
        default: return false
        }
    }

    /// 是否为安全策略拒绝（重试也没用）
    var isSafetyBlocked: Bool {
        if case .requestFailed(let status, let body) = self,
           status == 400 {
            let lower = body.lowercased()
            return lower.contains("safety system")
                || lower.contains("rejected")
                || lower.contains("moderation")
                || lower.contains("content policy")
        }
        return false
    }
}

// MARK: - 普通模式请求

struct OpenAIImageRequest {
    var inputImages: [UIImage]
    /// "前一张"参考图（来自历史或外部上传）—— 用于延续画风/角色/故事
    var previousPageImage: UIImage?
    /// 角色库参考图（角色"正面"立绘）—— 让 AI 把这些角色画进剧情
    var characterReferenceImages: [UIImage] = []
    var characterDirective: String? = nil
    /// 这个 prompt 已经按 isColor 解析过（来自 MangaStyle.effectivePrompt(isColor:)）
    var stylePrompt: String
    var userPrompt: String?
    var n: Int
    var size: String
    var quality: String
    /// 气泡里写什么文字: "chinese" / "japanese" / "english" / "empty" / "none"
    var bubbleTextMode: String

    /// 输入指纹：让相同输入的请求产生同样的字符串，用来 60s 内拦截重复提交。
    /// 包含：所有图（简化为像素总数 + 平均亮度近似）、prompt、size、quality、n、bubble、含前一张。
    var fingerprint: String {
        // 给每张图片打个简便指纹：尺寸 + 4 角像素的合
        func sig(_ img: UIImage) -> String {
            let w = Int(img.size.width)
            let h = Int(img.size.height)
            return "\(w)x\(h)"
        }
        var parts: [String] = []
        parts.append("style=\(stylePrompt.hashValue)")
        parts.append("user=\((userPrompt ?? "").hashValue)")
        parts.append("bubble=\(bubbleTextMode)")
        parts.append("n=\(n)|size=\(size)|q=\(quality)")
        parts.append("prev=\(previousPageImage.map { sig($0) } ?? "-")")
        parts.append("inputs=\(inputImages.map(sig).joined(separator: ","))")
        parts.append("chars=\(characterReferenceImages.map(sig).joined(separator: ","))")
        return String(parts.joined(separator: "|").hashValue)
    }

    var combinedPrompt: String {
        var parts: [String] = [stylePrompt]
        parts.append(BubbleDirective.simpleMode(bubbleTextMode))
        if previousPageImage != nil {
            parts.append(BubbleDirective.continuityDirective)
        }
        if let cd = characterDirective {
            parts.append(cd)
        }
        if let extra = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !extra.isEmpty {
            parts.append("Additional user note: " + extra)
        }
        return parts.joined(separator: "\n\n")
    }

    func groupedInputImagesForPages() -> [[UIImage]] {
        guard !inputImages.isEmpty else { return [] }
        let pageCount = max(1, n)
        if pageCount == 1 { return [inputImages] }

        if inputImages.count < pageCount {
            return (0..<pageCount).map { index in
                [inputImages[min(index, inputImages.count - 1)]]
            }
        }

        var groups: [[UIImage]] = []
        let base = inputImages.count / pageCount
        let extra = inputImages.count % pageCount
        var cursor = 0

        for pageIndex in 0..<pageCount {
            let count = base + (pageIndex < extra ? 1 : 0)
            let nextCursor = min(inputImages.count, cursor + count)
            groups.append(Array(inputImages[cursor..<nextCursor]))
            cursor = nextCursor
        }

        return groups
    }

    func promptForSequentialPage(index: Int,
                                 total: Int,
                                 pageImageCount: Int,
                                 hasPreviousGeneratedPage: Bool) -> String {
        var parts: [String] = [stylePrompt]
        parts.append(BubbleDirective.simpleMode(bubbleTextMode))
        if previousPageImage != nil || hasPreviousGeneratedPage {
            parts.append(BubbleDirective.continuityDirective)
        }
        if total > 1 {
            if index == 0 {
                parts.append("""
                MULTI-PAGE STORY MODE:
                You are generating page 1 of \(total) connected manga pages from a larger uploaded photo set.
                This page should primarily use the CURRENT attached subset of \(pageImageCount) source photo(s).
                Start a coherent story here. Leave natural room for continuation on the next page instead of resolving everything immediately.
                """)
            } else if index == total - 1 {
                parts.append("""
                MULTI-PAGE STORY MODE:
                You are generating page \(index + 1) of \(total) connected manga pages from a larger uploaded photo set.
                This page should primarily use the CURRENT attached subset of \(pageImageCount) source photo(s).
                Continue directly from the immediately previous page and bring the mini-story to a satisfying conclusion here.
                """)
            } else {
                parts.append("""
                MULTI-PAGE STORY MODE:
                You are generating page \(index + 1) of \(total) connected manga pages from a larger uploaded photo set.
                This page should primarily use the CURRENT attached subset of \(pageImageCount) source photo(s).
                Continue directly from the previous page, expand the same story, and keep clear momentum into the next page.
                """)
            }
            parts.append("""
            Do NOT try to retell every uploaded moment on every page.
            Focus this page on the currently attached subset of photos, while keeping the same protagonist, tone, and story continuity across pages.
            """)
        }
        if let cd = characterDirective {
            parts.append(cd)
        }
        if let extra = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !extra.isEmpty {
            parts.append("Additional user note: " + extra)
        }
        return parts.joined(separator: "\n\n")
    }
}

/// 气泡 / 延续 等 prompt 的拼装工具
enum BubbleDirective {

    /// "前一张"风格延续指令
    static let continuityDirective: String = """
    STYLE & STORY CONTINUITY:
    The FIRST attached reference image is the PREVIOUS manga page from the same comic. \
    Treat it as the gold standard for art style, line weight, character designs, costume \
    details, and overall aesthetic. The new page must look like it could come right after \
    that page in the same printed book. \
    If recurring characters appear, KEEP their faces, hair, and outfits identical. \
    Continue the visual narrative naturally — do not reset the style.
    """

    /// 普通模式下的气泡指令（追加到 styleprompt 后面）
    static func simpleMode(_ mode: String) -> String {
        switch mode {
        case "none":
            return """
            BUBBLE / TEXT INSTRUCTION (override anything else):
            Do NOT draw any speech bubbles, caption boxes, or dialogue text on this page. \
            Pure visual illustration only. Sound-effect kanji/katakana lettering integrated \
            into the artwork is still allowed if appropriate to the style.
            """
        case "empty":
            return """
            BUBBLE / TEXT INSTRUCTION:
            If you draw speech bubbles or caption boxes, leave them COMPLETELY EMPTY — \
            do NOT write any text inside them. Sound-effect lettering is still allowed.
            """
        case "japanese":
            return """
            BUBBLE / TEXT INSTRUCTION:
            If you add speech bubbles, render the dialogue inside them in JAPANESE \
            (natural manga-style Japanese, allowing kanji plus hiragana/katakana). \
            Do NOT use English. Do NOT use Chinese.
            """
        case "english":
            return """
            BUBBLE / TEXT INSTRUCTION:
            If you add speech bubbles, render the dialogue inside them in ENGLISH \
            (short natural English manga-style lines).
            """
        default: // "chinese"
            return """
            BUBBLE / TEXT INSTRUCTION:
            If you add speech bubbles, render the dialogue inside them in SIMPLIFIED \
            CHINESE (短的中文台词，自然的漫画对话，每个气泡 ≤ 12 字). \
            Do NOT use English. Do NOT use Japanese kana.
            """
        }
    }
}

// MARK: - 故事模式请求

struct OpenAIStoryRequest {
    var inputImages: [UIImage]
    /// "前一张"参考图（来自历史或外部上传）—— 用于延续画风/角色/故事
    var previousPageImage: UIImage?
    /// 角色库参考图
    var characterReferenceImages: [UIImage] = []
    var characterDirective: String? = nil
    var style: MangaStyle
    /// 用户故事提示（可选）
    var userHint: String?
    /// 期望的分镜格数
    var panelCount: Int
    /// 视觉编剧模型，比如 "gpt-5.4-mini" / "gpt-5.5"
    var scriptModel: String
    /// 渲染分辨率 / 质量
    var size: String
    var quality: String
    /// 气泡里写什么文字: "chinese" / "japanese" / "empty"
    var bubbleTextMode: String
    /// 彩色 / 黑白
    var isColor: Bool
    /// 漫画化强度（0 偏实景，1 偏强漫画）
    var stylizationStrength: Double
    /// 是否尽量保留真实场景可识别性（尤其用于导航案内）
    var preserveRealWorldReadability: Bool
}

private struct BackendConfig {
    let baseURL: URL
    let apiKey: String
}

private struct BackendTaskSubmission: Decodable {
    let task_id: String
    let status: String
}

private struct BackendTaskStatus: Decodable {
    let id: String
    let status: String
    let output_count: Int?
    let error_code: String?
    let error_message: String?
}

private struct BackendStoryScriptResponse: Decodable {
    let script: MangaStoryScript
}

// MARK: - Service

final class OpenAIService {

    static let shared = OpenAIService()
    private init() {}

    private let imagesEdit = URL(string: "https://api.openai.com/v1/images/edits")!
    private let chatCompletions = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let imageModel = "gpt-image-2"

    /// 最多重试次数（仅适用于纯文本接口，比如编剧本）。
    /// **图像生成接口（/v1/images/edits）禁止任何自动重试**，
    /// 因为一次 timeout 之后无法判断 OpenAI 是否仍在跑 GPU，retry 会重复扣费。
    private let maxRetries = 1

    /// 统一的"带退避的重试"包装。仅文本接口使用（`allowAutoRetry: true`）。
    /// 图像接口必须 `allowAutoRetry: false`。
    private func withRetry<T>(label: String,
                              allowAutoRetry: Bool,
                              onRetry: (@MainActor (String) -> Void)? = nil,
                              jobId: UUID? = nil,
                              perform: () async throws -> T) async throws -> T {
        // 图像接口直接走单次执行，绝不 retry
        guard allowAutoRetry else {
            return try await perform()
        }
        var attempt = 0
        while true {
            do {
                return try await perform()
            } catch {
                // 判断是否值得重试：OpenAI 5xx / 网络异常 / 超时
                let retryable: Bool = {
                    if let oa = error as? OpenAIError, oa.isTransient { return true }
                    if let url = error as? URLError {
                        switch url.code {
                        case .timedOut, .cannotConnectToHost, .cannotFindHost,
                             .networkConnectionLost, .notConnectedToInternet,
                             .dnsLookupFailed, .resourceUnavailable, .badServerResponse:
                            return true
                        default: return false
                        }
                    }
                    return false
                }()

                if retryable && attempt < maxRetries {
                    attempt += 1
                    let secs: [UInt64] = [5, 15, 30]
                    let delay = secs[min(attempt - 1, secs.count - 1)] * 1_000_000_000
                    JobStore.log(jobId,
                        "暂时失败 (\(error.localizedDescription)) → \(secs[min(attempt-1, secs.count-1)]) 秒后第 \(attempt)/\(maxRetries) 次重试",
                        level: .warning)
                    if let onRetry {
                        await onRetry("\(label)（暂时失败，\(attempt)/\(maxRetries) 次重试中…）")
                    }
                    try? await Task.sleep(nanoseconds: delay)
                    continue
                }
                JobStore.log(jobId, "重试已耗尽，最终失败: \(error.localizedDescription)", level: .error)
                throw error
            }
        }
    }

    @MainActor
    func resumeServerBackedJobs() {
        for job in JobStore.shared.jobs where job.phase.isRunning {
            guard let backendTaskId = job.backendTaskId, !backendTaskId.isEmpty else { continue }
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.resumeBackendTask(jobId: job.id,
                                                     backendTaskId: backendTaskId,
                                                     stageLabel: "正在与服务器同步任务状态…")
                } catch {
                    resolveJobError(error, jobId: job.id)
                }
            }
            JobStore.shared.attachTask(task, to: job.id)
        }
    }

    // MARK: 角色库：基于真人照片生成动漫角色立绘

    /// 角色立绘视图配置（标签 + 给模型的 prompt）
    struct CharacterViewSpec {
        let label: String      // 中文标签如"正面"
        let prompt: String     // 英文 prompt 描述这个视图
    }

    static let defaultCharacterViews: [CharacterViewSpec] = [
        CharacterViewSpec(label: "正面",
            prompt: "Standing T-pose facing camera, full body, neutral expression, neutral A-pose"),
        CharacterViewSpec(label: "背面",
            prompt: "Standing facing AWAY from camera, full body view of the back of the character"),
        CharacterViewSpec(label: "侧面",
            prompt: "Standing in profile, side view, full body silhouette readable")
    ]

    /// 预设的扩展动作 / 镜头池（按分类组织，UI 多选 → 批量生成）
    struct PoseGroup: Identifiable {
        let id: String
        let title: String
        let poses: [CharacterViewSpec]
    }

    static let extendedPoseGroups: [PoseGroup] = [
        PoseGroup(id: "daily", title: "日常动作", poses: [
            .init(label: "行走",   prompt: "walking forward at normal pace, casual stride, full body, slight 3/4 angle"),
            .init(label: "奔跑",   prompt: "running fast, dynamic action pose, motion lines, hair and clothes flowing back"),
            .init(label: "跳跃",   prompt: "mid-air jump with arms raised, dynamic upward motion, full body"),
            .init(label: "坐着",   prompt: "sitting on a chair (or floor), relaxed pose, full body visible"),
            .init(label: "躺下",   prompt: "lying on back peacefully, full body horizontal, hands at sides"),
            .init(label: "蹲下",   prompt: "squatting/crouching low to the ground, balanced pose, full body"),
            .init(label: "靠墙",   prompt: "leaning against a wall casually, one foot up, hands in pockets, full body"),
            .init(label: "走路看手机", prompt: "walking while looking at smartphone, head slightly down, full body"),
        ]),
        PoseGroup(id: "emotion", title: "情绪表现", poses: [
            .init(label: "大笑",   prompt: "laughing happily with head tilted back, big smile, joyful expression, full body"),
            .init(label: "哭泣",   prompt: "crying with tears, sad expression, slumped shoulders"),
            .init(label: "生气",   prompt: "angry expression, fists clenched, aggressive standing posture"),
            .init(label: "惊讶",   prompt: "shocked surprised expression, eyes wide, mouth open, recoiling slightly"),
            .init(label: "害羞",   prompt: "shy embarrassed look, blushing, averted gaze, hand near face"),
            .init(label: "思考",   prompt: "thinking pose, hand on chin, contemplative expression, full body"),
        ]),
        PoseGroup(id: "action", title: "动作戏（非血腥）", poses: [
            .init(label: "防御",   prompt: "defensive stance, arms raised guarding face, balanced ready pose"),
            .init(label: "出拳",   prompt: "punching forward dynamically, fist extended, action pose with motion"),
            .init(label: "踢腿",   prompt: "high kick pose, leg extended, dynamic action"),
            .init(label: "摔倒",   prompt: "falling backward off-balance dramatically (no injury), full body"),
            .init(label: "全力冲刺", prompt: "sprinting at full speed, leaning forward, dramatic forward motion"),
        ]),
        PoseGroup(id: "interaction", title: "互动 / 表演", poses: [
            .init(label: "招手",   prompt: "waving hand in friendly greeting, big smile, full body"),
            .init(label: "敬礼",   prompt: "saluting formally, upright posture, full body"),
            .init(label: "握手",   prompt: "extending hand for a handshake, friendly expression"),
            .init(label: "指着前方", prompt: "pointing forward dramatically, full body, determined expression"),
            .init(label: "鞠躬",   prompt: "bowing politely, hands at sides, traditional bow"),
        ]),
        PoseGroup(id: "camera", title: "镜头视角", poses: [
            .init(label: "正面特写", prompt: "head and shoulders close-up portrait, front view, neutral expression"),
            .init(label: "侧脸特写", prompt: "side profile close-up, head and shoulders only"),
            .init(label: "3/4 视角", prompt: "three-quarter angle full body view, slightly turned"),
            .init(label: "仰视镜头", prompt: "low angle dramatic shot looking up at the character, full body, towering perspective"),
            .init(label: "俯视镜头", prompt: "high angle shot looking down at the character, full body, top-down feel"),
            .init(label: "侧面",
                  prompt: "pure 90-degree side profile, full body, character facing left or right, clean readable silhouette"),
            .init(label: "背面",
                  prompt: "full back view, character facing AWAY from camera, full body visible from behind"),
            .init(label: "前半侧面",
                  prompt: "three-quarter FRONT angle, full body, character mostly facing camera with a slight turn so most of the face is visible"),
            .init(label: "后半侧面",
                  prompt: "three-quarter BACK angle, full body, character mostly facing away with shoulder/back visible, only a sliver of face from over the shoulder"),
        ]),
    ]

    // MARK: 角色资产：标准立绘 / 高级设定图

    /// 先生成一张干净的标准立绘，后续高级设定图 / 动作合集都可以拿它做主参考。
    func generateCharacterPortrait(sourcePhoto: UIImage,
                                   name: String,
                                   bio: String?,
                                   ageGroup: CharacterAgeGroup,
                                   gender: CharacterGender,
                                   artStyle: CharacterArtStyle,
                                   size: String,
                                   quality: String,
                                   jobId: UUID? = nil,
                                   onStage: @MainActor @escaping (String) -> Void)
        async throws -> Data
    {
        JobStore.log(jobId, "开始生成「\(artStyle.displayName)」标准立绘")
        JobStore.log(jobId, "角色名: \(name)", level: .detail)
        if let b = bio, !b.isEmpty {
            JobStore.log(jobId, "角色设定: \(b)", level: .detail)
        }
        guard currentBackendConfig() != nil else {
            JobStore.log(jobId, "❌ 未配置后端地址或后端 API Key", level: .error)
            throw OpenAIError.missingAPIKey
        }
        JobStore.log(jobId, "已加载 VPS 后端配置", level: .detail)
        await onStage("正在生成「\(artStyle.displayName)」标准立绘…")
        let prompt = buildCharacterPortraitPrompt(name: name,
                                                 bio: bio,
                                                 ageGroup: ageGroup,
                                                 gender: gender,
                                                 artStyle: artStyle)
        JobStore.log(jobId, "Prompt 已构造 (\(prompt.count) 字符)", level: .detail)

        let datas = try await submitImageTask(
            images: [sourcePhoto],
            prompt: prompt,
            n: 1,
            size: size,
            quality: quality,
            jobId: jobId,
            onStage: onStage
        )
        guard let first = datas.first else {
            JobStore.log(jobId, "OpenAI 返回空 data 数组", level: .error)
            throw OpenAIError.unknown("未生成任何图像")
        }
        JobStore.log(jobId, "解析成功，图像 \(first.count / 1024) KB ✓", level: .success)
        return first
    }

    /// 一次性生成一张复杂角色设定页——主体 + 表情区 + 服装/配饰/生活物件 + 细节 callout。
    func generateAdvancedCharacterSheet(sourcePhoto: UIImage,
                                        basePortrait: UIImage?,
                                        name: String,
                                        bio: String?,
                                        ageGroup: CharacterAgeGroup,
                                        gender: CharacterGender,
                                        artStyle: CharacterArtStyle,
                                        size: String,
                                        quality: String,
                                        jobId: UUID? = nil,
                                        onStage: @MainActor @escaping (String) -> Void)
        async throws -> Data
    {
        JobStore.log(jobId, "开始生成「\(artStyle.displayName)」高级设定图")
        JobStore.log(jobId, "角色名: \(name)", level: .detail)
        if let b = bio, !b.isEmpty {
            JobStore.log(jobId, "角色设定: \(b)", level: .detail)
        }
        guard currentBackendConfig() != nil else {
            JobStore.log(jobId, "❌ 未配置后端地址或后端 API Key", level: .error)
            throw OpenAIError.missingAPIKey
        }
        JobStore.log(jobId, "已加载 VPS 后端配置", level: .detail)
        await onStage("正在生成「\(artStyle.displayName)」高级设定图…")
        let prompt = buildAdvancedCharacterSheetPrompt(name: name,
                                                       bio: bio,
                                                       ageGroup: ageGroup,
                                                       gender: gender,
                                                       artStyle: artStyle)
        JobStore.log(jobId, "Prompt 已构造 (\(prompt.count) 字符)", level: .detail)

        var images: [UIImage] = []
        if let basePortrait { images.append(basePortrait) }
        images.append(sourcePhoto)
        let datas = try await submitImageTask(
            images: images,
            prompt: prompt,
            n: 1,
            size: size,
            quality: quality,
            jobId: jobId,
            onStage: onStage
        )
        guard let first = datas.first else {
            JobStore.log(jobId, "OpenAI 返回空 data 数组", level: .error)
            throw OpenAIError.unknown("未生成任何图像")
        }
        JobStore.log(jobId, "解析成功，图像 \(first.count / 1024) KB ✓", level: .success)
        return first
    }

    private func buildCharacterPortraitPrompt(name: String,
                                              bio: String?,
                                              ageGroup: CharacterAgeGroup,
                                              gender: CharacterGender,
                                              artStyle: CharacterArtStyle) -> String {
        var lines: [String] = []
        lines.append("Create a polished full-body CHARACTER PORTRAIT based on the reference photo.")
        lines.append("This is NOT a collage or design board. It must be a single clean standing character illustration.")
        lines.append("")
        lines.append("Composition:")
        lines.append("• One \(ageGroup.promptPhrase) \(gender.promptPhrase) character only, full body visible from head to shoes.")
        lines.append("• Plain pure white or very light neutral studio background.")
        lines.append("• Clean silhouette, natural relaxed standing pose, fashion-illustration presentation.")
        lines.append("• No extra props, no text, no labels, no callout boxes, no duplicate heads.")
        lines.append("")
        lines.append("Character: \(name).\(bio.flatMap { $0.isEmpty ? nil : " \($0)." } ?? "")")
        lines.append("")
        lines.append("Art style: \(artStyle.prompt)")
        lines.append("")
        lines.append("Rules: The character should clearly read as \(ageGroup.promptPhrase) and \(gender.promptPhrase), not another life stage. Match face, hair, body build and vibe from the source photo as closely as the policy allows. Make the outfit feel signature and coherent with the bio. Render in full color. Premium clean character reference illustration quality.")
        return lines.joined(separator: "\n")
    }

    private func buildAdvancedCharacterSheetPrompt(name: String,
                                                   bio: String?,
                                                   ageGroup: CharacterAgeGroup,
                                                   gender: CharacterGender,
                                                   artStyle: CharacterArtStyle) -> String {
        let moodItems: String
        switch artStyle {
        case .jpAnime, .krManhwa:
            moodItems = "journal, phone, bag, drink, accessory"
        case .semiReal:
            moodItems = "friendly backpack, storybook, drink cup, badge, playful accessory"
        case .usComics:
            moodItems = "gear, bag, notebook, device, accessory"
        case .kawaii, .chibi:
            moodItems = "cute bag, phone charm, snack, notebook, accessory"
        case .render3D:
            moodItems = "tech gadget, bag, drink, accessory, notebook"
        case .watercolor:
            moodItems = "book, perfume, scarf, notebook, accessory"
        case .pixelArt:
            moodItems = "retro bag, handheld device, notebook, drink, accessory"
        }
        var lines: [String] = []
        lines.append("Create a richly designed CHARACTER DESIGN BOARD / REFERENCE SHEET on ONE page.")
        lines.append("This should feel like a premium anime / manga / illustration character setup board, not a simple collage.")
        lines.append("")
        lines.append("Layout:")
        lines.append("• Center: one large full-body main character as the hero image.")
        lines.append("• Top-right: 4 to 5 expression portraits with varied emotions.")
        lines.append("• Left side: outfit breakdown pieces or clothing components.")
        lines.append("• Bottom area: 4 to 6 personal belongings / lifestyle items related to the character.")
        lines.append("• Add 2 to 4 zoomed detail callout boxes (fabric, hair, accessory, hand detail, texture, etc).")
        lines.append("• Use arrows, framed sections, and clean editorial spacing to organize the board.")
        lines.append("")
        lines.append("Character: \(name).\(bio.flatMap { $0.isEmpty ? nil : " \($0)." } ?? "")")
        lines.append("Target profile: \(ageGroup.promptPhrase), \(gender.promptPhrase).")
        lines.append("Personal item inspiration: \(moodItems).")
        lines.append("")
        lines.append("Art style: \(artStyle.prompt)")
        lines.append("")
        lines.append("Rules:")
        lines.append("• Keep the character clearly within the requested life stage (\(ageGroup.promptPhrase)) and gender presentation (\(gender.promptPhrase)).")
        lines.append("• Keep the SAME person across main figure and all portraits.")
        lines.append("• Use a refined design-board aesthetic with off-white paper or clean grid/studio sheet background.")
        lines.append("• Text, if any, must be minimal short labels only. Prioritize visuals over dense writing.")
        lines.append("• The board should feel information-rich, curated, and professionally art-directed.")
        lines.append("• Full color, polished, attractive, collectible concept-sheet quality.")
        return lines.joined(separator: "\n")
    }

    /// 把 N 个动作 / 镜头**合并到一张图**里输出（pose sheet 模式）
    func generatePoseSheet(sourcePhoto: UIImage,
                           name: String,
                           bio: String?,
                           ageGroup: CharacterAgeGroup,
                           gender: CharacterGender,
                           specs: [CharacterViewSpec],
                           style: MangaStyle,
                           isColor: Bool,
                           size: String,
                           quality: String,
                           jobId: UUID? = nil,
                           onStage: @MainActor @escaping (String) -> Void)
        async throws -> Data
    {
        JobStore.log(jobId, "开始生成动作合集（\(specs.count) 个动作合并到一张图）")
        guard currentBackendConfig() != nil else {
            JobStore.log(jobId, "❌ 未配置后端地址或后端 API Key", level: .error)
            throw OpenAIError.missingAPIKey
        }
        await onStage("正在生成动作合集（\(specs.count) 个动作）…")
        let prompt = buildPoseSheetPrompt(name: name,
                                          bio: bio,
                                          ageGroup: ageGroup,
                                          gender: gender,
                                          specs: specs,
                                          style: style, isColor: isColor)
        JobStore.log(jobId, "Prompt 已构造 (\(prompt.count) 字符)", level: .detail)

        let datas = try await submitImageTask(
            images: [sourcePhoto],
            prompt: prompt,
            n: 1,
            size: size,
            quality: quality,
            jobId: jobId,
            onStage: onStage
        )
        guard let first = datas.first else {
            throw OpenAIError.unknown("未生成任何图像")
        }
        JobStore.log(jobId, "动作合集生成成功，图像 \(first.count / 1024) KB ✓", level: .success)
        return first
    }

    private func buildPoseSheetPrompt(name: String,
                                      bio: String?,
                                      ageGroup: CharacterAgeGroup,
                                      gender: CharacterGender,
                                      specs: [CharacterViewSpec],
                                      style: MangaStyle,
                                      isColor: Bool) -> String {
        var lines: [String] = []
        lines.append("Create a single character pose sheet illustration on plain white background — show the SAME \(ageGroup.promptPhrase) \(gender.promptPhrase) character drawn \(specs.count) times in different poses, all arranged on ONE page.")
        lines.append("")
        lines.append("Character: \(name).\(bio.flatMap { $0.isEmpty ? nil : " \($0)." } ?? "")")
        lines.append("")
        lines.append("Show the character in these \(specs.count) poses:")
        for (i, s) in specs.enumerated() {
            lines.append("\(i + 1). \(s.label) — \(s.prompt)")
        }
        lines.append("")
        lines.append("Layout: white background, balanced grid (e.g. 3 columns × needed rows). Each pose has a small bilingual caption below it (中文 / English).")
        lines.append("")
        lines.append("Art style:")
        lines.append(style.effectivePrompt(isColor: isColor))
        lines.append("")
        lines.append("Color requirement: render the entire pose sheet in full color. Never make it monochrome, grayscale, ink-only, manga black-and-white, or sketch-only.")
        lines.append("Rules: ADULT character (not a child). Modest clothing. Plain white background. Match face/hair/build/outfit/style from the chosen reference image. Same person in ALL poses. Real legible Chinese characters.")
        return lines.joined(separator: "\n")
    }

    /// 用一张真人照片生成动漫风格的多视图角色立绘。
    /// 单个视图失败不影响其他视图；至少有一张成功就返回成功的部分。
    /// 返回 [(label, imageData)]，label 来自 specs。
    func generateCharacterViews(sourcePhoto: UIImage,
                                name: String,
                                bio: String?,
                                specs: [CharacterViewSpec],
                                style: MangaStyle,
                                isColor: Bool,
                                onStage: @MainActor @escaping (String) -> Void)
        async throws -> [(label: String, data: Data)]
    {
        guard currentBackendConfig() != nil else { throw OpenAIError.missingAPIKey }

        var results: [(label: String, data: Data)] = []
        var failures: [(label: String, message: String)] = []

        for (idx, spec) in specs.enumerated() {
            await onStage("正在生成「\(spec.label)」（\(idx+1)/\(specs.count)）…")

            let prompt = buildCharacterPrompt(name: name,
                                              bio: bio,
                                              spec: spec,
                                              style: style,
                                              isColor: isColor)
            do {
                let datas = try await submitImageTask(
                    images: [sourcePhoto],
                    prompt: prompt,
                    n: 1,
                    size: "1024x1536",
                    quality: "medium",
                    onStage: onStage
                )
                if let first = datas.first {
                    results.append((label: spec.label, data: first))
                }
            } catch {
                // 单个失败：记一下，继续下一个
                failures.append((spec.label, error.localizedDescription))
                await onStage("「\(spec.label)」失败，跳过继续生成下一张…")
            }
        }

        // 全失败 → 抛错（让上层标记 Job 为失败）
        if results.isEmpty {
            let summary = failures.map { "「\($0.label)」: \($0.message)" }
                                  .joined(separator: "\n")
            throw OpenAIError.unknown("全部 \(specs.count) 个视图都失败了：\n\(summary)")
        }
        return results
    }

    private func buildCharacterPrompt(name: String,
                                      bio: String?,
                                      spec: CharacterViewSpec,
                                      style: MangaStyle,
                                      isColor: Bool) -> String {
        var lines: [String] = []
        lines.append("Create a CHARACTER REFERENCE SHEET illustration of an anime/manga character.")
        lines.append("")
        lines.append("CHARACTER:")
        lines.append("- Name: \(name)")
        if let b = bio, !b.isEmpty { lines.append("- Background: \(b)") }
        lines.append("- The reference photo I provided shows the real-life appearance the character must be based on (face, hair color, build, age range). Stylize into manga/anime art while preserving identity (so the user can recognize themselves).")
        lines.append("")
        lines.append("VIEW TO RENDER (this image only):")
        lines.append(spec.prompt)
        lines.append("")
        lines.append("LAYOUT:")
        lines.append("- Plain neutral background (off-white or very light gray), no scenery, no extra props.")
        lines.append("- Character centered, full body visible from head to feet.")
        lines.append("- No text, no labels, no caption. Just the character on plain background.")
        lines.append("- Composition reads cleanly as a turnaround/character-sheet illustration.")
        lines.append("")
        lines.append("STYLE:")
        lines.append(style.effectivePrompt(isColor: isColor))
        return lines.joined(separator: "\n")
    }

    // MARK: 普通模式：照片 → 单张漫画

    func generateManga(_ request: OpenAIImageRequest,
                       jobId: UUID? = nil,
                       onStage: (@MainActor (String) -> Void)? = nil) async throws -> [Data] {
        JobStore.log(jobId, "开始生成漫画")
        JobStore.log(jobId, "用户图: \(request.inputImages.count) 张" +
            (request.previousPageImage != nil ? " · 含前一张参考" : "") +
            (request.characterReferenceImages.isEmpty ? "" : " · 含 \(request.characterReferenceImages.count) 个角色参考"),
            level: .detail)
        guard currentBackendConfig() != nil else {
            JobStore.log(jobId, "❌ 未配置后端地址或后端 API Key", level: .error)
            throw OpenAIError.missingAPIKey
        }
        guard !request.inputImages.isEmpty else {
            JobStore.log(jobId, "❌ 用户没传图片", level: .error)
            throw OpenAIError.invalidImage
        }
        JobStore.log(jobId, "已加载 VPS 后端配置", level: .detail)
        if request.n <= 1 {
            JobStore.log(jobId, "Prompt 已构造 (\(request.combinedPrompt.count) 字符)", level: .detail)

            // 顺序：前一张 → 用户照片 → 角色参考图
            var images: [UIImage] = []
            if let prev = request.previousPageImage { images.append(prev) }
            images.append(contentsOf: request.inputImages)
            images.append(contentsOf: request.characterReferenceImages)
            return try await submitImageTask(
                images: images,
                prompt: request.combinedPrompt,
                n: request.n,
                size: request.size,
                quality: request.quality,
                jobId: jobId,
                onStage: onStage
            )
        }

        JobStore.log(jobId, "进入多页连续生成模式：共 \(request.n) 页", level: .detail)
        var pages: [Data] = []
        var previousGeneratedPage: UIImage? = nil
        let pageInputGroups = request.groupedInputImagesForPages()

        for index in 0..<request.n {
            await onStage?("正在生成连续剧情第 \(index + 1)/\(request.n) 页…")
            let pageInputs = index < pageInputGroups.count ? pageInputGroups[index] : request.inputImages

            var images: [UIImage] = []
            if let previousGeneratedPage {
                images.append(previousGeneratedPage)
            } else if let prev = request.previousPageImage {
                images.append(prev)
            }
            images.append(contentsOf: pageInputs)
            images.append(contentsOf: request.characterReferenceImages)

            let prompt = request.promptForSequentialPage(
                index: index,
                total: request.n,
                pageImageCount: pageInputs.count,
                hasPreviousGeneratedPage: previousGeneratedPage != nil
            )
            JobStore.log(jobId, "第 \(index + 1) 页 Prompt 已构造 (\(prompt.count) 字符)", level: .detail)

            let datas = try await submitImageTask(
                images: images,
                prompt: prompt,
                n: 1,
                size: request.size,
                quality: request.quality,
                jobId: jobId,
                onStage: onStage
            )
            guard let first = datas.first else {
                throw OpenAIError.unknown("第 \(index + 1) 页未生成任何图像")
            }
            pages.append(first)
            previousGeneratedPage = UIImage(data: first)
        }

        return pages
    }

    // MARK: 故事模式：第 1 步 —— 只编剧本（不画）

    func generateStoryScriptOnly(_ request: OpenAIStoryRequest,
                                 jobId: UUID? = nil,
                                 onStage: @MainActor @escaping (String) -> Void)
        async throws -> MangaStoryScript
    {
        JobStore.log(jobId, "开始故事模式 第 1 步：编剧（\(request.scriptModel)）")
        JobStore.log(jobId, "用户图: \(request.inputImages.count) 张, 期望分镜: \(request.panelCount) 格", level: .detail)
        guard currentBackendConfig() != nil else {
            JobStore.log(jobId, "❌ 未配置后端地址或后端 API Key", level: .error)
            throw OpenAIError.missingAPIKey
        }
        guard !request.inputImages.isEmpty else { throw OpenAIError.invalidImage }
        JobStore.log(jobId, "已加载 VPS 后端配置", level: .detail)
        await onStage("AI 正在脑补剧情…")
        return try await withRetry(label: "AI 正在脑补剧情…",
                                   allowAutoRetry: true,    // 文本接口允许自动重试（不烧 GPU 配额）
                                   onRetry: onStage,
                                   jobId: jobId) {
            try await callBackendStoryScript(
                request,
                jobId: jobId,
                onStage: onStage
            )
        }
    }

    // MARK: 故事模式：第 2 步 —— 用（用户已编辑过的）剧本去画

    func renderStoryWithScript(_ request: OpenAIStoryRequest,
                               script: MangaStoryScript,
                               jobId: UUID? = nil,
                               onStage: @MainActor @escaping (String) -> Void)
        async throws -> [Data]
    {
        JobStore.log(jobId, "开始故事模式 第 2 步：分镜作画（\(script.panels.count) 格）")
        JobStore.log(jobId, "剧本标题: \(script.title)", level: .detail)
        guard currentBackendConfig() != nil else {
            JobStore.log(jobId, "❌ 未配置后端地址或后端 API Key", level: .error)
            throw OpenAIError.missingAPIKey
        }
        guard !request.inputImages.isEmpty else { throw OpenAIError.invalidImage }
        JobStore.log(jobId, "已加载 VPS 后端配置", level: .detail)

        await onStage("AI 正在分镜作画…（需要 1~3 分钟）")
        var renderPrompt = buildRenderPrompt(style: request.style,
                                             script: script,
                                             bubbleMode: request.bubbleTextMode,
                                             isColor: request.isColor,
                                             stylizationStrength: request.stylizationStrength,
                                             preserveRealWorldReadability: request.preserveRealWorldReadability)
        // 前一张图片：拼成第 1 张参考 + 在 prompt 里追加风格延续指令
        var images: [UIImage] = []
        if let prev = request.previousPageImage {
            images.append(prev)
            renderPrompt = BubbleDirective.continuityDirective + "\n\n" + renderPrompt
        }
        images.append(contentsOf: request.inputImages)
        images.append(contentsOf: request.characterReferenceImages)
        if let cd = request.characterDirective {
            renderPrompt += "\n\n" + cd
        }
        JobStore.log(jobId, "Prompt 已构造 (\(renderPrompt.count) 字符)", level: .detail)

        return try await submitImageTask(
            images: images,
            prompt: renderPrompt,
            n: 1,
            size: request.size,
            quality: request.quality,
            jobId: jobId,
            onStage: onStage
        )
    }

    // MARK: 故事模式：一次性两步（保留作为简便接口）

    /// 一次性返回剧本和漫画图。内部经历两步。
    func generateStory(_ request: OpenAIStoryRequest,
                       onStage: @MainActor @escaping (String) -> Void) async throws
        -> (script: MangaStoryScript, images: [Data])
    {
        let script = try await generateStoryScriptOnly(request, onStage: onStage)
        let images = try await renderStoryWithScript(request, script: script, onStage: onStage)
        return (script, images)
    }

    // MARK: ─────────────────────────────────────────────────────
    // MARK: 私有：第一步——让视觉模型把图变成剧本

    private func generateScript(apiKey: String,
                                images: [UIImage],
                                previousPage: UIImage? = nil,
                                characterImages: [UIImage] = [],
                                characterDirective: String? = nil,
                                style: MangaStyle,
                                userHint: String?,
                                panelCount: Int,
                                model: String,
                                jobId: UUID? = nil) async throws -> MangaStoryScript {

        // 构造 system + user 消息（含图）
        let system = """
        You are a creative Japanese manga screenwriter. You receive a few real-life photos \
        from the user. They may seem unrelated. Your job is to invent a short, compelling \
        manga story that connects them in unexpected, emotionally resonant, or dramatic ways.
        Output STRICT JSON only — no markdown, no commentary.
        """

        let hintLine: String = {
            if let h = userHint?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
                return "User's story hint: \"\(h)\""
            }
            return "User has no specific hint — feel free to invent."
        }()

        let userText = """
        Manga style: \(style.displayName) — \(style.subtitle)
        Style guide for tone: \(style.prompt)

        \(hintLine)

        \(characterDirective ?? "")

        Design a \(panelCount)-panel manga page. You are NOT required to use one panel per \
        input photo — invent extra panels if useful: establishing shots, emotion close-ups, \
        transition panels, dramatic splash panels, flashbacks, etc. Aim for a beginning, \
        middle, and end.

        For each piece of dialogue/narration, ALWAYS provide BOTH a Simplified Chinese \
        version (for the user to read) AND a short Japanese-kana version (used to render \
        inside speech bubbles, because the image model handles kana more reliably than \
        Chinese). Keep the Japanese version short (≤ 8 kana per bubble), naturally \
        translated, like real shonen manga dialogue.

        Return ONLY this JSON object (no extra text, no markdown):
        {
          "title":    "<2~6字 中文标题>",
          "synopsis": "<一两句中文剧情简介>",
          "panels": [
            {
              "description":  "<English visual description: camera angle, action, mood>",
              "dialogue":     "<角色名：中文台词>          // null if none>",
              "dialogueJa":   "<corresponding short Japanese kana, e.g. 「行くぞ！」  // null if none>",
              "narration":    "<中文旁白                     // null if none>",
              "narrationJa":  "<short Japanese-kana narration  // null if none>",
              "sfx":          "<拟声词 e.g. ドン! バン! ガタン!  // null if none>"
            }
            // ...共 \(panelCount) 个 panel
          ]
        }

        IMPORTANT: every panel MUST exist; use null (not empty string) when there is no \
        dialogue/narration/sfx. Do not output anything except the JSON.
        """

        // 把图片打包成 base64 data url
        var contentArray: [[String: Any]] = [
            ["type": "text", "text": userText]
        ]

        // 视觉模型对图片体积更敏感（base64 大小再 × 1.33），目标 250KB
        // 前一张漫画页（如果有）放最前面 + 加一段文字标签
        if let prev = previousPage {
            if let data = prev.compressForUpload(targetKB: 250, startMaxDimension: 768) {
                let dataURL = "data:image/jpeg;base64," + data.base64EncodedString()
                contentArray.append([
                    "type": "text",
                    "text": "↑ The image BELOW is the PREVIOUS manga page in this story. The new page must continue smoothly from it — same characters, same art style, same world. The remaining images after that are new real-life photos the user wants you to weave into the next page."
                ])
                contentArray.append([
                    "type": "image_url",
                    "image_url": ["url": dataURL]
                ])
            }
        }

        for img in images {
            guard let data = img.compressForUpload(targetKB: 250, startMaxDimension: 768)
            else { throw OpenAIError.invalidImage }
            let dataURL = "data:image/jpeg;base64," + data.base64EncodedString()
            contentArray.append([
                "type": "image_url",
                "image_url": ["url": dataURL]
            ])
        }

        if !characterImages.isEmpty {
            contentArray.append([
                "type": "text",
                "text": "The following image(s) are recurring CHARACTER REFERENCES. Keep these exact people/character designs consistent when writing the page."
            ])
        }
        for img in characterImages {
            guard let data = img.compressForUpload(targetKB: 250, startMaxDimension: 768)
            else { throw OpenAIError.invalidImage }
            let dataURL = "data:image/jpeg;base64," + data.base64EncodedString()
            contentArray.append([
                "type": "image_url",
                "image_url": ["url": dataURL]
            ])
        }

        // GPT-5 系列把 max_tokens 改成了 max_completion_tokens
        // 而且推理 token 也算在内，所以放宽到 4000
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": contentArray]
            ],
            "response_format": ["type": "json_object"],
            "max_completion_tokens": 4000
        ]

        var req = URLRequest(url: chatCompletions)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120

        // 走后台 URLSession，锁屏也不会断
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        JobStore.log(jobId, "编剧请求 body \(bodyData.count / 1024) KB", level: .detail)
        let (data, response) = try await BackgroundTaskRunner.shared.upload(req, body: bodyData, jobId: jobId)
        guard let http = response as? HTTPURLResponse else {
            JobStore.log(jobId, "响应类型异常（非 HTTP）", level: .error)
            throw OpenAIError.unknown("Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let s = String(data: data, encoding: .utf8) ?? "<binary>"
            throw OpenAIError.requestFailed(status: http.statusCode, body: s)
        }

        struct ChatResp: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String }
                let message: Msg
            }
            let choices: [Choice]
        }
        guard let resp = try? JSONDecoder().decode(ChatResp.self, from: data),
              let raw = resp.choices.first?.message.content else {
            throw OpenAIError.decodingFailed
        }
        // raw 应该是 JSON 字符串
        guard let rawData = raw.data(using: .utf8),
              let script = try? JSONDecoder().decode(MangaStoryScript.self, from: rawData)
        else {
            // 返回的不是合法 JSON，丢出原文方便调试
            throw OpenAIError.unknown("剧本解析失败：\n" + raw.prefix(400))
        }
        return script
    }

    /// 把剧本拼成给绘图模型的详细 prompt
    private func buildRenderPrompt(style: MangaStyle,
                                   script: MangaStoryScript,
                                   bubbleMode: String,
                                   isColor: Bool,
                                   stylizationStrength: Double = 0.78,
                                   preserveRealWorldReadability: Bool = false) -> String {

        func clean(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty, s.lowercased() != "null" else { return nil }
            return s
        }

        var lines: [String] = []
        lines.append("Create a SINGLE full Japanese manga page in this style:")
        lines.append(style.effectivePrompt(isColor: isColor,
                                           stylizationStrength: stylizationStrength,
                                           preserveRealWorldReadability: preserveRealWorldReadability))
        lines.append("")
        lines.append("Layout: arrange \(script.panels.count) panels in a classic manga grid with clear \(isColor ? "" : "black ")gutters between panels. Vary panel sizes for dramatic effect (e.g., one larger splash panel). Use the provided reference photos to keep characters and locations visually consistent.")
        lines.append("")

        // 标题文字策略
        switch bubbleMode {
        case "none", "empty":
            lines.append("MANGA TITLE (for your understanding only, do NOT render any title text on the page): \(script.title)")
        case "chinese":
            lines.append("MANGA TITLE (render this Chinese title large at the top in stylized brush calligraphy): \(script.title)")
        case "english":
            lines.append("MANGA TITLE (render an English version of this title large at the top in stylized lettering — translate the Chinese title naturally): \(script.title)")
        default: // japanese
            lines.append("MANGA TITLE (for your understanding only, do NOT render any title text on the page): \(script.title)")
        }
        lines.append("SYNOPSIS (for your understanding only, do not render): \(script.synopsis)")
        lines.append("")
        lines.append("PANELS (read top-to-bottom):")

        for (i, p) in script.panels.enumerated() {
            lines.append("")
            lines.append("Panel \(i+1):")
            lines.append("  Visual: \(p.description)")

            let zhDialogue   = clean(p.dialogue)
            let jaDialogue   = clean(p.dialogueJa)
            let zhNarration  = clean(p.narration)
            let jaNarration  = clean(p.narrationJa)
            let sfx          = clean(p.sfx)

            switch bubbleMode {

            case "none":
                // 完全不画对话框
                break

            case "empty":
                if zhDialogue != nil {
                    lines.append("  Draw a clean empty speech bubble (oval with tail pointing to the speaker). Leave it COMPLETELY EMPTY — do NOT put any text inside.")
                }
                if zhNarration != nil {
                    lines.append("  Draw a clean empty rectangular caption box at the top/corner of the panel. Leave it COMPLETELY EMPTY.")
                }

            case "chinese":
                if let d = zhDialogue {
                    lines.append("  Speech bubble — render this Chinese text VERBATIM, large and clearly readable: 「\(d)」")
                }
                if let n = zhNarration {
                    lines.append("  Narration caption box — render this Chinese text VERBATIM: 「\(n)」")
                }

            case "english":
                if let d = zhDialogue {
                    lines.append("  Speech bubble — render a natural English translation of this Chinese line, short and clearly readable (≤ 12 words): \(d)")
                }
                if let n = zhNarration {
                    lines.append("  Narration caption box — render a natural English translation of this Chinese narration: \(n)")
                }

            default: // "japanese": 气泡里画日语
                if let ja = jaDialogue {
                    lines.append("  Speech bubble — render this Japanese text VERBATIM, large and clearly readable: 「\(ja)」")
                } else if let zh = zhDialogue {
                    // 用户改了中文但没同步日文，让模型现场翻译
                    lines.append("  Speech bubble — render a natural short Japanese translation of this Chinese line, using normal Japanese writing with kanji and kana as appropriate: \(zh)")
                }
                if let ja = jaNarration {
                    lines.append("  Narration caption box — render this Japanese text VERBATIM: 「\(ja)」")
                } else if let zh = zhNarration {
                    lines.append("  Narration caption box — render a natural short Japanese translation of this Chinese line: \(zh)")
                }
            }

            if let s = sfx {
                lines.append("  Stylized sound effect lettering integrated into the art (use Japanese katakana exactly as written, large and dramatic): \(s)")
            }
        }

        lines.append("")
        lines.append("RENDERING RULES:")
        if isColor {
            lines.append("- FULL COLOR rendering with vivid harmonious manga/anime palette. Strong ink linework + cel-shaded coloring + atmospheric lighting.")
        } else {
            lines.append("- Pure black-and-white ink, no color whatsoever.")
        }
        switch bubbleMode {
        case "none":
            lines.append("- DO NOT draw ANY speech bubbles or caption boxes anywhere on the page. Pure visual storytelling. Sound-effect lettering integrated into the artwork is the ONLY allowed text.")
        case "empty":
            lines.append("- DO NOT render ANY readable text inside bubbles or caption boxes (must remain completely empty). Sound effects (拟声词 katakana) are the ONLY allowed text.")
        case "chinese":
            lines.append("- All Chinese dialogue/narration text MUST be reproduced VERBATIM, large enough that every stroke is crisp and readable. Use a brush-style display font for impact. Do NOT use English or Japanese.")
        case "english":
            lines.append("- All bubble/caption text must be in clean readable English. Do NOT use Chinese or Japanese in bubbles.")
        default: // japanese
            lines.append("- Render Japanese text in bubbles VERBATIM, large and crisp, using normal Japanese writing with kanji and kana where appropriate. Do not invent additional Chinese or English text.")
        }
        lines.append("- Sound effects: large dramatic stylized lettering integrated into the artwork.")
        lines.append("- Maintain visual consistency of any recurring character/location across panels.")
        lines.append("- Page composition should feel like a real Weekly Shonen Jump / seinen manga page.")
        return lines.joined(separator: "\n")
    }

    private func submitImageTask(images: [UIImage],
                                 prompt: String,
                                 n: Int,
                                 size: String,
                                 quality: String,
                                 jobId: UUID? = nil,
                                 onStage: (@MainActor (String) -> Void)? = nil) async throws -> [Data] {
        guard let config = currentBackendConfig() else { throw OpenAIError.missingAPIKey }

        final class SubmissionBox {
            var taskId: String?
        }
        let box = SubmissionBox()

        return try await withTaskCancellationHandler {
            let files = try images.enumerated().map { idx, image in
                guard let data = image.compressForUpload(targetKB: 500, startMaxDimension: 1024) else {
                    throw OpenAIError.invalidImage
                }
                return (field: "images", filename: "input_\(idx).jpg", mime: "image/jpeg", data: data)
            }
            let fields = [
                ("prompt", prompt),
                ("n", String(max(1, min(n, 4)))),
                ("size", size),
                ("quality", quality)
            ]
            let (request, body) = try makeMultipartRequest(
                config: config,
                path: "/api/tasks",
                fields: fields,
                files: files
            )
            let (data, response) = try await BackgroundTaskRunner.shared.upload(request, body: body, jobId: jobId)
            guard let http = response as? HTTPURLResponse else {
                throw OpenAIError.unknown("Invalid backend response")
            }
            if http.statusCode == 409 {
                let message = String(data: data, encoding: .utf8) ?? "duplicate_request"
                throw OpenAIError.unknown("服务器检测到短时间内重复提交，已拦截本次请求。\n\n\(message)")
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyString = String(data: data, encoding: .utf8) ?? "<binary>"
                throw OpenAIError.requestFailed(status: http.statusCode, body: bodyString)
            }
            let submission = try decodeJSON(BackendTaskSubmission.self, from: data)
            box.taskId = submission.task_id
            if let jobId {
                await MainActor.run {
                    JobStore.shared.updateBackendTaskId(jobId, submission.task_id)
                    JobStore.shared.updateStage(jobId, "素材已上传，服务器开始排队…")
                }
            }
            return try await pollBackendTaskResults(jobId: jobId,
                                                    backendTaskId: submission.task_id,
                                                    stageLabel: "服务器正在生成图片…",
                                                    onStage: onStage)
        } onCancel: {
            guard let taskId = box.taskId,
                  let config = self.currentBackendConfig() else { return }
            Task { try? await self.cancelBackendTask(taskId: taskId, config: config) }
        }
    }

    private func callBackendStoryScript(_ request: OpenAIStoryRequest,
                                        jobId: UUID? = nil,
                                        onStage: @MainActor @escaping (String) -> Void) async throws -> MangaStoryScript {
        guard let config = currentBackendConfig() else { throw OpenAIError.missingAPIKey }

        var files: [(field: String, filename: String, mime: String, data: Data)] = []
        if let previous = request.previousPageImage {
            guard let data = previous.compressForUpload(targetKB: 500, startMaxDimension: 1024) else {
                throw OpenAIError.invalidImage
            }
            files.append((field: "previousPage", filename: "previous.jpg", mime: "image/jpeg", data: data))
        }
        for (idx, image) in request.inputImages.enumerated() {
            guard let data = image.compressForUpload(targetKB: 500, startMaxDimension: 1024) else {
                throw OpenAIError.invalidImage
            }
            files.append((field: "images", filename: "image_\(idx).jpg", mime: "image/jpeg", data: data))
        }
        for (idx, image) in request.characterReferenceImages.enumerated() {
            guard let data = image.compressForUpload(targetKB: 500, startMaxDimension: 1024) else {
                throw OpenAIError.invalidImage
            }
            files.append((field: "characterImages", filename: "character_\(idx).jpg", mime: "image/jpeg", data: data))
        }

        let fields = [
            ("styleDisplayName", request.style.displayName),
            ("styleSubtitle", request.style.subtitle),
            ("stylePrompt", request.style.prompt),
            ("userHint", request.userHint ?? ""),
            ("panelCount", String(request.panelCount)),
            ("model", request.scriptModel),
            ("characterDirective", request.characterDirective ?? "")
        ]
        let (req, body) = try makeMultipartRequest(
            config: config,
            path: "/api/story-script",
            fields: fields,
            files: files
        )
        let (data, response) = try await BackgroundTaskRunner.shared.upload(req, body: body, jobId: jobId)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.unknown("Invalid backend response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<binary>"
            throw OpenAIError.requestFailed(status: http.statusCode, body: bodyString)
        }
        let result = try decodeJSON(BackendStoryScriptResponse.self, from: data)
        await onStage("剧情已经构思完成，等待你确认分镜…")
        return result.script
    }

    private func pollBackendTaskResults(jobId: UUID?,
                                        backendTaskId: String,
                                        stageLabel: String,
                                        onStage: (@MainActor (String) -> Void)? = nil) async throws -> [Data] {
        let status = try await resumeBackendTask(jobId: jobId,
                                                 backendTaskId: backendTaskId,
                                                 stageLabel: stageLabel,
                                                 onStage: onStage,
                                                 finalize: false)
        return try await downloadBackendOutputs(taskId: backendTaskId,
                                                outputCount: max(status.output_count ?? 1, 1))
    }

    @discardableResult
    private func resumeBackendTask(jobId: UUID?,
                                   backendTaskId: String,
                                   stageLabel: String,
                                   onStage: (@MainActor (String) -> Void)? = nil,
                                   finalize: Bool = true) async throws -> BackendTaskStatus {
        while true {
            try Task.checkCancellation()
            let status = try await fetchBackendTaskStatus(taskId: backendTaskId)
            switch status.status {
            case "pending":
                if let onStage { await onStage("服务器已收到请求，等待排队…") }
                if let jobId { await MainActor.run { JobStore.shared.updateStage(jobId, "服务器已收到请求，等待排队…") } }
            case "openai_processing":
                if let onStage { await onStage(stageLabel) }
                if let jobId { await MainActor.run { JobStore.shared.updateStage(jobId, stageLabel) } }
            case "completed":
                if finalize, let jobId {
                    let outputs = try await downloadBackendOutputs(taskId: backendTaskId,
                                                                   outputCount: max(status.output_count ?? 1, 1))
                    await finalizeServerBackedJob(jobId: jobId, outputs: outputs)
                }
                return status
            case "failed":
                throw OpenAIError.unknown(status.error_message ?? "服务器任务失败")
            case "timeout_unknown":
                throw OpenAIError.unknown(status.error_message ?? "服务器与 OpenAI 通信超时，结果未知。")
            case "cancelled", "cancel_requested":
                throw CancellationError()
            default:
                throw OpenAIError.unknown("服务器返回未知任务状态：\(status.status)")
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    @MainActor
    private func finalizeServerBackedJob(jobId: UUID, outputs: [Data]) {
        guard let job = JobStore.shared.jobs.first(where: { $0.id == jobId }) else { return }
        guard !job.phase.isFinal else { return }

        switch job.kind {
        case .simpleImage, .storyRender:
            guard let inputFiles = job.inputImageFiles else {
                JobStore.shared.markTimeoutUnknown(jobId,
                                                   message: "服务器任务已完成，但本地输入图快照已缺失，无法自动写入历史。",
                                                   errorCode: "SERVER_RECOVERY_INPUT_MISSING")
                return
            }
            let inputDatas = inputFiles.compactMap {
                JobStore.shared.loadPendingImage($0, jobId: job.id)?.pngData()
            }
            guard !inputDatas.isEmpty else {
                JobStore.shared.markTimeoutUnknown(jobId,
                                                   message: "服务器任务已完成，但本地输入图快照已缺失，无法自动写入历史。",
                                                   errorCode: "SERVER_RECOVERY_INPUT_MISSING")
                return
            }
            let projectId = job.projectId ?? ProjectStore.shared.ensureDefaultProject().id
            let saved = MangaStorage.shared.add(
                projectId: projectId,
                style: job.style,
                inputs: inputDatas,
                outputs: outputs,
                userPrompt: job.userPromptText,
                storyScript: job.storyScriptSnapshot,
                previousPage: job.previousPageFile.flatMap {
                    JobStore.shared.loadPendingImage($0, jobId: job.id)?.pngData()
                },
                loadedCharacterIds: job.characterIds,
                loadedCharacterSelections: job.characterSelections,
                bubbleTextMode: job.bubbleMode,
                isColorOutput: job.wasColorOn,
                imageCount: job.imageCount,
                imageSize: job.imageSizeStr,
                imageQuality: job.imageQualityStr
            )
            JobStore.shared.complete(job.id, with: saved.id)
        case .characterViews:
            guard let first = outputs.first,
                  let characterId = job.characterId,
                  let label = job.outputLabel ?? job.artStyle?.displayName else {
                JobStore.shared.markTimeoutUnknown(jobId,
                                                   message: "服务器任务已完成，但角色回写信息不完整。",
                                                   errorCode: "SERVER_RECOVERY_CHARACTER_MISSING")
                return
            }
            CharacterStore.shared.addViews(to: characterId, views: [(label, first)])
            JobStore.shared.complete(job.id, with: characterId)
        case .storyScript:
            JobStore.shared.markTimeoutUnknown(jobId,
                                               message: "编剧任务已在服务器完成，但当前版本不会自动恢复编辑界面。",
                                               errorCode: "SERVER_RECOVERY_UNSUPPORTED")
        }
    }

    private func fetchBackendTaskStatus(taskId: String) async throws -> BackendTaskStatus {
        let config = try requireBackendConfig()
        let req = try makeBackendRequest(config: config, path: "/api/tasks/\(taskId)")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.unknown("Invalid backend response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<binary>"
            throw OpenAIError.requestFailed(status: http.statusCode, body: bodyString)
        }
        return try decodeJSON(BackendTaskStatus.self, from: data)
    }

    private func downloadBackendOutputs(taskId: String, outputCount: Int) async throws -> [Data] {
        let config = try requireBackendConfig()
        var outputs: [Data] = []
        for index in 0..<outputCount {
            let req = try makeBackendRequest(config: config,
                                             path: "/api/tasks/\(taskId)/result?index=\(index)")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw OpenAIError.unknown("Invalid backend response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyString = String(data: data, encoding: .utf8) ?? "<binary>"
                throw OpenAIError.requestFailed(status: http.statusCode, body: bodyString)
            }
            outputs.append(data)
        }
        return outputs
    }

    private func cancelBackendTask(taskId: String, config: BackendConfig) async throws {
        var req = try makeBackendRequest(config: config,
                                         path: "/api/tasks/\(taskId)/cancel",
                                         method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        _ = try await URLSession.shared.data(for: req)
    }

    private func makeMultipartRequest(
        config: BackendConfig,
        path: String,
        fields: [(String, String)],
        files: [(field: String, filename: String, mime: String, data: Data)]
    ) throws -> (URLRequest, Data) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        for (name, value) in fields {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        for file in files {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.filename)\"\r\n")
            body.appendString("Content-Type: \(file.mime)\r\n\r\n")
            body.append(file.data)
            body.appendString("\r\n")
        }

        body.appendString("--\(boundary)--\r\n")

        var req = try makeBackendRequest(config: config, path: path, method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return (req, body)
    }

    private func makeBackendRequest(config: BackendConfig,
                                    path: String,
                                    method: String = "GET") throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: config.baseURL)?.absoluteURL else {
            throw OpenAIError.unknown("后端地址无效：\(config.baseURL.absoluteString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 120
        return req
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OpenAIError.unknown("后端返回解析失败：\(error.localizedDescription)")
        }
    }

    private func requireBackendConfig() throws -> BackendConfig {
        guard let config = currentBackendConfig() else {
            throw OpenAIError.missingAPIKey
        }
        return config
    }

    private func currentBackendConfig() -> BackendConfig? {
        let rawURL = UserDefaults.standard.string(forKey: AppSettings.backendBaseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (rawURL?.isEmpty == false ? rawURL! : "https://manga.areu.pro")
        guard let key = KeychainService.shared.loadBackendAPIKey(),
              !key.isEmpty,
              let url = URL(string: base) else {
            return nil
        }
        return BackendConfig(baseURL: url, apiKey: key)
    }

    // MARK: ─────────────────────────────────────────────────────
    // MARK: 私有：调 images/edits 通用方法

    private func callImagesEdit(apiKey: String,
                                images: [UIImage],
                                prompt: String,
                                n: Int,
                                size: String,
                                quality: String,
                                jobId: UUID? = nil) async throws -> [Data] {
        JobStore.log(jobId, "构造 multipart 请求 · model=\(imageModel) · size=\(size) · quality=\(quality) · n=\(n)", level: .detail)
        // 提前压缩一遍，日志列出每张实际大小
        var perImageKB: [Int] = []
        for img in images {
            if let d = img.compressForUpload(targetKB: 500, startMaxDimension: 1024) {
                perImageKB.append(d.count / 1024)
            }
        }
        let totalKB = perImageKB.reduce(0, +)
        let perStr = perImageKB.map { "\($0)KB" }.joined(separator: ", ")
        JobStore.log(jobId,
            "压缩 \(images.count) 张参考图 (目标 ≤500KB/张): [\(perStr)] · 总计 \(totalKB) KB",
            level: .detail)

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        func appendImage(_ idx: Int, _ image: UIImage) throws {
            // 智能压缩到 ≤ 500KB JPEG，先降质量再降尺寸
            // 之前 PNG + Retina scale 会出现 27MB 的 body，OpenAI 后端反复超时
            guard let data = image.compressForUpload(targetKB: 500, startMaxDimension: 1024)
            else { throw OpenAIError.invalidImage }
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"image[]\"; filename=\"input_\(idx).jpg\"\r\n")
            body.appendString("Content-Type: image/jpeg\r\n\r\n")
            body.append(data)
            body.appendString("\r\n")
        }

        appendField("model",   imageModel)
        appendField("prompt",  prompt)
        appendField("n",       String(max(1, min(n, 10))))
        appendField("size",    size)
        appendField("quality", quality)
        for (i, img) in images.enumerated() {
            try appendImage(i, img)
        }
        body.appendString("--\(boundary)--\r\n")

        var req = URLRequest(url: imagesEdit)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 240

        JobStore.log(jobId, "Body 总计 \(body.count / 1024) KB，发送中…", level: .detail)

        // 走后台 URLSession：锁屏 / 切应用都不会中断
        let (data, response) = try await BackgroundTaskRunner.shared.upload(req, body: body, jobId: jobId)
        guard let http = response as? HTTPURLResponse else {
            JobStore.log(jobId, "响应类型异常（非 HTTP）", level: .error)
            throw OpenAIError.unknown("Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let s = String(data: data, encoding: .utf8) ?? "<binary>"
            throw OpenAIError.requestFailed(status: http.statusCode, body: s)
        }

        struct Resp: Decodable {
            struct Item: Decodable { let b64_json: String?; let url: String? }
            let data: [Item]
        }
        guard let resp = try? JSONDecoder().decode(Resp.self, from: data) else {
            throw OpenAIError.decodingFailed
        }
        var results: [Data] = []
        for item in resp.data {
            if let b64 = item.b64_json, let imgData = Data(base64Encoded: b64) {
                results.append(imgData)
            } else if let urlStr = item.url, let url = URL(string: urlStr) {
                let (d, _) = try await URLSession.shared.data(from: url)
                results.append(d)
            }
        }
        if results.isEmpty { throw OpenAIError.decodingFailed }
        return results
    }

    // MARK: 工具

    private func currentKey() -> String? {
        let k = KeychainService.shared.loadAPIKey()
        return (k?.isEmpty == false) ? k : nil
    }
}

// MARK: - 小工具

private extension Data {
    mutating func appendString(_ s: String) {
        if let d = s.data(using: .utf8) { append(d) }
    }
}

private extension UIImage {
    /// 把图片缩到 maxDimension（按长边）。**强制 scale=1.0**：
    /// 否则在 Retina 设备上 UIGraphics 默认按设备倍率渲染，
    /// 1024 点会变成 1024×deviceScale 像素 → PNG 体积爆炸到几十 MB。
    func resizedForUpload(maxDimension: CGFloat) -> UIImage {
        let w = size.width, h = size.height
        let m = max(w, h)
        guard m > maxDimension else { return self }
        let s = maxDimension / m
        let newSize = CGSize(width: w * s, height: h * s)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0   // 1 point = 1 pixel
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// 智能压缩到 ≤ targetKB 的 JPEG。
    /// 策略：先降质量（0.85 → 0.4），还不行再降尺寸（× 0.85），最多迭代 6 轮。
    /// 兜底返回最后一次结果，最坏情况 ≈ 200KB 以内。
    func compressForUpload(targetKB: Int = 500,
                          startMaxDimension: CGFloat = 1024) -> Data? {
        let targetBytes = targetKB * 1024
        var dim = startMaxDimension
        var quality: CGFloat = 0.85

        for _ in 0..<6 {
            let resized = resizedForUpload(maxDimension: dim)
            guard let data = resized.jpegData(compressionQuality: quality) else { return nil }
            if data.count <= targetBytes {
                return data
            }
            // 还超：先降质量到 0.4，再降尺寸
            if quality > 0.45 {
                quality -= 0.15
            } else {
                dim *= 0.85
                quality = 0.7
            }
        }
        // 兜底：保底再来一次
        let resized = resizedForUpload(maxDimension: dim)
        return resized.jpegData(compressionQuality: max(0.3, quality))
    }
}
