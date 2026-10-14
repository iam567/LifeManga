//
//  MangaGeneratorViewModel.swift
//  LifeManga
//
//  状态机：
//      .idle  →  .generatingScript  →  .scriptReady  →  .generatingImage  →  .done
//
//  普通模式跳过 .scriptReady，直接 .idle → .generatingImage → .done
//

import Foundation
import SwiftUI
import UIKit
import CoreLocation

enum NavigationGuideStrength: String, CaseIterable, Identifiable {
    case light
    case balanced
    case strong

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "轻导览"
        case .balanced: return "标准"
        case .strong: return "强指引"
        }
    }

    var promptCue: String {
        switch self {
        case .light:
            return "Lean more toward a charming travel-note comic with gentle guidance."
        case .balanced:
            return "Balance route clarity with visual charm and readable landmark guidance."
        case .strong:
            return "Make this an explicit route manual with strong arrows, clear numbered steps, and unmistakable wayfinding."
        }
    }
}

struct SelectedImageInput: Identifiable, Equatable {
    let id: UUID = UUID()
    let image: UIImage
    let diaryStamp: DiaryStamp?
}

enum GenerationPhase: Equatable {
    case idle
    case generatingScript
    case scriptReady
    case generatingImage
    case done
}

@MainActor
final class MangaGeneratorViewModel: ObservableObject {

    static func maxInputImageCount(forPageCount pageCount: Int) -> Int {
        max(6, max(1, pageCount) * 6)
    }

    /// 当前所属工程
    var projectId: UUID
    /// 工程名（仅用来发通知文案）
    var projectName: String
    let projectMode: ProjectMode
    private var drivingTask: Task<Void, Never>?

    init(projectId: UUID, projectName: String = "", projectMode: ProjectMode = .comicLife) {
        self.projectId = projectId
        self.projectName = projectName
        self.projectMode = projectMode
        if projectMode == .navigationGuide {
            self.style = .navigationGuide
            self.bubbleTextMode = "chinese"
            self.isColor = true
        }
    }

    // 用户选择的输入图
    @Published var selectedInputs: [SelectedImageInput] = []
    // "前一张" 漫画图（用于风格延续）—— 可来自历史，也可外部上传
    @Published var previousPageImage: UIImage?
    /// 关联的来源 MangaItem（如果是从历史里选的）
    @Published var previousPageSourceId: UUID?
    // 载入的角色（来自角色库）—— 角色立绘会作为参考图随请求一起发
    @Published var loadedCharacters: [Character] = []
    @Published var selectedCharacterReferenceViewIDs: [UUID: UUID] = [:]
    // 当前风格
    @Published var style: MangaStyle = .shonenJump
    // 用户额外补充的描述
    @Published var userPrompt: String = ""
    @Published var navigationStart: String = ""
    @Published var navigationDestination: String = ""
    @Published var navigationWaypoints: String = ""
    @Published var navigationStrength: NavigationGuideStrength = .balanced
    // 故事模式开关
    @Published var storyMode: Bool = false
    // 故事模式分镜数
    @Published var panelCount: Int = 6
    // 彩色 / 黑白
    @Published var isColor: Bool = false
    // 气泡里文字 "chinese" / "japanese" / "english" / "empty" / "none"
    @Published var bubbleTextMode: String = "chinese"

    // 状态
    @Published var phase: GenerationPhase = .idle
    @Published var stageMessage: String = ""

    // 生成结果
    @Published var generatedImages: [UIImage] = []
    /// 当前剧本（可被用户编辑后再用于绘画）
    @Published var generatedScript: MangaStoryScript?

    // UI
    @Published var errorMessage: String?
    @Published var errorIsSafetyBlocked: Bool = false
    @Published var lastSaved: MangaItem?
    @Published var toastMessage: String?

    var selectedImages: [UIImage] { selectedInputs.map(\.image) }
    var activeDiaryStamp: DiaryStamp? { selectedInputs.compactMap(\.diaryStamp).first }
    var fallbackDiaryStamp: DiaryStamp {
        DiaryStamp(capturedAt: Date(), weatherText: nil)
    }

    var isGenerating: Bool {
        phase == .generatingScript || phase == .generatingImage
    }

