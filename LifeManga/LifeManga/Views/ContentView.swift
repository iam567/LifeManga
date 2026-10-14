//
//  ContentView.swift
//  LifeManga
//
//  根视图：TabView 三大 Tab —— 工程 / 角色库 / 发布
//

import SwiftUI
import PhotosUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            NavigationStack {
                ProjectListView()
            }
            .tabItem { Label("工程", systemImage: "books.vertical.fill") }

            NavigationStack {
                CharacterLibraryView()
            }
            .tabItem { Label("角色库", systemImage: "person.crop.rectangle.stack.fill") }

            NavigationStack {
                PublishView()
            }
            .tabItem { Label("发布", systemImage: "paperplane.fill") }
        }
        .overlay(alignment: .top) {
            if !settings.isBackendConfigured {
                BackendConfigMissingBanner()
                    .padding(.top, 4)
            }
        }
    }
}

private struct BackendConfigMissingBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("请先到「设置」配置漫画后端地址和 API Key")
                .font(.footnote)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.85), in: Capsule())
        .padding(.horizontal)
    }
}

// MARK: ───────────────────────────────────────── 工程 Tab ─────

struct ProjectListView: View {
    @ObservedObject private var store = ProjectStore.shared
    @ObservedObject private var storage = MangaStorage.shared
    @ObservedObject private var jobStore = JobStore.shared

    @State private var showNewSheet = false
    @State private var newName: String = ""
    @State private var newMode: ProjectMode = .comicLife
    @State private var renamingProject: MangaProject?
    @State private var renameInput: String = ""
    @State private var showSettings = false
    @State private var showTasks = false

