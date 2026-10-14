//
//  MangaDetailView.swift
//  LifeManga
//
//  详情页：浏览生成的漫画 + 输入图，可收藏 / 分享 / 保存到相册 / 删除
//

import SwiftUI
import UIKit

struct MangaDetailView: View {

    @EnvironmentObject var settings: AppSettings
    @State var item: MangaItem
    @ObservedObject private var storage = MangaStorage.shared
    @Environment(\.dismiss) private var dismiss

    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var showDeleteAlert = false
    @State private var toastMessage: String?
    @State private var showFeedbackSheet = false
    @State private var pendingFeedbackState: MangaFeedbackState = .liked
    @State private var selectedFeedbackTags: Set<MangaFeedbackTag> = []
    @State private var actionErrorMessage: String?
    @State private var isRegenerating = false

    private var preserveRealWorldReadability: Bool {
        ProjectStore.shared.projects.first(where: { $0.id == item.projectId })?.mode == .navigationGuide
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // 输出图（漫画）
                Text("生成的漫画").font(.headline)
                ForEach(item.outputImageNames, id: \.self) { name in
                    if let img = storage.image(named: name) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contextMenu {
                                Button {
                                    UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                                    toastMessage = "已保存到相册 ✓"
                                } label: {
                                    Label("保存到相册", systemImage: "square.and.arrow.down")
                                }
                                Button {
                                    shareItems = [img]
                                    showShare = true
                                } label: {
                                    Label("分享", systemImage: "square.and.arrow.up")
                                }
                            }
                    }
                }