    var isBlockingGenerate: Bool {
        phase == .generatingScript || (storyMode && phase == .generatingImage)
    }

    // MARK: - 操作

    @discardableResult
    func addImage(_ img: UIImage, diaryStamp: DiaryStamp? = nil, maxCount: Int = .max) -> Bool {
        guard selectedInputs.count < maxCount else { return false }
        selectedInputs.append(SelectedImageInput(image: img, diaryStamp: diaryStamp))
        return true
    }

    func removeImage(at index: Int) {
        guard selectedInputs.indices.contains(index) else { return }
        selectedInputs.remove(at: index)
    }

    func moveSelectedInput(id: UUID, before targetID: UUID) {
        guard id != targetID,
              let fromIndex = selectedInputs.firstIndex(where: { $0.id == id }),
              let targetIndex = selectedInputs.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        let item = selectedInputs.remove(at: fromIndex)
        let adjustedTarget = fromIndex < targetIndex ? max(0, targetIndex - 1) : targetIndex
        selectedInputs.insert(item, at: adjustedTarget)
    }

    func moveSelectedInputToEnd(id: UUID) {
        guard let fromIndex = selectedInputs.firstIndex(where: { $0.id == id }) else { return }
        let item = selectedInputs.remove(at: fromIndex)
        selectedInputs.append(item)
    }

    func reset() {
        selectedInputs = []
        previousPageImage = nil
        previousPageSourceId = nil
        loadedCharacters = []
        selectedCharacterReferenceViewIDs = [:]
        userPrompt = ""
        navigationStart = ""
        navigationDestination = ""
        navigationWaypoints = ""
        navigationStrength = .balanced
        generatedImages = []
        generatedScript = nil
        stageMessage = ""
        lastSaved = nil
        toastMessage = nil
        phase = .idle
    }

    func clearPreviousPage() {
        previousPageImage = nil
        previousPageSourceId = nil
    }

    func loadCharacter(_ c: Character, referenceViewID: UUID? = nil) {
        if !loadedCharacters.contains(where: { $0.id == c.id }) {
            loadedCharacters.append(c)
        }
        if let referenceViewID {
            selectedCharacterReferenceViewIDs[c.id] = referenceViewID
        } else if selectedCharacterReferenceViewIDs[c.id] == nil,
                  let defaultViewID = c.referencePortraitView?.id ?? c.preferredCoverView?.id {
            selectedCharacterReferenceViewIDs[c.id] = defaultViewID
        }
    }

    func unloadCharacter(_ c: Character) {
        loadedCharacters.removeAll { $0.id == c.id }
        selectedCharacterReferenceViewIDs.removeValue(forKey: c.id)
    }

    func selectedReferenceView(for character: Character) -> CharacterView? {
        if let selectedID = selectedCharacterReferenceViewIDs[character.id],
           let view = character.views.first(where: { $0.id == selectedID }) {
            return view
        }
        return character.referencePortraitView ?? character.preferredCoverView
    }

    func setSelectedReferenceView(_ view: CharacterView, for character: Character) {
        selectedCharacterReferenceViewIDs[character.id] = view.id
        if !loadedCharacters.contains(where: { $0.id == character.id }) {
            loadedCharacters.append(character)
        }
    }

    func selectedCharacterSelectionsSnapshot() -> [CharacterReferenceSelection] {
        loadedCharacters.map { character in
            CharacterReferenceSelection(characterId: character.id,
                                        viewId: selectedReferenceView(for: character)?.id)
        }
    }

    /// 把所有载入角色的标准立绘（没有就退而求其次取第一张）作为参考图
    func characterReferenceImages() -> [UIImage] {
        var imgs: [UIImage] = []
        for c in loadedCharacters {
            let view = selectedReferenceView(for: c)
            if let n = view?.imageName, let ui = CharacterStore.shared.image(named: n) {
                imgs.append(ui)
            } else if let n = c.sourcePhotoName,
                      let ui = CharacterStore.shared.image(named: n) {
                imgs.append(ui)
            }
        }
        return imgs
    }