    var body: some View {
        Group {
            if store.projects.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .navigationTitle("漫画人生")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 14) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    Button { showTasks = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "tray.full")
                            if jobStore.runningCount > 0 {
                                Text("\(jobStore.runningCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                                    .offset(x: 8, y: -6)
                            }
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { startNewProject() } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
            }
        }
        .sheet(isPresented: $showNewSheet) {
            CreateProjectSheet(name: $newName, mode: $newMode) {
                store.create(
                    name: newName.trimmingCharacters(in: .whitespaces),
                    mode: newMode
                )
                newName = ""
                newMode = .comicLife
                showNewSheet = false
            } onCancel: {
                newName = ""
                newMode = .comicLife
                showNewSheet = false
            }
        }
        .alert("重命名工程", isPresented: .init(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } })
        ) {
            TextField("新名称", text: $renameInput)
            Button("保存") {
                if let p = renamingProject {
                    store.rename(p, to: renameInput.trimmingCharacters(in: .whitespaces))
                }
                renamingProject = nil
            }
            Button("取消", role: .cancel) { renamingProject = nil }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showTasks) { TaskManagerView() }
        .navigationDestination(for: MangaProject.self) { project in
            ProjectShellView(project: project)
        }
    }

    private func startNewProject() {
        newName = ""
        newMode = .comicLife
        showNewSheet = true
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 64))
                .foregroundStyle(.indigo.opacity(0.6))
            Text("还没有漫画工程")
                .font(.title3.weight(.semibold))
            Text("一个「工程」就是一本你的漫画。\n你可以在里面持续创作多张漫画页，并保持画风一致。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                startNewProject()
            } label: {
                Label("新建一个工程", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectList: some View {
        List {
            ForEach(store.projects) { project in
                NavigationLink(value: project) {
                    ProjectRow(project: project)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.delete(project)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        renamingProject = project
                        renameInput = project.name
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    .tint(.indigo)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct ProjectRow: View {
    let project: MangaProject
    @ObservedObject private var storage = MangaStorage.shared

    private var itemCount: Int { storage.items(in: project.id).count }

    private var coverImage: UIImage? {
        let items = storage.items(in: project.id)
        let target = items.first { $0.id == project.coverItemId } ?? items.first
        guard let name = target?.outputImageNames.first else { return nil }
        return storage.image(named: name)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                if let img = coverImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "book.closed.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.headline)
                Label(project.mode.displayName, systemImage: project.mode.symbolName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(project.mode == .navigationGuide ? .green : .indigo)
                HStack(spacing: 8) {
                    Text("\(itemCount) 张")
                    Text("·")
                    Text(project.updatedAt.formatted(date: .abbreviated, time: .omitted))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CreateProjectSheet: View {
    @Binding var name: String
    @Binding var mode: ProjectMode
    let onCreate: () -> Void
    let onCancel: () -> Void

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameSection
                    modeSection
                }
                .padding()
            }
            .navigationTitle("新建漫画工程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建", action: onCreate)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("工程名")
                .font(.headline)
            TextField("如：东京游记 / 找咖啡店 / 我的猫的一天", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("工程模式")
                .font(.headline)
            VStack(spacing: 12) {
                ForEach(ProjectMode.allCases) { option in
                    modeCard(option)
                }
            }
        }
    }

    private func modeCard(_ option: ProjectMode) -> some View {
        let selected = mode == option
        return Button {
            mode = option
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: option.symbolName)
                    .font(.title3)
                    .foregroundStyle(selected ? .white : .indigo)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.displayName)
                        .font(.headline)
                        .foregroundStyle(selected ? .white : .primary)
                    Text(option.subtitle)
                        .font(.caption)
                        .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .white : Color.secondary.opacity(0.6))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(selected ? Color.indigo : Color(.systemGray6))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: ─── 工程内壳：用 SegmentedPicker 替代嵌套 TabView ───

struct ProjectShellView: View {
    let project: MangaProject

    enum Section: String, CaseIterable, Identifiable {
        case create = "创作", history = "历史"
        var id: String { rawValue }
    }

    @State private var section: Section = .create

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { s in
                    Text(sectionTitle(for: s)).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch section {
            case .create:
                HomeView(project: project)
            case .history:
                HistoryView(project: project)
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionTitle(for section: Section) -> String {
        switch (project.mode, section) {
        case (.navigationGuide, .create):
            return "导览"
        default:
            return section.rawValue
        }
    }
}

// MARK: ──────────────────────────────────────── 任务管理 ─────

struct TaskManagerView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jobStore = JobStore.shared
    @ObservedObject private var storage = MangaStorage.shared
    @ObservedObject private var characterStore = CharacterStore.shared
    @State private var detailItem: MangaItem?
    @State private var detailCharacter: Character?
    @State private var logViewJob: Job?
    @State private var showingError: String?
    /// 用户对 timeoutUnknown 任务点了「重新生成」时，先弹确认框防止重复扣费
    @State private var pendingRetryConfirm: Job?

    var body: some View {
        NavigationStack {
            Group {
                if jobStore.jobs.isEmpty {
                    ContentUnavailableView(
                        "还没有任何任务",
                        systemImage: "tray",
                        description: Text("生成漫画时会自动加入这里。\n你可以锁屏或切到别的 App，完成后会推送通知。")
                    )
                } else {
                    List {
                        ForEach(jobStore.jobs) { job in
                            JobRow(job: job)
                                .contentShape(Rectangle())
                                .onTapGesture { handleTap(job) }
                                .swipeActions(edge: .leading) {
                                    if job.canRetry {
                                        Button {
                                            // timeoutUnknown 状态先弹确认（避免重复扣费），失败状态直接走
                                            if job.phase.isTimeoutUnknown {
                                                pendingRetryConfirm = job
                                            } else {
                                                retryJob(job)
                                            }
                                        } label: {
                                            Label("重新生成", systemImage: "arrow.clockwise")
                                        }
                                        .tint(.green)
                                    }
                                    Button {
                                        logViewJob = job
                                    } label: {
                                        Label("日志", systemImage: "doc.text")
                                    }
                                    .tint(.indigo)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if job.phase.isRunning {
                                        // 第一个 = 最靠边 = 全划触发：终止（更安全，保留记录）
                                        Button {
                                            jobStore.cancel(job.id)
                                        } label: {
                                            Label("终止任务", systemImage: "stop.circle.fill")
                                        }
                                        .tint(.orange)
                                        // 第二个 = 内侧：删除（先终止再从列表移除）
                                        Button(role: .destructive) {
                                            jobStore.cancel(job.id)
                                            jobStore.remove(job)
                                        } label: {
                                            Label("删除任务", systemImage: "trash")
                                        }
                                    } else {
                                        Button(role: .destructive) {
                                            jobStore.remove(job)
                                        } label: {
                                            Label("删除任务", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if jobStore.jobs.contains(where: { !$0.phase.isRunning }) {
                        Menu {
                            Button(role: .destructive) {
                                jobStore.clearFinished()
                            } label: {
                                Label("清除已完成 / 失败", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(item: $detailItem) { item in
                NavigationStack { MangaDetailView(item: item) }
            }
            .sheet(item: $detailCharacter) { c in
                NavigationStack { CharacterDetailView(character: c) }
            }
            .sheet(item: $logViewJob) { job in
                JobLogView(job: job)
            }
            .alert("失败原因", isPresented: .init(
                get: { showingError != nil },
                set: { if !$0 { showingError = nil } })
            ) {
                Button("好") { showingError = nil }
            } message: {
                Text(showingError ?? "")
            }
            .alert("确认重新生成？",
                   isPresented: .init(
                    get: { pendingRetryConfirm != nil },
                    set: { if !$0 { pendingRetryConfirm = nil } })
            ) {
                Button("取消", role: .cancel) { pendingRetryConfirm = nil }
                Button("重新生成", role: .destructive) {
                    if let j = pendingRetryConfirm { retryJob(j) }
                    pendingRetryConfirm = nil
                }
            } message: {
                Text("这个任务客户端没收到结果，OpenAI 端可能仍在生成或已经成功。" +
                     "现在「重新生成」会创建一个新的 OpenAI 任务，**可能再次扣费**。" +
                     "建议先去 OpenAI dashboard / 看任务列表看看上一个会不会陆续完成，再决定。")
            }
        }
    }

    private func handleTap(_ job: Job) {
        switch job.phase {
        case .running, .failed, .timeoutUnknown:
            // 跑中 / 失败 / 超时未知 → 打开日志查看实时进度 / 错误链
            logViewJob = job
        case .done(let resultId):
            if job.kind == .characterViews {
                if let c = characterStore.characters.first(where: { $0.id == resultId }) {
                    detailCharacter = c
                }
            } else {
                if let item = storage.allItems.first(where: { $0.id == resultId }) {
                    detailItem = item
                }
            }
        }
    }

    /// 重新生成失败的任务（角色设定稿 / 普通漫画）
    private func retryJob(_ job: Job) {
        guard job.canRetry else {
            showingError = "这个任务不支持自动重试"
            return
        }
        switch job.kind {
        case .characterViews:
            retryCharacterJob(job)
        case .simpleImage:
            retryMangaJob(job)
        default:
            showingError = "暂不支持重试这种任务（目前仅支持「角色设定稿」与「普通漫画」）"
        }
    }

    private func retryCharacterJob(_ job: Job) {
        guard let artStyle = job.artStyle,
              let cId = job.characterId,
              let c = characterStore.characters.first(where: { $0.id == cId }),
              let n = c.sourcePhotoName,
              let img = characterStore.image(named: n) else {
            showingError = "无法自动重试这个任务（缺少原始照片或参数）"
            return
        }

        let imgSize = "1024x1536"
        let imgQuality = "medium"
        let cName = c.name
        let bio = c.bio

        let isAdvancedSheet = job.outputLabel?.contains("高级设定图") == true
        let label: String = {
            if isAdvancedSheet {
                return artStyle.nextAdvancedSheetLabel(existingLabels: c.views.map(\.label))
            }
            return artStyle.standardPortraitLabel
        }()

        let newJobId = JobStore.shared.startJob(
            style: settings.defaultStyle,
            kind: .characterViews,
            stageMessage: "已加入后台队列…（重试）",
            subtitle: "\(artStyle.displayName)·\(cName)·" + (isAdvancedSheet ? "高级设定图" : "标准立绘"),
            characterId: cId,
            characterName: cName,
            artStyle: artStyle,
            outputLabel: label,
            manualRetryCount: job.manualRetryCount + 1
        )

        let task = Task {
            do {
                let data: Data
                if isAdvancedSheet {
                    let basePortrait = c.views.first(where: { $0.label == artStyle.standardPortraitLabel })
                        .flatMap { characterStore.image(named: $0.imageName) }
                    data = try await OpenAIService.shared.generateAdvancedCharacterSheet(
                        sourcePhoto: img,
                        basePortrait: basePortrait,
                        name: cName,
                        bio: bio,
                        ageGroup: c.ageGroup,
                        gender: c.gender,
                        artStyle: artStyle,
                        size: imgSize,
                        quality: imgQuality,
                        jobId: newJobId,
                        onStage: { msg in JobStore.shared.updateStage(newJobId, msg) }
                    )
                } else {
                    data = try await OpenAIService.shared.generateCharacterPortrait(
                        sourcePhoto: img,
                        name: cName,
                        bio: bio,
                        ageGroup: c.ageGroup,
                        gender: c.gender,
                        artStyle: artStyle,
                        size: imgSize,
                        quality: imgQuality,
                        jobId: newJobId,
                        onStage: { msg in JobStore.shared.updateStage(newJobId, msg) }
                    )
                }
                if Task.isCancelled { return }
                CharacterStore.shared.addViews(to: cId, views: [(label, data)])
                JobStore.shared.complete(newJobId, with: cId)
                LocalNotifier.notifyDone(
                    title: "「\(artStyle.displayName)」" + (isAdvancedSheet ? "高级设定图完成" : "标准立绘完成"),
                    body: cName
                )
            } catch {
                resolveJobError(error, jobId: newJobId,
                                label: "\(artStyle.displayName) " + (isAdvancedSheet ? "高级设定图" : "标准立绘"))
            }
        }
        JobStore.shared.attachTask(task, to: newJobId)
    }

    /// 重新生成失败的"普通漫画"任务
    private func retryMangaJob(_ job: Job) {
        // 1. 还原输入图
        guard let files = job.inputImageFiles, !files.isEmpty else {
            showingError = "没找到输入图（任务被清理过），无法重试"
            return
        }
        let inputImages: [UIImage] = files.compactMap {
            JobStore.shared.loadPendingImage($0, jobId: job.id)
        }
        guard !inputImages.isEmpty else {
            showingError = "输入图已经丢失，无法重试"
            return
        }
        let prevImage: UIImage? = job.previousPageFile.flatMap {
            JobStore.shared.loadPendingImage($0, jobId: job.id)
        }
        // 2. 还原角色参考图
        let charImages: [UIImage] = (job.characterIds ?? []).compactMap { cid in
            guard let c = characterStore.characters.first(where: { $0.id == cid }) else {
                return nil
            }
            let selectedViewId = job.characterSelections?.first(where: { $0.characterId == cid })?.viewId
            if let selectedViewId,
               let view = c.views.first(where: { $0.id == selectedViewId }),
               let ui = characterStore.image(named: view.imageName) {
                return ui
            }
            if let n = c.preferredCoverView?.imageName,
               let ui = characterStore.image(named: n) {
                return ui
            }
            if let n = c.sourcePhotoName, let ui = characterStore.image(named: n) {
                return ui
            }
            return nil
        }
        let charDirective: String? = {
            let names = (job.characterIds ?? [])
                .compactMap { cid in characterStore.characters.first(where: { $0.id == cid })?.name }
            guard !names.isEmpty else { return nil }
            return """
            CHARACTER REFERENCE:
            I have attached \(names.count) character reference image(s) at the end of \
            the input set. These represent the recurring characters that should appear in this \
            page (\(names.joined(separator: "、"))). Match their faces, hair, outfits and overall \
            design EXACTLY as shown. Do not redesign them.
            """
        }()

        let isColor = job.wasColorOn ?? false
        let bubbleMode = job.bubbleMode ?? "chinese"
        let n = job.imageCount ?? 1
        let imgSize = job.imageSizeStr ?? "1024x1536"
        let imgQuality = job.imageQualityStr ?? "medium"
        let userPrompt = job.userPromptText
        let style = job.style
        let projectId = job.projectId
        let projectName = job.projectName
        let preserveRealWorldReadability = ProjectStore.shared.projects
            .first(where: { $0.id == projectId })?.mode == .navigationGuide

        let req = OpenAIImageRequest(
            inputImages: inputImages,
            previousPageImage: prevImage,
            characterReferenceImages: charImages,
            characterDirective: charDirective,
            stylePrompt: style.effectivePrompt(
                isColor: isColor,
                stylizationStrength: settings.mangaStylizationStrength,
                preserveRealWorldReadability: preserveRealWorldReadability
            ),
            userPrompt: userPrompt,
            n: n,
            size: imgSize,
            quality: imgQuality,
            bubbleTextMode: bubbleMode
        )

        // 3. 起一个新的 jobId（保留旧的失败记录，方便用户对比）
        let newJobId = UUID()
        let pending = JobStore.shared.savePendingInputs(
            jobId: newJobId,
            inputs: inputImages,
            previousPage: prevImage
        )
        JobStore.shared.startJob(
            id: newJobId,
            projectId: projectId,
            projectName: projectName,
            style: style,
            kind: .simpleImage,
            stageMessage: "已加入后台队列…（重试）",
            inputImageFiles: pending.inputs,
            previousPageFile: pending.previous,
            characterIds: job.characterIds,
            characterSelections: job.characterSelections,
            userPromptText: userPrompt,
            bubbleMode: bubbleMode,
            wasColorOn: isColor,
            imageCount: n,
            imageSizeStr: imgSize,
            imageQualityStr: imgQuality,
            requestHash: req.fingerprint,
            manualRetryCount: job.manualRetryCount + 1
        )

        let task = Task {
            do {
                let datas = try await OpenAIService.shared.generateManga(req, jobId: newJobId) { msg in
                    JobStore.shared.updateStage(newJobId, msg)
                }
                if Task.isCancelled { return }
                let inputDatas = inputImages.compactMap { $0.pngData() }
                let pid = projectId ?? ProjectStore.shared.ensureDefaultProject().id
                let savedItem = MangaStorage.shared.add(
                    projectId: pid,
                    style: style,
                    inputs: inputDatas,
                    outputs: datas,
                    userPrompt: userPrompt,
                    storyScript: nil,
                    previousPage: prevImage?.pngData(),
                    loadedCharacterIds: job.characterIds,
                    loadedCharacterSelections: job.characterSelections,
                    bubbleTextMode: bubbleMode,
                    isColorOutput: isColor,
                    imageCount: n,
                    imageSize: imgSize,
                    imageQuality: imgQuality
                )
                JobStore.shared.complete(newJobId, with: savedItem.id)
                LocalNotifier.notifyDone(
                    title: "漫画生成完成",
                    body: "\(projectName)：\(style.displayName) · 共 \(savedItem.outputImageNames.count) 张"
                )
            } catch {
                resolveJobError(error, jobId: newJobId)
            }
        }
        JobStore.shared.attachTask(task, to: newJobId)
    }
}

// MARK: - 任务日志视图

struct JobLogView: View {
    let job: Job

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jobStore = JobStore.shared

    private var entries: [JobLogEntry] {
        jobStore.logs[job.id] ?? []
    }

    private var liveJob: Job {
        jobStore.jobs.first { $0.id == job.id } ?? job
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if entries.isEmpty {
                            Text("尚未产生日志")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding()
                        } else {
                            ForEach(entries) { e in
                                LogRow(entry: e)
                                    .id(e.id)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
                .background(Color(.systemBackground))
                .onChange(of: entries.count) { _, _ in
                    if let last = entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("任务日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    statusBadge
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                headerCard
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let p = liveJob.phase
        Text({
            if p.isRunning         { return "运行中" }
            if p.isDone            { return "已完成" }
            if p.isTimeoutUnknown  { return "结果未知" }
            return "失败"
        }())
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background({
                if p.isRunning         { return Color.indigo.opacity(0.15) }
                if p.isDone            { return Color.green.opacity(0.15) }
                if p.isTimeoutUnknown  { return Color.orange.opacity(0.15) }
                return Color.red.opacity(0.15)
            }())
            .foregroundStyle({ () -> Color in
                if p.isRunning         { return .indigo }
                if p.isDone            { return .green }
                if p.isTimeoutUnknown  { return .orange }
                return .red
            }())
            .clipShape(Capsule())
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(liveJob.displayName).font(.headline)
            if let sub = liveJob.subtitle, !sub.isEmpty {
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(liveJob.stageMessage).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if liveJob.phase.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsed(ctx.date))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func elapsed(_ now: Date) -> String {
        let secs = Int(now.timeIntervalSince(liveJob.createdAt))
        let m = secs / 60, s = secs % 60
        return m == 0 ? "\(s) 秒" : "\(m) 分 \(s) 秒"
    }
}

private struct LogRow: View {
    let entry: JobLogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: 11).monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)

            Image(systemName: entry.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(swiftUIColor)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)

            Text(entry.message)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(entry.level == .detail ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    private var swiftUIColor: Color {
        switch entry.color {
        case "green":  return .green
        case "orange": return .orange
        case "red":    return .red
        case "gray":   return .gray
        default:       return .blue
        }
    }
}

private struct JobRow: View {
    let job: Job
    @ObservedObject private var storage = MangaStorage.shared
    @ObservedObject private var characterStore = CharacterStore.shared

    var body: some View {
        HStack(spacing: 12) {
            iconBox
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if job.kind == .characterViews {
                        Image(systemName: "person.crop.rectangle.fill")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                    } else {
                        StylePreviewIcon(style: job.style, size: 18)
                    }
                    Text(job.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                }
                if let sub = job.subtitle, !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(stateText).font(.caption2).foregroundStyle(stateColor).lineLimit(2)
                // 运行中实时显示已运行时长
                if job.phase.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("已运行 \(elapsedString(ctx.date))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(timestamp).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 4)
    }

    private func elapsedString(_ now: Date) -> String {
        let secs = Int(now.timeIntervalSince(job.createdAt))
        let m = secs / 60
        let s = secs % 60
        if m == 0 { return "\(s) 秒" }
        return "\(m) 分 \(s) 秒"
    }

    @ViewBuilder
    private var iconBox: some View {
        switch job.phase {
        case .running:
            ZStack {
                Circle().fill(Color.indigo.opacity(0.15)).frame(width: 44, height: 44)
                ProgressView().controlSize(.small)
            }
        case .done(let resultId):
            ZStack {
                if job.kind == .characterViews {
                    if let c = characterStore.characters.first(where: { $0.id == resultId }),
                       let v = c.preferredCoverView,
                       let img = characterStore.image(named: v.imageName) {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Circle().fill(Color.green.opacity(0.2)).frame(width: 44, height: 44)
                        Image(systemName: "person.fill").foregroundStyle(.green)
                    }
                } else if let item = storage.allItems.first(where: { $0.id == resultId }),
                          let name = item.outputImageNames.first,
                          let img = storage.image(named: name) {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Circle().fill(Color.green.opacity(0.2)).frame(width: 44, height: 44)
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            }
        case .failed:
            ZStack {
                Circle().fill(Color.red.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "xmark").foregroundStyle(.red)
            }
        case .timeoutUnknown:
            ZStack {
                Circle().fill(Color.orange.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "questionmark").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch job.phase {
        case .running:        Image(systemName: "ellipsis").foregroundStyle(.tertiary)
        case .done:           Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        case .failed:         Image(systemName: "info.circle").foregroundStyle(.red)
        case .timeoutUnknown: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }

    private var stateText: String {
        switch job.phase {
        case .running:                return job.stageMessage
        case .done:                   return "已完成 · 点击查看"
        case .failed(let m):          return m
        case .timeoutUnknown(let m):  return m
        }
    }

    private var stateColor: Color {
        switch job.phase {
        case .running:        return .indigo
        case .done:           return .green
        case .failed:         return .red
        case .timeoutUnknown: return .orange
        }
    }

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: job.createdAt)
    }
}

// MARK: ───────────────────────────────────────── 角色库 Tab ─────

struct CharacterLibraryView: View {
    @ObservedObject private var store = CharacterStore.shared
    @State private var showCreate = false
    @State private var isSyncing = false
    @State private var syncMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        Group {
            if store.characters.isEmpty {
                empty
            } else {
                grid
            }
        }
        .navigationTitle("角色库")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    Button {
                        syncCharacters()
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud.fill")
                                .font(.title3)
                        }
                    }
                    .disabled(isSyncing || store.characters.isEmpty)

                    Button { showCreate = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CharacterCreateView()
        }
        .navigationDestination(for: Character.self) { c in
            CharacterDetailView(character: c)
        }
        .alert("角色库同步", isPresented: Binding(
            get: { syncMessage != nil },
            set: { if !$0 { syncMessage = nil } }
        )) {
            Button("好") { syncMessage = nil }
        } message: {
            Text(syncMessage ?? "")
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 56))
                .foregroundStyle(.indigo.opacity(0.6))
            Text("还没有角色").font(.title3.weight(.semibold))
            Text("用一张真人照片，先生成干净的标准立绘；\n之后再按不同艺术风格继续扩展成高级设定图、动作合集和剧情参考。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button { showCreate = true } label: {
                Label("创建角色", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.characters) { c in
                    NavigationLink(value: c) {
                        CharacterCardView(character: c)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    private func syncCharacters() {
        isSyncing = true
        Task {
            defer { Task { @MainActor in isSyncing = false } }
            do {
                let count = try await CharacterSyncService.shared.syncAllCharacters()
                await MainActor.run {
                    syncMessage = "已同步 \(count) 个角色到服务器后台。"
                }
            } catch {
                await MainActor.run {
                    syncMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct CharacterCardView: View {
    let character: Character
    @ObservedObject private var store = CharacterStore.shared

    private var coverImage: UIImage? {
        if let v = character.preferredCoverView {
            return store.image(named: v.imageName)
        }
        if let n = character.sourcePhotoName {
            return store.image(named: n)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                if let img = coverImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(character.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text("\(character.views.count) 张角色资产")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// 角色详情：网格展示该角色所有立绘
struct CharacterDetailView: View {
    let character: Character
    @ObservedObject private var store = CharacterStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvancedSheet = false
    @State private var showPosePicker = false
    @State private var zoomingView: CharacterView?
    @State private var showRename = false
    @State private var renameInput = ""

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    /// 每次获取最新版本的角色（store 更新后跟进）
    private var current: Character {
        store.characters.first { $0.id == character.id } ?? character
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let bio = current.bio, !bio.isEmpty {
                    Text(bio).font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                // 操作按钮
                HStack(spacing: 10) {
                    Button {
                        showPosePicker = true
                    } label: {
                        Label("生成更多动作", systemImage: "figure.run")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showAdvancedSheet = true
                    } label: {
                        Label("生成高级设定图", systemImage: "square.grid.3x3.topleft.filled")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                if current.views.isEmpty {
                    Text("还没有角色资产。标准立绘生成中？去任务面板看看进度。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(current.views) { v in
                            Button {
                                zoomingView = v
                            } label: {
                                VStack(spacing: 6) {
                                    if let img = store.image(named: v.imageName) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxHeight: 220)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    Text(v.label).font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.removeView(characterId: current.id, viewId: v.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameInput = current.name
                        showRename = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        store.delete(current)
                        dismiss()
                    } label: {
                        Label("删除角色", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("重命名角色", isPresented: $showRename) {
            TextField("名字", text: $renameInput)
            Button("保存") {
                let trimmed = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    store.rename(current, name: trimmed)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showAdvancedSheet) {
            AdvancedCharacterSheetView(character: current)
        }
        .sheet(isPresented: $showPosePicker) {
            PosePickerSheet(character: current)
        }
        .fullScreenCover(item: $zoomingView) { v in
            ZoomableImageView(
                image: store.image(named: v.imageName) ?? UIImage(),
                title: v.label
            )
        }
    }
}

// MARK: - 全屏可缩放图片查看器

struct ZoomableImageView: View {
    let image: UIImage
    let title: String?
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1, min(lastScale * value, 6))
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1 {
                                    withAnimation(.spring()) {
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                }
                            },
                        DragGesture()
                            .onChanged { v in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width:  lastOffset.width  + v.translation.width,
                                    height: lastOffset.height + v.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if scale > 1 {
                            scale = 1; lastScale = 1
                            offset = .zero; lastOffset = .zero
                        } else {
                            scale = 2.5; lastScale = 2.5
                        }
                    }
                }

            VStack {
                HStack {
                    if let t = title {
                        Text(t)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                }
                .padding()
                Spacer()
                Button {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.bottom, 30)
            }
        }
    }
}

// MARK: - 动作选择器（多选 + 批量后台生成）

struct PosePickerSheet: View {
    let character: Character
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: AppSettings
    @State private var selected: Set<String> = []
    @State private var selectedReferenceViewID: UUID?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    private struct PoseOption {
        let id: String
        let pose: OpenAIService.CharacterViewSpec
    }

    private var allPoses: [PoseOption] {
        OpenAIService.extendedPoseGroups.flatMap { g in
            g.poses.map { PoseOption(id: "\(g.id)::\($0.label)", pose: $0) }
        }
    }

    private var pickedSpecs: [OpenAIService.CharacterViewSpec] {
        allPoses.filter { selected.contains($0.id) }.map(\.pose)
    }

    private var standardPortraitViews: [CharacterView] {
        character.views
            .filter(\.isStandardPortrait)
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.label < rhs.label
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private var selectedReferenceView: CharacterView? {
        if let selectedReferenceViewID,
           let view = standardPortraitViews.first(where: { $0.id == selectedReferenceViewID }) {
            return view
        }
        return standardPortraitViews.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("先选一张标准立绘做主参考，再勾选要生成的动作 / 镜头。所有勾选动作会被合成到一张全彩动作图里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    if let hero = selectedReferenceView,
                       let image = CharacterStore.shared.image(named: hero.imageName) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("当前主参考")
                                .font(.subheadline.bold())
                                .padding(.horizontal)
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal)
                            Text(hero.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    }

                    if !standardPortraitViews.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("切换参考图")
                                .font(.subheadline.bold())
                                .padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(standardPortraitViews) { view in
                                        if let image = CharacterStore.shared.image(named: view.imageName) {
                                            Button {
                                                selectedReferenceViewID = view.id
                                            } label: {
                                                VStack(alignment: .leading, spacing: 8) {
                                                    Image(uiImage: image)
                                                        .resizable()
                                                        .scaledToFill()
                                                        .frame(width: 110, height: 146)
                                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 12)
                                                                .stroke(
                                                                    selectedReferenceView?.id == view.id
                                                                    ? Color.accentColor
                                                                    : Color.gray.opacity(0.2),
                                                                    lineWidth: selectedReferenceView?.id == view.id ? 3 : 1
                                                                )
                                                        )
                                                    Text(view.label)
                                                        .font(.caption2.weight(.medium))
                                                        .foregroundStyle(.primary)
                                                        .lineLimit(2)
                                                }
                                                .frame(width: 110, alignment: .leading)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    ForEach(OpenAIService.extendedPoseGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title).font(.subheadline.bold())
                                .padding(.horizontal)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(group.poses.indices, id: \.self) { idx in
                                    let p = group.poses[idx]
                                    let optionId = "\(group.id)::\(p.label)"
                                    PoseChip(label: p.label,
                                             selected: selected.contains(optionId)) {
                                        if selected.contains(optionId) {
                                            selected.remove(optionId)
                                        } else {
                                            selected.insert(optionId)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("生成更多动作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        submit()
                    } label: {
                        Text(selected.isEmpty ? "生成" : "合成 \(selected.count) 个")
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear {
                if selectedReferenceViewID == nil {
                    selectedReferenceViewID = standardPortraitViews.first?.id
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    HStack {
                        Image(systemName: "moon.zzz.fill")
                        Text("会立刻关闭，AI 在后台按当前参考图风格生成 1 张全彩动作图（含 \(selected.count) 个动作，约 1~3 分钟）")
                            .font(.caption)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.indigo.opacity(0.15))
                }
            }
        }
    }

    private func submit() {
        let specs = pickedSpecs
        guard !specs.isEmpty else { return }

        let sourceImage: UIImage? = {
            if let v = selectedReferenceView,
               let img = CharacterStore.shared.image(named: v.imageName) { return img }
            if let n = character.sourcePhotoName,
               let img = CharacterStore.shared.image(named: n) { return img }
            if let v = character.preferredCoverView,
               let img = CharacterStore.shared.image(named: v.imageName) { return img }
            return nil
        }()
        guard let src = sourceImage else { return }

        let style = settings.defaultStyle
        let isColor = true
        let cId = character.id
        let cName = character.name

        // 标签 - 第几张动作合集
        let existingCount = CharacterStore.shared.characters
            .first { $0.id == cId }?
            .views.filter { $0.label.hasPrefix("动作合集") }.count ?? 0
        let label: String = existingCount == 0
            ? "动作合集"
            : "动作合集 \(existingCount + 1)"

        let jobId = JobStore.shared.startJob(
            style: style,
            kind: .characterViews,
            stageMessage: "已加入后台队列…",
            subtitle: "\(specs.count) 个动作合集 · \(cName) · 全彩",
            characterId: cId,
            characterName: cName,
            outputLabel: label
        )

        dismiss()

        let task = Task {
            do {
                let data = try await OpenAIService.shared.generatePoseSheet(
                    sourcePhoto: src,
                    name: cName,
                    bio: character.bio,
                    ageGroup: character.ageGroup,
                    gender: character.gender,
                    specs: specs,
                    style: style,
                    isColor: isColor,
                    size: "1024x1536",
                    quality: "medium",
                    jobId: jobId,
                    onStage: { msg in JobStore.shared.updateStage(jobId, msg) }
                )
                if Task.isCancelled { return }
                CharacterStore.shared.addViews(
                    to: cId,
                    views: [(label, data)]
                )
                JobStore.shared.complete(jobId, with: cId)
                LocalNotifier.notifyDone(
                    title: "动作合集完成",
                    body: "\(cName) · \(specs.count) 个动作"
                )
            } catch {
                resolveJobError(error, jobId: jobId, label: "动作合集")
            }
        }
        JobStore.shared.attachTask(task, to: jobId)
    }
}

private struct PoseChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(selected ? Color.accentColor.opacity(0.18) : Color(.systemGray6))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(selected ? Color.accentColor : Color.gray.opacity(0.2),
                                lineWidth: selected ? 2 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

// 创建角色：先生成标准立绘
struct CharacterCreateView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CharacterStore.shared

    @State private var name = ""
    @State private var bio = ""
    @State private var ageGroup: CharacterAgeGroup = .youngAdult
    @State private var gender: CharacterGender = .male
    @State private var photo: UIImage?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedStyles: Set<CharacterArtStyle> = [.jpAnime]

    private let styleColumns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    private var referencePhotoHint: String {
        var lines: [String] = []
        lines.append("📸 照片小贴士：")
        if ageGroup.isMinor {
            lines.append("• 你当前选的是「\(ageGroup.displayName)」：OpenAI 对真人儿童照片非常敏感，可能直接拦截，或者生成结果不稳定。")
            lines.append("• 这个年龄档位更适合作为角色设定信息，不能保证真人宝宝/儿童照片一定能成功转成角色。")
        } else {
            lines.append("• 半身或全身效果 > 大头自拍（V 字脸自拍角度容易被误判年龄）")
            lines.append("• 正常表情 > 卖萌 / 鬼脸")
            lines.append("• 光线清楚、面部正面或 3/4 角度最好")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("角色信息") {
                    TextField("名字（如：小明）", text: $name)
                    TextField("一句话设定（性格/身份）", text: $bio, axis: .vertical)
                        .lineLimit(2...4)
                    Picker("角色类型", selection: $ageGroup) {
                        ForEach(CharacterAgeGroup.allCases) { group in
                            Text(group.displayName).tag(group)
                        }
                    }
                    Picker("性别", selection: $gender) {
                        ForEach(CharacterGender.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    if let img = photo {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    PhotosPicker(selection: $pickerItems,
                                 maxSelectionCount: 1,
                                 matching: .images) {
                        Label(photo == nil ? "选一张照片" : "更换照片",
                              systemImage: "photo.on.rectangle")
                    }
                } header: {
                    Text("参考照片（必选）")
                } footer: {
                    Text(referencePhotoHint)
                        .font(.caption2)
                }
                Section("艺术风格（可多选，每选一个会单独生成一张标准立绘）") {
                    LazyVGrid(columns: styleColumns, spacing: 8) {
                        ForEach(CharacterArtStyle.allCases) { s in
                            ArtStyleChip(
                                style: s,
                                selected: selectedStyles.contains(s)
                            ) {
                                if selectedStyles.contains(s) {
                                    selectedStyles.remove(s)
                                } else {
                                    selectedStyles.insert(s)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                Section {
                    Label("点击「生成」立刻关闭窗口，AI 会先为每个所选艺术风格生成一张白背景彩色标准立绘。后续在角色详情页里还能继续生成高级设定图和动作合集。",
                          systemImage: "moon.zzz.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新建角色")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: pickerItems) { _, items in
                Task {
                    if let item = items.first,
                       let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        photo = img
                    }
                    pickerItems = []
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedStyles.count > 1 ? "生成 \(selectedStyles.count) 张" : "生成") {
                        submit()
                    }
                    .disabled(photo == nil || selectedStyles.isEmpty ||
                              name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// 把生成任务提交到后台，立即关闭弹窗。
    /// 多风格 → 逐个独立提交到后端队列，这样锁屏后也不依赖本地串行调度继续往下发。
    private func submit() {
        guard let img = photo else { return }
        guard !selectedStyles.isEmpty else { return }

        let created = store.create(name: name,
                                   bio: bio.isEmpty ? nil : bio,
                                   ageGroup: ageGroup,
                                   gender: gender,
                                   sourcePhoto: img.pngData())
        let characterId = created.id
        let characterName = created.name
        let imgSize = "1024x1536"
        let imgQuality = "medium"
        let bioText = bio.isEmpty ? nil : bio
        let styles = Array(selectedStyles).sorted { $0.displayName < $1.displayName }

        var jobInfos: [(jobId: UUID, artStyle: CharacterArtStyle, label: String)] = []
        for s in styles {
            let label = s.standardPortraitLabel
            let jobId = JobStore.shared.startJob(
                style: settings.defaultStyle,
                kind: .characterViews,
                stageMessage: "准备提交到服务器…",
                subtitle: "\(s.displayName)·\(characterName)·标准立绘",
                characterId: characterId,
                characterName: characterName,
                artStyle: s,
                outputLabel: label
            )
            jobInfos.append((jobId, s, label))
        }

        dismiss()

        for info in jobInfos {
            let task = Task {
                await runOnePortrait(
                    jobId: info.jobId,
                    characterId: characterId,
                    characterName: characterName,
                    bio: bioText,
                    ageGroup: ageGroup,
                    gender: gender,
                    photo: img,
                    artStyle: info.artStyle,
                    label: info.label,
                    size: imgSize,
                    quality: imgQuality
                )
            }
            JobStore.shared.attachTask(task, to: info.jobId)
        }
    }

    private func runOnePortrait(jobId: UUID,
                                characterId: UUID,
                                characterName: String,
                                bio: String?,
                                ageGroup: CharacterAgeGroup,
                                gender: CharacterGender,
                                photo: UIImage,
                                artStyle: CharacterArtStyle,
                                label: String,
                                size: String,
                                quality: String) async {
        do {
            let data = try await OpenAIService.shared.generateCharacterPortrait(
                sourcePhoto: photo,
                name: characterName,
                bio: bio,
                ageGroup: ageGroup,
                gender: gender,
                artStyle: artStyle,
                size: size,
                quality: quality,
                jobId: jobId,
                onStage: { msg in JobStore.shared.updateStage(jobId, msg) }
            )
            if Task.isCancelled { return }
            CharacterStore.shared.addViews(
                to: characterId,
                views: [(label, data)]
            )
            JobStore.shared.complete(jobId, with: characterId)
            LocalNotifier.notifyDone(
                title: "「\(artStyle.displayName)」标准立绘完成",
                body: characterName
            )
        } catch {
            resolveJobError(error, jobId: jobId, label: "\(artStyle.displayName) 标准立绘")
        }
    }
}

struct AdvancedCharacterSheetView: View {
    let character: Character
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CharacterStore.shared
    @State private var selectedStyles: Set<CharacterArtStyle> = [.jpAnime]
    @State private var selectedReferenceViewID: UUID?

    private let styleColumns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    private var current: Character {
        store.characters.first { $0.id == character.id } ?? character
    }

    private var sourcePhoto: UIImage? {
        current.sourcePhotoName.flatMap { store.image(named: $0) }
    }

    private var standardPortraitViews: [CharacterView] {
        current.views
            .filter(\.isStandardPortrait)
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.label < rhs.label
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private var selectedReferenceView: CharacterView? {
        if let selectedReferenceViewID,
           let view = standardPortraitViews.first(where: { $0.id == selectedReferenceViewID }) {
            return view
        }
        return standardPortraitViews.first
    }

    private func standardPortrait(for style: CharacterArtStyle) -> UIImage? {
        guard let view = current.views.first(where: { $0.label == style.standardPortraitLabel }) else {
            return nil
        }
        return store.image(named: view.imageName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("生成逻辑") {
                    Text("你可以先从这个角色已有的多张「标准立绘」里手动选一张做主参考；系统会优先使用这张主参考，再结合原始真人照片生成更复杂的高级设定图。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let hero = selectedReferenceView,
                   let image = store.image(named: hero.imageName) {
                    Section("当前主参考") {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(hero.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !standardPortraitViews.isEmpty {
                    Section("切换主参考") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(standardPortraitViews) { view in
                                    if let image = store.image(named: view.imageName) {
                                        Button {
                                            selectedReferenceViewID = view.id
                                        } label: {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Image(uiImage: image)
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 120, height: 160)
                                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 12)
                                                            .stroke(
                                                                selectedReferenceViewID == view.id || (selectedReferenceViewID == nil && selectedReferenceView?.id == view.id)
                                                                ? Color.accentColor
                                                                : Color.gray.opacity(0.2),
                                                                lineWidth: selectedReferenceViewID == view.id || (selectedReferenceViewID == nil && selectedReferenceView?.id == view.id)
                                                                ? 3
                                                                : 1
                                                            )
                                                    )

                                                Text(view.label)
                                                    .font(.caption2.weight(.medium))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(2)
                                            }
                                            .frame(width: 120, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("艺术风格（可多选，每选一个会单独生成一张高级设定图）") {
                    LazyVGrid(columns: styleColumns, spacing: 8) {
                        ForEach(CharacterArtStyle.allCases) { s in
                            ArtStyleChip(style: s, selected: selectedStyles.contains(s)) {
                                if selectedStyles.contains(s) {
                                    selectedStyles.remove(s)
                                } else {
                                    selectedStyles.insert(s)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }

                Section {
                    Label("高级设定图会比标准立绘复杂很多：主角色、表情区、服装拆解、生活物件、细节框和排版会一起生成，稳定性会稍低但信息量更高。",
                          systemImage: "rectangle.grid.2x2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("高级设定图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedStyles.count > 1 ? "生成 \(selectedStyles.count) 张" : "生成") {
                        submit()
                    }
                    .disabled(sourcePhoto == nil || selectedStyles.isEmpty)
                }
            }
            .onAppear {
                if selectedReferenceViewID == nil {
                    selectedReferenceViewID = standardPortraitViews.first?.id
                }
            }
        }
    }

    private func submit() {
        guard let sourcePhoto else { return }
        let styles = Array(selectedStyles).sorted { $0.displayName < $1.displayName }
        let imgSize = "1024x1536"
        let imgQuality = "medium"
        let bioText = current.bio
        let chosenReferenceImage = selectedReferenceView.flatMap { store.image(named: $0.imageName) }

        var jobInfos: [(jobId: UUID, artStyle: CharacterArtStyle, label: String)] = []
        for style in styles {
            let label = style.nextAdvancedSheetLabel(existingLabels: current.views.map(\.label))
            let jobId = JobStore.shared.startJob(
                style: settings.defaultStyle,
                kind: .characterViews,
                stageMessage: "准备提交到服务器…",
                subtitle: "\(style.displayName)·\(current.name)·高级设定图",
                characterId: current.id,
                characterName: current.name,
                artStyle: style,
                outputLabel: label
            )
            jobInfos.append((jobId, style, label))
        }

        dismiss()

        for info in jobInfos {
            let task = Task {
                await runOneAdvancedSheet(
                    jobId: info.jobId,
                    sourcePhoto: sourcePhoto,
                    basePortrait: chosenReferenceImage ?? standardPortrait(for: info.artStyle),
                    characterId: current.id,
                    characterName: current.name,
                    bio: bioText,
                    artStyle: info.artStyle,
                    label: info.label,
                    size: imgSize,
                    quality: imgQuality
                )
            }
            JobStore.shared.attachTask(task, to: info.jobId)
        }
    }

    private func runOneAdvancedSheet(jobId: UUID,
                                     sourcePhoto: UIImage,
                                     basePortrait: UIImage?,
                                     characterId: UUID,
                                     characterName: String,
                                     bio: String?,
                                     artStyle: CharacterArtStyle,
                                     label: String,
                                     size: String,
                                     quality: String) async {
        do {
            let data = try await OpenAIService.shared.generateAdvancedCharacterSheet(
                sourcePhoto: sourcePhoto,
                basePortrait: basePortrait,
                name: characterName,
                bio: bio,
                ageGroup: current.ageGroup,
                gender: current.gender,
                artStyle: artStyle,
                size: size,
                quality: quality,
                jobId: jobId,
                onStage: { msg in JobStore.shared.updateStage(jobId, msg) }
            )
            if Task.isCancelled { return }
            CharacterStore.shared.addViews(to: characterId, views: [(label, data)])
            JobStore.shared.complete(jobId, with: characterId)
            LocalNotifier.notifyDone(
                title: "「\(artStyle.displayName)」高级设定图完成",
                body: characterName
            )
        } catch {
            resolveJobError(error, jobId: jobId, label: "\(artStyle.displayName) 高级设定图")
        }
    }
}

// MARK: - 艺术风格选择卡

private struct ArtStyleChip: View {
    let style: CharacterArtStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.accentColor.opacity(0.18) : Color(.systemGray6))
                    Image(systemName: style.symbolName)
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    if selected {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.white, .indigo)
                                    .padding(4)
                            }
                            Spacer()
                        }
                    }
                }
                .frame(height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.accentColor : Color.gray.opacity(0.2),
                                lineWidth: selected ? 2 : 1)
                )

                Text(style.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                Text(style.subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: ──────────────────────────────────────── 发布 Tab ─────

struct PublishView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 64))
                .foregroundStyle(.indigo.opacity(0.5))
            Text("发布功能即将推出")
                .font(.title3.weight(.semibold))
            Text("未来可以把工程导出成 PDF 漫画书、生成长图、\n或一键发布到社交平台。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("发布")
    }
}