                // 剧本（如果有）
                if let script = item.storyScript {
                    Divider()
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(script.synopsis)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ForEach(Array(script.panels.enumerated()), id: \.offset) { idx, p in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("第 \(idx + 1) 格").font(.caption).bold()
                                        .foregroundStyle(.indigo)
                                    Text(p.description).font(.caption)
                                    if let d = p.dialogue, !d.isEmpty, d.lowercased() != "null" {
                                        Label(d, systemImage: "bubble.left.fill").font(.caption)
                                    }
                                    if let n = p.narration, !n.isEmpty, n.lowercased() != "null" {
                                        Label(n, systemImage: "text.alignleft").font(.caption).italic()
                                    }
                                    if let s = p.sfx, !s.isEmpty, s.lowercased() != "null" {
                                        Label(s, systemImage: "burst.fill")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack {
                            Image(systemName: "scroll.fill")
                                .foregroundStyle(.indigo)
                            Text(script.title).font(.headline)
                            Spacer()
                            Text("\(script.panels.count) 格")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // 输入图
                if !item.inputImageNames.isEmpty {
                    Text("原始素材").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(item.inputImageNames, id: \.self) { name in
                                if let img = storage.image(named: name) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 110, height: 110)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }

                // 元数据
                VStack(alignment: .leading, spacing: 6) {
                    Label(item.style.displayName, systemImage: "paintpalette")
                    Label(item.createdAt.formatted(date: .long, time: .shortened),
                          systemImage: "calendar")
                    if let feedback = item.feedbackState {
                        Label(feedback.title, systemImage: feedback.symbolName)
                            .foregroundStyle(feedback == .liked ? .green : .orange)
                    }
                    if let p = item.userPrompt, !p.isEmpty {
                        Label(p, systemImage: "text.bubble")
                            .font(.subheadline)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        pendingFeedbackState = .liked
                        selectedFeedbackTags = Set(item.feedbackTags.filter { $0.sentiment == .liked })
                        showFeedbackSheet = true
                    } label: {
                        Label(item.feedbackState == .liked ? "已标记满意" : "满意",
                              systemImage: "hand.thumbsup.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isRegenerating)

                    Button {
                        pendingFeedbackState = .disliked
                        selectedFeedbackTags = Set(item.feedbackTags.filter { $0.sentiment == .disliked })
                        showFeedbackSheet = true
                    } label: {
                        Label(isRegenerating ? "重新生成中…" : "不满意",
                              systemImage: "hand.thumbsdown.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .disabled(isRegenerating)
                }

                // 按钮区
                HStack(spacing: 12) {
                    Button {
                        storage.toggleFavorite(item)
                        if let updated = storage.refreshedItem(id: item.id) {
                            item = updated
                        }
                    } label: {
                        Label(item.isFavorite ? "已收藏" : "收藏",
                              systemImage: item.isFavorite ? "heart.fill" : "heart")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.pink)

                    Button {
                        var items: [Any] = []
                        for n in item.outputImageNames {
                            if let img = storage.image(named: n) { items.append(img) }
                        }
                        shareItems = items
                        showShare = true
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("删除这条记录", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("作品详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
        .alert("确认删除？", isPresented: $showDeleteAlert) {
            Button("删除", role: .destructive) {
                storage.delete(item)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会同时删除生成结果和原图。")
        }
        .alert("操作失败", isPresented: .init(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } })
        ) {
            Button("好", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "")
        }
        .sheet(isPresented: $showFeedbackSheet) {
            NavigationStack {
                FeedbackCaptureSheet(
                    mode: pendingFeedbackState,
                    selectedTags: $selectedFeedbackTags,
                    isWorking: isRegenerating,
                    onConfirm: handleFeedbackConfirm
                )
            }
        }
        .overlay(alignment: .top) {
            if let toastMessage {
                Text(toastMessage)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { self.toastMessage = nil }
                    }
            }
        }
    }

    private func handleFeedbackConfirm() {
        let tags = selectedFeedbackTags
            .filter { $0.sentiment == pendingFeedbackState }
            .sorted { $0.rawValue < $1.rawValue }

        storage.applyFeedback(item, state: pendingFeedbackState, tags: tags)
        if let updated = storage.refreshedItem(id: item.id) {
            item = updated
        }
        showFeedbackSheet = false

        switch pendingFeedbackState {
        case .liked:
            toastMessage = "已加入收藏，并记住你的偏好"
        case .disliked:
            Task {
                await regenerateFromDislike(tags: tags)
            }
        }
    }

    @MainActor
    private func regenerateFromDislike(tags: [MangaFeedbackTag]) async {
        guard !isRegenerating else { return }
        let inputImages = item.inputImageNames.compactMap { storage.image(named: $0) }
        guard !inputImages.isEmpty else {
            actionErrorMessage = "原始素材已经缺失，暂时无法按这条记录重新生成。"
            return
        }

        isRegenerating = true
        defer { isRegenerating = false }

        let previousPageImage = item.previousPageImageName.flatMap { storage.image(named: $0) }
        let characterIds = item.loadedCharacterIds ?? []
        let characterSelections = item.loadedCharacterSelections
        let n = max(1, item.imageCount ?? item.outputImageNames.count)
        let size = item.imageSize ?? settings.imageSize
        let quality = item.imageQuality ?? settings.imageQuality
        let bubbleMode = item.bubbleTextMode ?? settings.bubbleTextMode
        let isColor = item.isColorOutput ?? settings.isColor
        let prompt = combinedRetryPrompt(extraDislikes: tags)

        let imageReq = OpenAIImageRequest(
            inputImages: inputImages,
            previousPageImage: previousPageImage,
            characterReferenceImages: characterReferenceImages(for: characterIds,
                                                               selections: characterSelections),
            characterDirective: characterDirective(for: characterIds),
            stylePrompt: item.style.effectivePrompt(
                isColor: isColor,
                stylizationStrength: settings.mangaStylizationStrength,
                preserveRealWorldReadability: preserveRealWorldReadability
            ),
            userPrompt: prompt,
            n: n,
            size: size,
            quality: quality,
            bubbleTextMode: bubbleMode
        )
        let storyReq = OpenAIStoryRequest(
            inputImages: inputImages,
            previousPageImage: previousPageImage,
            characterReferenceImages: characterReferenceImages(for: characterIds,
                                                               selections: characterSelections),
            characterDirective: characterDirective(for: characterIds),
            style: item.style,
            userHint: prompt,
            panelCount: max(2, item.storyScript?.panels.count ?? 6),
            scriptModel: settings.scriptModel,
            size: size,
            quality: quality,
            bubbleTextMode: bubbleMode,
            isColor: isColor,
            stylizationStrength: settings.mangaStylizationStrength,
            preserveRealWorldReadability: preserveRealWorldReadability
        )

        let jobId = JobStore.shared.startJob(
            projectId: item.projectId,
            projectName: projectName(for: item.projectId),
            style: item.style,
            kind: item.storyScript == nil ? .simpleImage : .storyRender,
            stageMessage: "根据你的反馈重新生成中…",
            subtitle: item.storyScript?.title,
            characterIds: characterIds,
            characterSelections: characterSelections,
            userPromptText: item.userPrompt,
            bubbleMode: bubbleMode,
            wasColorOn: isColor,
            imageCount: n,
            imageSizeStr: size,
            imageQualityStr: quality,
            storyScriptSnapshot: item.storyScript,
            requestHash: imageReq.fingerprint
        )

        do {
            let outputs: [Data]
            if let script = item.storyScript {
                outputs = try await OpenAIService.shared.renderStoryWithScript(storyReq, script: script, jobId: jobId) { msg in
                    JobStore.shared.updateStage(jobId, msg)
                }
            } else {
                outputs = try await OpenAIService.shared.generateManga(imageReq, jobId: jobId) { msg in
                    JobStore.shared.updateStage(jobId, msg)
                }
            }

            let saved = MangaStorage.shared.add(
                projectId: item.projectId,
                style: item.style,
                inputs: inputImages.compactMap { $0.pngData() },
                outputs: outputs,
                userPrompt: item.userPrompt,
                storyScript: item.storyScript,
                previousPage: previousPageImage?.pngData(),
                loadedCharacterIds: characterIds,
                loadedCharacterSelections: characterSelections,
                bubbleTextMode: bubbleMode,
                isColorOutput: isColor,
                imageCount: n,
                imageSize: size,
                imageQuality: quality,
                diaryStamp: item.diaryStamp,
                applyDiaryOverlay: settings.diaryOverlayAssistOn
            )
            JobStore.shared.complete(jobId, with: saved.id)
            item = saved
            toastMessage = "已根据你的不满意点重生成一版"
        } catch {
            resolveJobError(error, jobId: jobId)
            actionErrorMessage = error.localizedDescription
        }
    }

    private func combinedRetryPrompt(extraDislikes: [MangaFeedbackTag]) -> String? {
        let base = item.userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let memory = storage.tasteMemoryPrompt(for: item.style, extraDislikes: extraDislikes)
        let diary = diaryPrompt(for: item.diaryStamp)
        let retryLine = """
        This is a regeneration after a rejected result. Keep the same subject, source photos, and overall intent, but fix the dissatisfaction points above.
        """

        var parts: [String] = []
        if let base, !base.isEmpty { parts.append(base) }
        if let memory, !memory.isEmpty { parts.append(memory) }
        if let diary, !diary.isEmpty { parts.append(diary) }
        parts.append(retryLine)
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func diaryPrompt(for stamp: DiaryStamp?) -> String? {
        guard let stamp else { return nil }
        var lines: [String] = []
        lines.append("DIARY MODE:")
        lines.append("Treat this manga like a personal visual diary entry.")
        lines.append("Include a clearly visible but tasteful diary-style date stamp in one corner, showing exactly: \(stamp.dateText).")
        if let weather = stamp.weatherText, !weather.isEmpty {
            lines.append("Also include a subtle weather note showing \(weather).")
        }
        return lines.joined(separator: "\n")
    }

    private func characterReferenceImages(for ids: [UUID],
                                          selections: [CharacterReferenceSelection]?) -> [UIImage] {
        ids.compactMap { id in
            guard let character = CharacterStore.shared.characters.first(where: { $0.id == id }) else {
                return nil
            }
            let selectedViewId = selections?.first(where: { $0.characterId == id })?.viewId
            if let selectedViewId,
               let view = character.views.first(where: { $0.id == selectedViewId }) {
                return CharacterStore.shared.image(named: view.imageName)
            }
            if let name = character.referencePortraitView?.imageName {
                return CharacterStore.shared.image(named: name)
            }
            if let name = character.sourcePhotoName {
                return CharacterStore.shared.image(named: name)
            }
            return nil
        }
    }

    private func characterDirective(for ids: [UUID]) -> String? {
        let names = ids.compactMap { id in
            CharacterStore.shared.characters.first(where: { $0.id == id })?.name
        }
        guard !names.isEmpty else { return nil }
        return """
        CHARACTER REFERENCE:
        I have attached \(names.count) character reference image(s) at the end of the input set. These represent the recurring characters that should appear in this page (\(names.joined(separator: "、"))). Match their faces, hair, outfits and overall design exactly as shown. Do not redesign them.

        IMPORTANT REFERENCE-USE RULE:
        Use ONLY the main standing character figure from each reference as the canonical design. Ignore any side expression heads, accessory callouts, prop layouts, object boards, arrows, labels, multi-panel sheet layout, background decorations, or extra design-sheet elements that may appear around the character in a character sheet. Those surrounding helper elements are reference aids only and must NOT be copied into the manga unless the user explicitly asked for that object or prop in the scene.
        """
    }

    private func projectName(for projectId: UUID) -> String {
        ProjectStore.shared.projects.first(where: { $0.id == projectId })?.name ?? "漫画工程"
    }
}

private struct FeedbackCaptureSheet: View {
    let mode: MangaFeedbackState
    @Binding var selectedTags: Set<MangaFeedbackTag>
    let isWorking: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var availableTags: [MangaFeedbackTag] {
        MangaFeedbackTag.allCases.filter { $0.sentiment == mode }
    }

    var body: some View {
        List {
            Section {
                Text(mode == .liked
                     ? "选几个你满意的点，后面生成时会更偏向这些方向。"
                     : "选几个这次最不满意的点，系统会据此重新生成并尽量避开。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section(mode == .liked ? "满意点" : "不满意点") {
                ForEach(availableTags) { tag in
                    Button {
                        if selectedTags.contains(tag) {
                            selectedTags.remove(tag)
                        } else {
                            selectedTags.insert(tag)
                        }
                    } label: {
                        HStack {
                            Text(tag.title)
                            Spacer()
                            if selectedTags.contains(tag) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(mode == .liked ? .green : .orange)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
                    .disabled(isWorking)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(mode == .liked ? "加入收藏" : "重新生成") {
                    onConfirm()
                }
                .disabled(isWorking)
            }
        }
    }
}

// MARK: - UIActivityViewController 包装

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