    func charactersDirective() -> String? {
        guard !loadedCharacters.isEmpty else { return nil }
        let names = loadedCharacters.map { $0.name }.joined(separator: "、")
        return """
        CHARACTER REFERENCE:
        I have attached \(loadedCharacters.count) character reference image(s) at the end of \
        the input set. These represent the recurring characters that should appear in this \
        page (\(names)). Match their faces, hair, outfits and overall design EXACTLY as shown. \
        Do not redesign them.

        IMPORTANT REFERENCE-USE RULE:
        Use ONLY the main standing character figure from each reference as the canonical design. \
        Ignore any side expression heads, accessory callouts, prop layouts, object boards, arrows, \
        labels, multi-panel sheet layout, background decorations, or extra design-sheet elements \
        that may appear around the character in a character sheet. Those surrounding helper elements \
        are reference aids only and must NOT be copied into the manga unless the user explicitly \
        asked for that object or prop in the scene.
        """
    }

    /// 抛弃当前剧本，回到空闲态（用于"重新构思剧情"的入口前）
    func discardScript() {
        generatedScript = nil
        phase = .idle
    }

    func startGenerate(settings: AppSettings) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.generate(settings: settings)
            await MainActor.run {
                self.drivingTask = nil
            }
        }
        drivingTask = task
    }

    func startRegenerateScript(settings: AppSettings) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.regenerateScript(settings: settings)
            await MainActor.run {
                self.drivingTask = nil
            }
        }
        drivingTask = task
    }

    /// 主入口：根据当前 phase + storyMode 决定下一步
    func generate(settings: AppSettings) async {
        guard !selectedInputs.isEmpty else {
            errorMessage = "请先至少选择一张图片"
            return
        }
        errorIsSafetyBlocked = false

        // 故事模式下，如果剧本已就绪则进入第 2 步；否则先编剧
        if storyMode {
            switch phase {
            case .scriptReady:
                await runStoryMode_renderImage(settings: settings)
            default:
                await runStoryMode_writeScript(settings: settings)
            }
        } else {
            await runSimpleMode(settings: settings)
        }
    }

    /// 重新构思剧情（保留所有其他设置，只把剧本扔掉重写）
    func regenerateScript(settings: AppSettings) async {
        generatedScript = nil
        await runStoryMode_writeScript(settings: settings)
    }

    // MARK: - 普通模式

    private func runSimpleMode(settings: AppSettings) async {
        let n = max(1, min(settings.imageCount, 4))
        let size = settings.imageSize
        let quality = settings.imageQuality
        let effectiveDiaryStamp = resolvedDiaryStamp(diaryModeOn: settings.diaryModeOn)
        let effectiveUserPrompt = buildEffectiveUserPrompt(
            basePrompt: userPrompt.isEmpty ? nil : userPrompt,
            style: style,
            diaryStamp: effectiveDiaryStamp
        )

        let req = OpenAIImageRequest(
            inputImages: selectedImages,
            previousPageImage: previousPageImage,
            characterReferenceImages: characterReferenceImages(),
            characterDirective: charactersDirective(),
            stylePrompt: style.effectivePrompt(
                isColor: isColor,
                stylizationStrength: settings.mangaStylizationStrength,
                preserveRealWorldReadability: projectMode == .navigationGuide
            ),
            userPrompt: effectiveUserPrompt,
            n: n,
            size: size,
            quality: quality,
            bubbleTextMode: bubbleTextMode
        )

        // ── 防重复请求 ──
        let hash = req.fingerprint
        if let dup = JobStore.shared.recentJob(matchingHash: hash, withinSeconds: 60) {
            self.errorMessage = "60 秒内有相同请求（任务 \(dup.id.uuidString.prefix(8))），" +
                                "为避免重复扣费已拦截。请稍后再试或在任务列表查看上一个。"
            self.errorIsSafetyBlocked = false
            phase = .idle
            return
        }

        let selectedImagesSnapshot = selectedImages
        let previousPageSnapshot = previousPageImage
        let loadedCharacterIdsSnapshot = loadedCharacters.map(\.id)
        let loadedCharacterSelectionsSnapshot = selectedCharacterSelectionsSnapshot()
        let userPromptSnapshot = userPrompt.isEmpty ? nil : userPrompt
        let bubbleModeSnapshot = bubbleTextMode
        let isColorSnapshot = isColor
        let diaryStampSnapshot = effectiveDiaryStamp
        let styleSnapshot = style
        let projectIdSnapshot = projectId
        let projectNameSnapshot = projectName

        // 先预分配 jobId，把输入图存到磁盘（用于"重新生成"按钮）
        let jobId = UUID()
        let pending = JobStore.shared.savePendingInputs(
            jobId: jobId,
            inputs: selectedImagesSnapshot,
            previousPage: previousPageSnapshot
        )

        JobStore.shared.startJob(
            id: jobId,
            projectId: projectId,
            projectName: projectName,
            style: styleSnapshot,
            kind: .simpleImage,
            stageMessage: "已提交 OpenAI，生成可能需要 1~5 分钟…",
            inputImageFiles: pending.inputs,
            previousPageFile: pending.previous,
            characterIds: loadedCharacterIdsSnapshot,
            characterSelections: loadedCharacterSelectionsSnapshot,
            userPromptText: userPromptSnapshot,
            bubbleMode: bubbleModeSnapshot,
            wasColorOn: isColorSnapshot,
            imageCount: n,
            imageSizeStr: size,
            imageQualityStr: quality,
            requestHash: hash
        )

        let backgroundTask = Task { [weak self] in
            do {
                // 普通模式提交后立即释放 UI，让用户继续切风格排队生成。
                let datas = try await OpenAIService.shared.generateManga(req, jobId: jobId) { msg in
                    JobStore.shared.updateStage(jobId, msg)
                }

                let inputDatas = selectedImagesSnapshot.compactMap { $0.pngData() }
                let savedItem = MangaStorage.shared.add(
                    projectId: projectIdSnapshot,
                    style: styleSnapshot,
                    inputs: inputDatas,
                    outputs: datas,
                    userPrompt: userPromptSnapshot,
                    storyScript: nil,
                    previousPage: previousPageSnapshot?.pngData(),
                    loadedCharacterIds: loadedCharacterIdsSnapshot,
                    loadedCharacterSelections: loadedCharacterSelectionsSnapshot,
                    bubbleTextMode: bubbleModeSnapshot,
                    isColorOutput: isColorSnapshot,
                    imageCount: n,
                    imageSize: size,
                    imageQuality: quality,
                    diaryStamp: diaryStampSnapshot,
                    applyDiaryOverlay: settings.diaryOverlayAssistOn
                )

                await MainActor.run {
                    self?.lastSaved = savedItem
                }
                JobStore.shared.complete(jobId, with: savedItem.id)
                LocalNotifier.notifyDone(
                    title: "漫画生成完成",
                    body: "\(projectNameSnapshot)：\(styleSnapshot.displayName) · 共 \(savedItem.outputImageNames.count) 张"
                )
            } catch {
                await MainActor.run {
                    self?.handleError(error)
                }
                resolveJobError(error, jobId: jobId)
            }
        }

        JobStore.shared.attachTask(backgroundTask, to: jobId)
        toastMessage = "任务已加到后台，可继续换风格生成"
        stageMessage = ""
        phase = .idle
    }

    // MARK: - 故事模式 第 1 步：编剧

    private func runStoryMode_writeScript(settings: AppSettings) async {
        phase = .generatingScript
        let req = currentStoryRequest(settings: settings)
        do {
            let script = try await OpenAIService.shared.generateStoryScriptOnly(req) { [weak self] msg in
                self?.stageMessage = msg
            }
            self.generatedScript = script
            phase = .scriptReady
        } catch {
            self.handleError(error)
            phase = .idle
        }
        stageMessage = ""
    }

    // MARK: - 故事模式 第 2 步：绘画（用户可能已经编辑过 generatedScript）

    private func runStoryMode_renderImage(settings: AppSettings) async {
        guard let script = generatedScript else {
            errorMessage = "没有可用的剧本"
            return
        }
        phase = .generatingImage
        let effectiveDiaryStamp = resolvedDiaryStamp(diaryModeOn: settings.diaryModeOn)
        let req = currentStoryRequest(settings: settings)
        let jobId = UUID()
        let pending = JobStore.shared.savePendingInputs(
            jobId: jobId,
            inputs: selectedImages,
            previousPage: previousPageImage
        )
        JobStore.shared.startJob(
            id: jobId,
            projectId: projectId,
            projectName: projectName,
            style: style,
            kind: .storyRender,
            stageMessage: "AI 正在分镜作画…",
            subtitle: script.title,
            inputImageFiles: pending.inputs,
            previousPageFile: pending.previous,
            characterIds: loadedCharacters.map { $0.id },
            characterSelections: selectedCharacterSelectionsSnapshot(),
            userPromptText: userPrompt.isEmpty ? nil : userPrompt,
            bubbleMode: bubbleTextMode,
            wasColorOn: isColor,
            imageCount: 1,
            imageSizeStr: settings.imageSize,
            imageQualityStr: settings.imageQuality,
            storyScriptSnapshot: script
        )
        if let drivingTask {
            JobStore.shared.attachTask(drivingTask, to: jobId)
        }
        do {
            // 不再用外层 wall-clock 砍请求——URLSession 已经放到 600s
            let datas = try await OpenAIService.shared.renderStoryWithScript(
                req, script: script, jobId: jobId
            ) { [weak self] msg in
                self?.stageMessage = msg
                JobStore.shared.updateStage(jobId, msg)
            }
            self.generatedImages = datas.compactMap { UIImage(data: $0) }

            let inputDatas = selectedImages.compactMap { $0.pngData() }
            let saved = MangaStorage.shared.add(
                projectId: projectId,
                style: style,
                inputs: inputDatas,
                outputs: datas,
                userPrompt: userPrompt.isEmpty ? nil : userPrompt,
                storyScript: script,
                previousPage: previousPageImage?.pngData(),
                loadedCharacterIds: loadedCharacters.map(\.id),
                loadedCharacterSelections: selectedCharacterSelectionsSnapshot(),
                bubbleTextMode: bubbleTextMode,
                isColorOutput: isColor,
                imageCount: 1,
                imageSize: settings.imageSize,
                imageQuality: settings.imageQuality,
                diaryStamp: effectiveDiaryStamp,
                applyDiaryOverlay: settings.diaryOverlayAssistOn
            )
            self.lastSaved = saved
            phase = .done
            JobStore.shared.complete(jobId, with: saved.id)
            LocalNotifier.notifyDone(
                title: "漫画生成完成",
                body: "\(projectName)：\(script.title)"
            )
        } catch {
            self.handleError(error)
            // 失败后回到 scriptReady，让用户可以再次尝试
            phase = .scriptReady
            resolveJobError(error, jobId: jobId)
        }
        stageMessage = ""
    }

    // MARK: - 工具

    private func currentStoryRequest(settings: AppSettings) -> OpenAIStoryRequest {
        let effectiveDiaryStamp = resolvedDiaryStamp(diaryModeOn: settings.diaryModeOn)
        let effectiveUserPrompt = buildEffectiveUserPrompt(
            basePrompt: userPrompt.isEmpty ? nil : userPrompt,
            style: style,
            diaryStamp: effectiveDiaryStamp
        )
        return OpenAIStoryRequest(
            inputImages: selectedImages,
            previousPageImage: previousPageImage,
            characterReferenceImages: characterReferenceImages(),
            characterDirective: charactersDirective(),
            style: style,
            userHint: effectiveUserPrompt,
            panelCount: max(2, min(panelCount, 9)),
            scriptModel: settings.scriptModel,
            size: settings.imageSize,
            quality: settings.imageQuality,
            bubbleTextMode: bubbleTextMode,
            isColor: isColor,
            stylizationStrength: settings.mangaStylizationStrength,
            preserveRealWorldReadability: projectMode == .navigationGuide
        )
    }

    private func buildEffectiveUserPrompt(basePrompt: String?,
                                          style: MangaStyle,
                                          diaryStamp: DiaryStamp?) -> String? {
        let trimmed = basePrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let memory = MangaStorage.shared.tasteMemoryPrompt(for: style)
        let diary = diaryPrompt(for: diaryStamp)
        let navigation = navigationPrompt()
        return [trimmed, memory, diary, navigation]
            .compactMap { value in
                guard let value else { return nil }
                let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            .joined(separator: "\n\n")
            .nilIfEmpty
    }

    private func resolvedDiaryStamp(diaryModeOn: Bool) -> DiaryStamp? {
        guard diaryModeOn else { return nil }
        return activeDiaryStamp ?? fallbackDiaryStamp
    }

    private func diaryPrompt(for stamp: DiaryStamp?) -> String? {
        guard let stamp else { return nil }
        var lines: [String] = []
        lines.append("DIARY MODE:")
        lines.append("Treat this manga like a personal visual diary entry.")
        lines.append("Use noticeably MORE text than normal mode — richer narration, more diary-like reflections, more inner thoughts, and clearer scene-setting notes.")
        lines.append("If speech bubbles or caption boxes are available, make good use of them. The page should feel like a written diary memory, not a mostly silent illustration.")
        lines.append("Prefer short but frequent text beats across the page: observations, feelings, little discoveries, mood notes, and reflective commentary.")
        lines.append("Include a clearly visible but tasteful diary-style date stamp in one corner, showing exactly: \(stamp.dateText).")
        if let weather = stamp.weatherText, !weather.isEmpty {
            lines.append("Also include a subtle weather note showing \(weather).")
        }
        lines.append("The stamp should feel naturally integrated into the page, like a handwritten diary note or editorial corner label, without overwhelming the composition.")
        return lines.joined(separator: "\n")
    }

    private func navigationPrompt() -> String? {
        guard projectMode == .navigationGuide else { return nil }
        var lines: [String] = []
        lines.append("NAVIGATION GUIDE MODE:")
        lines.append("This is not a normal life comic. It is a route-guidance comic that helps the viewer travel from one place to another.")
        lines.append("Use the uploaded map screenshots, overhead map crops, and street-view images as route reference material. Convert them into a clean illustrated guide page.")
        if !navigationStart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Start point: \(navigationStart.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !navigationDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Destination: \(navigationDestination.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let via = navigationWaypoints
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !via.isEmpty {
            lines.append("Waypoints / landmarks to mention in order: \(via.joined(separator: " -> "))")
        }
        if !selectedInputs.isEmpty {
            lines.append("INPUT ORDER RULE:")
            lines.append("Use the uploaded user reference images in their EXACT attached order. Treat image 1 as step 1, image 2 as step 2, image 3 as step 3, and so on, unless the first image is clearly an overview map. Do not shuffle the step order.")
            lines.append("If one image is an overview map and the remaining images are street-view steps, show the map first as orientation, then present the street-view panels in the same order the user attached them.")
        }
        lines.append(navigationStrength.promptCue)
        lines.append("ARROW RULE:")
        lines.append("If the uploaded reference image(s) already contain route arrows, treat those arrows as the ground-truth route. Follow their direction, turning points, and forward progression strictly. Do not invent a different path, do not flip the route, and do not reinterpret the navigation.")
        lines.append("When reference arrows are present, redraw them as polished bold blue navigation arrows with soft white outline, rounded shape, and clear wayfinding visibility — but keep the same path and turn behavior as the user's arrows.")
        lines.append("If the uploaded reference image(s) do NOT contain arrows, do NOT add new route arrows by yourself. In that case rely on step captions, landmarks, route callouts, and the guide character instead of inventing arrows.")
        lines.append("Prefer a step-by-step flow with route callouts, landmark recognition, and a guide character from the character library pointing the way.")
        lines.append("If multiple pages are requested, page 1 should orient the route and early steps, later pages should continue the route and arrival.")
        lines.append("Do not drift into unrelated slice-of-life storytelling. The primary goal is clear navigation and local guidance.")
        return lines.joined(separator: "\n")
    }

    private func handleError(_ error: Error) {
        self.errorMessage = error.localizedDescription
        if let oa = error as? OpenAIError {
            self.errorIsSafetyBlocked = oa.isSafetyBlocked
        } else {
            self.errorIsSafetyBlocked = false
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// 顶层引用（withDeadline / TaskTimeoutError 在 OpenAIService.swift 里定义）
// 这里不需要再 import 任何东西，全部在同一 module 内
