//
//  HomeView.swift
//  LifeManga
//
//  主功能页：选图 → 选风格 →（可选）打开故事模式 → 生成 → 预览 → 保存到历史
//

import SwiftUI
import PhotosUI
import Photos

struct HomeView: View {
    let project: MangaProject

    @EnvironmentObject var settings: AppSettings
    @StateObject private var vm: MangaGeneratorViewModel
    @ObservedObject private var storage = MangaStorage.shared

    init(project: MangaProject) {
        self.project = project
        _vm = StateObject(wrappedValue: MangaGeneratorViewModel(
            projectId: project.id,
            projectName: project.name,
            projectMode: project.mode
        ))
    }

    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var detailItem: MangaItem?
    // "前一张" 选择器
    @State private var showPrevPickerSheet = false
    @State private var showPrevLibrary = false
    @State private var prevPickerItems: [PhotosPickerItem] = []
    // 角色选择
    @State private var showCharacterPicker = false
    @State private var draggingInputID: UUID?

    private var maxInputImageCount: Int {
        MangaGeneratorViewModel.maxInputImageCount(forPageCount: settings.imageCount)
    }

    private var isNavigationMode: Bool {
        project.mode == .navigationGuide
    }

    private var remainingInputImageSlots: Int {
        max(0, maxInputImageCount - vm.selectedInputs.count)
    }

    private var canAddMoreInputImages: Bool {
        remainingInputImageSlots > 0
    }

    private var inputLimitHint: String {
        if settings.imageCount <= 1 {
            return "可以拍 1~6 张照片，或从相册选"
        }
        return "当前是 \(settings.imageCount) 页模式，最多可选 \(maxInputImageCount) 张素材；系统会按每页最多 6 张自动分组连续生成"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                inputSection
                previousPageSection
                charactersSection
                if isNavigationMode {
                    navigationGuideSection
                } else {
                    styleSection
                }
                colorModeSection
                diaryModeSection
                bubbleModeSection
                if !isNavigationMode {
                    storyModeSection
                }
                promptSection
                generateButton

                if vm.isBlockingGenerate { progressSection }

                if vm.generatedScript != nil {
                    editableScriptCard
                }

                if !vm.generatedImages.isEmpty { resultSection }
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: vm.reset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(vm.selectedImages.isEmpty && vm.generatedImages.isEmpty)
            }
        }
        // 相机
        .sheet(isPresented: $showCamera) {
            ImagePickerView(sourceType: .camera) { img, _ in
                Task {
                    let stamp = settings.diaryModeOn ? DiaryStamp(capturedAt: Date(), weatherText: nil) : nil
                    if !vm.addImage(img, diaryStamp: stamp, maxCount: maxInputImageCount) {
                        await MainActor.run {
                            vm.toastMessage = "当前最多可添加 \(maxInputImageCount) 张素材"
                        }
                    }
                }
            }
            .ignoresSafeArea()
        }
        // 相册多选
        .photosPicker(isPresented: $showLibrary,
                      selection: $photoPickerItems,
                      maxSelectionCount: max(1, remainingInputImageSlots),
                      matching: .images)
        .onChange(of: photoPickerItems) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        let stamp = settings.diaryModeOn ? await diaryStamp(for: item) : nil
                        if !vm.addImage(img, diaryStamp: stamp, maxCount: maxInputImageCount) {
                            await MainActor.run {
                                vm.toastMessage = "当前最多可添加 \(maxInputImageCount) 张素材"
                            }
                            break
                        }
                    }
                }
                photoPickerItems = []
            }
        }
        .onAppear {
            vm.style = isNavigationMode ? .navigationGuide : settings.defaultStyle
            vm.storyMode = isNavigationMode ? false : settings.storyModeOn
            vm.panelCount = settings.panelCount
            vm.bubbleTextMode = settings.bubbleTextMode
            vm.isColor = isNavigationMode ? true : settings.isColor
        }
        .overlay(alignment: .top) {
            if let toastMessage = vm.toastMessage {
                Text(toastMessage)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation { vm.toastMessage = nil }
                    }
            }
        }
        .alert(vm.errorIsSafetyBlocked ? "图片被安全系统拒绝" : "出错了",
               isPresented: .init(
                   get: { vm.errorMessage != nil },
                   set: { if !$0 { vm.errorMessage = nil } })
        ) {
            if vm.errorIsSafetyBlocked {
                Button("我知道了", role: .cancel) { vm.errorMessage = nil }
            } else {
                Button("立即重试") {
                    vm.errorMessage = nil
                    vm.startGenerate(settings: settings)
                }
                Button("好", role: .cancel) { vm.errorMessage = nil }
            }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .sheet(item: $detailItem) { item in
            NavigationStack { MangaDetailView(item: item) }
                .environmentObject(settings)
        }
        // 前一张：选择来源（本工程历史 vs 相册）
        .sheet(isPresented: $showPrevPickerSheet) {
            PreviousPagePickerSheet(
                project: project,
                onPickHistory: { item in
                    if let name = item.outputImageNames.first,
                       let img = storage.image(named: name) {
                        vm.previousPageImage = img
                        vm.previousPageSourceId = item.id
                    }
                    showPrevPickerSheet = false
                },
                onPickLibrary: {
                    showPrevPickerSheet = false
                    showPrevLibrary = true
                }
            )
            .presentationDetents([.medium, .large])
        }
        // 角色库选择
        .sheet(isPresented: $showCharacterPicker) {
            CharacterPickerSheet(
                selected: vm.loadedCharacters.map { $0.id },
                selectedReferenceViewIDs: vm.selectedCharacterReferenceViewIDs,
                onToggle: { character, view in
                    if vm.loadedCharacters.contains(where: { $0.id == character.id }) {
                        vm.loadCharacter(character, referenceViewID: view?.id)
                    } else {
                        vm.loadCharacter(character, referenceViewID: view?.id)
                    }
                },
                onRemove: { character in
                    vm.unloadCharacter(character)
                }
            )
            .presentationDetents([.medium, .large])
        }
        // 前一张：从相册选
        .photosPicker(isPresented: $showPrevLibrary,
                      selection: $prevPickerItems,
                      maxSelectionCount: 1,
                      matching: .images)
        .onChange(of: prevPickerItems) { _, items in
            Task {
                if let item = items.first,
                   let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    vm.previousPageImage = img
                    vm.previousPageSourceId = nil
                }
                prevPickerItems = []
            }
        }
    }

    // MARK: - 子视图

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 选择素材图片").font(.headline)

            if vm.selectedImages.isEmpty {
                placeholderRow
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(vm.selectedInputs.enumerated()), id: \.element.id) { idx, input in
                            ZStack(alignment: .topTrailing) {
                                ZStack(alignment: .bottomLeading) {
                                    Image(uiImage: input.image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 110, height: 110)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))

                                    Text("\(idx + 1)")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(.black.opacity(0.7), in: Capsule())
                                        .padding(8)
                                }
                                Button { vm.removeImage(at: idx) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.7))
                                        .font(.title3)
                                }
                                .offset(x: 6, y: -6)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(draggingInputID == input.id ? Color.accentColor : .clear, lineWidth: 3)
                            )
                            .scaleEffect(draggingInputID == input.id ? 1.04 : 1.0)
                            .animation(.spring(duration: 0.22), value: draggingInputID)
                            .onDrag {
                                draggingInputID = input.id
                                return NSItemProvider(object: input.id.uuidString as NSString)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let source = items.first,
                                      let sourceID = UUID(uuidString: source) else { return false }
                                vm.moveSelectedInput(id: sourceID, before: input.id)
                                draggingInputID = nil
                                return true
                            } isTargeted: { targeted in
                                if !targeted, draggingInputID == input.id {
                                    draggingInputID = nil
                                }
                            }
                        }
                    }
                }
                Text("长按图片可拖动排序；导航案内会尽量按这个顺序排步骤。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    showCamera = true
                } label: {
                    Label("拍照", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera) || !canAddMoreInputImages)

                Button {
                    showLibrary = true
                } label: {
                    Label("从相册选", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canAddMoreInputImages)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var placeholderRow: some View {
        HStack {
            Image(systemName: "photo.stack")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text("还没有图片").font(.subheadline)
                Text(inputLimitHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 角色（载入角色库里的角色）
    private var charactersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.crop.rectangle.stack.fill")
                    .foregroundStyle(.indigo)
                Text("角色").font(.headline)
                Spacer()
                Button {
                    showCharacterPicker = true
                } label: {
                    Label("从角色库选", systemImage: "plus.circle")
                        .font(.caption)
                }
            }
            if vm.loadedCharacters.isEmpty {
                Text("可选。从「角色库」里选一个或多个角色，AI 会把他们画进剧情，保持角色形象一致。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(vm.loadedCharacters) { c in
                            ZStack(alignment: .topTrailing) {
                                LoadedCharacterChip(character: c,
                                                    selectedView: vm.selectedReferenceView(for: c))
                                Button { vm.unloadCharacter(c) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 前一张（续接）
    private var previousPageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "rectangle.stack.fill.badge.plus")
                    .foregroundStyle(.indigo)
                Text("前一张").font(.headline)
                Spacer()
                if vm.previousPageImage != nil {
                    Button("移除", action: vm.clearPreviousPage)
                        .font(.caption)
                }
            }
            if let img = vm.previousPageImage {
                HStack(alignment: .top, spacing: 10) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 90, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已设为续接基准")
                            .font(.subheadline.weight(.medium))
                        Text("AI 会保持画风、角色和故事的延续。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            showPrevPickerSheet = true
                        } label: {
                            Label("换一张", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
            } else {
                Button {
                    showPrevPickerSheet = true
                } label: {
                    HStack {
                        Image(systemName: "plus.rectangle.on.rectangle")
                        Text("选一张前作").font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                Text("可选。把上一张漫画作为参考，让 AI 延续相同的画风、角色和故事走向。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("2. 选择漫画风格").font(.headline)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(MangaStyle.allCases) { s in
                        StyleChip(style: s, selected: s == vm.style) {
                            vm.style = s
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var navigationGuideSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "map.fill")
                    .foregroundStyle(.green)
                Text("2. 导览设置").font(.headline)
                Spacer()
                Label("导航案内", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
            Text("这一模式会把地图俯视图、街景截图和角色向导一起组织成路线说明漫画。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("起点").font(.subheadline.weight(.medium))
                TextField("例如：东京站八重洲口", text: $vm.navigationStart)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("终点").font(.subheadline.weight(.medium))
                TextField("例如：酒店 / 咖啡店 / 某个景点入口", text: $vm.navigationDestination)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("途经点 / 地标（每行一个，可选）").font(.subheadline.weight(.medium))
                TextField("例如：\n7-Eleven 路口\n地铁 A2 出口\n红色天桥", text: $vm.navigationWaypoints, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("导览强度").font(.subheadline.weight(.medium))
                Spacer()
                Picker("", selection: $vm.navigationStrength) {
                    ForEach(NavigationGuideStrength.allCases) { strength in
                        Text(strength.displayName).tag(strength)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 色彩模式
    private var colorModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "paintpalette")
                Text("色彩").font(.headline)
                Spacer()
            }
            HStack(spacing: 10) {
                ColorModeCard(isColor: false, selected: !vm.isColor) { vm.isColor = false }
                ColorModeCard(isColor: true,  selected: vm.isColor)  { vm.isColor = true }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var diaryModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(.indigo)
                Text("日记模式").font(.headline)
                Spacer()
                Toggle("", isOn: $settings.diaryModeOn)
                    .labelsHidden()
            }
            Text(settings.diaryModeOn
                 ? diaryModeHint()
                 : "打开后，系统会优先读取第一张照片的拍摄时间；如果照片带定位，还会尝试自动附加当天当地天气，让漫画更像日记页。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if settings.diaryModeOn {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("补强日期戳")
                            .font(.subheadline.weight(.medium))
                        Text("AI 没把日期稳定画出来时，再额外叠一张本地日期卡片；如果 AI 已经画出来了，可以关掉避免重复。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.diaryOverlayAssistOn)
                        .labelsHidden()
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 对话框模式（全局，故事模式 + 普通模式都生效）
    private var bubbleModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.indigo)
                Text("对话框").font(.headline)
                Spacer()
            }
            // 5 个模式：中文 / 日文 / 英文 / 留空 / 无
            // segmented 一行装不下 5 个，用 horizontal scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AppSettings.bubbleTextModes, id: \.id) { mode in
                        BubbleModeChip(
                            id: mode.id,
                            label: mode.label,
                            selected: vm.bubbleTextMode == mode.id
                        ) {
                            vm.bubbleTextMode = mode.id
                        }
                    }
                }
            }
            Text(currentBubbleHint())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func currentBubbleHint() -> String {
        AppSettings.bubbleTextModes.first { $0.id == vm.bubbleTextMode }?.hint ?? ""
    }

    private func diaryModeHint() -> String {
        if let stamp = vm.activeDiaryStamp {
            if let weather = stamp.weatherText, !weather.isEmpty {
                return "将按第一张照片生成日记戳：\(stamp.dateText) · \(weather)"
            }
            return "将按第一张照片生成日记戳：\(stamp.dateText) · 未读到天气"
        }
        return "已开启。优先读取第一张照片的拍摄时间；如果暂时没读到元数据，也会自动用当前日期补一个日记戳。"
    }

    private func diaryStamp(for item: PhotosPickerItem) async -> DiaryStamp? {
        guard let identifier = item.itemIdentifier else { return nil }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject else { return nil }
        let capturedAt = asset.creationDate ?? Date()
        let weather: String?
        if let location = asset.location {
            weather = await DiaryWeatherService.shared.weatherText(for: location.coordinate, at: capturedAt)
        } else {
            weather = nil
        }
        return DiaryStamp(capturedAt: capturedAt, weatherText: weather)
    }

    // MARK: 故事模式区
    private var storyModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: $vm.storyMode) {
                    HStack(spacing: 6) {
                        Image(systemName: "book.pages.fill")
                            .foregroundStyle(.indigo)
                        Text("故事模式").font(.headline)
                    }
                }
                .tint(.indigo)
            }

            Text(vm.storyMode
                 ? "AI 会根据你的图片自由脑补一段剧情，配上对白，画成多格漫画页。分镜数量由 AI 决定，不一定等于图片数。"
                 : "关：直接把照片转成单张漫画风格图。开：根据图片编一段故事并画成多格漫画。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if vm.storyMode {
                HStack {
                    Text("分镜格数").font(.subheadline)
                    Spacer()
                    Picker("", selection: $vm.panelCount) {
                        ForEach([4, 6, 8], id: \.self) { Text("\($0) 格").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(promptSectionTitle)
                .font(.headline)
            TextField(promptPlaceholder,
                      text: $vm.userPrompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var promptSectionTitle: String {
        if isNavigationMode { return "3. 导览补充说明（可选）" }
        return vm.storyMode ? "3. 故事方向（可选）" : "3. 补充描述（可选）"
    }

    private var promptPlaceholder: String {
        if isNavigationMode {
            return "例如：突出便利店招牌、让角色多做指路手势、在终点加到达提示"
        }
        return vm.storyMode
            ? "例如：悬疑 / 父子情 / 一场误会 / 穿越异世界"
            : "例如：把主角画成戴墨镜的中学生"
    }

    @ViewBuilder
    private var generateButton: some View {
        switch vm.phase {
        case .scriptReady:
            // 剧本已就绪：让用户选择"重新构思"或"用这个剧本作画"
            HStack(spacing: 10) {
                Button {
                    vm.startRegenerateScript(settings: settings)
                } label: {
                    Label("重新构思", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button {
                    vm.startGenerate(settings: settings)
                } label: {
                    Label("用这个剧本作画", systemImage: "paintbrush.pointed.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }

        default:
            Button {
                vm.startGenerate(settings: settings)
            } label: {
                HStack {
                    Image(systemName: vm.storyMode ? "book.pages.fill" : "wand.and.stars")
                    Text(buttonLabel)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isBlockingGenerate || vm.selectedImages.isEmpty)
        }
    }

    private var buttonLabel: String {
        if vm.isBlockingGenerate { return "正在生成…" }
        if isNavigationMode { return "生成导览漫画" }
        return vm.storyMode ? "构思剧情" : "生成漫画"
    }

    private var progressSection: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(vm.stageMessage.isEmpty
                 ? "AI 正在挥笔作画…"
                 : vm.stageMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(progressHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // 后台执行提示
            if vm.phase == .generatingImage {
                Label("可以锁屏 / 切到别的 App，完成后会推送通知", systemImage: "moon.zzz.fill")
                    .font(.caption2)
                    .foregroundStyle(.indigo)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var progressHint: String {
        switch vm.phase {
        case .generatingScript: return "编剧只需 10~30 秒"
        case .generatingImage:  return vm.storyMode ? "分镜作画约 1~3 分钟" : "约 30~90 秒"
        default: return ""
        }
    }

    // MARK: 可编辑剧本卡

    @ViewBuilder
    private var editableScriptCard: some View {
        if vm.generatedScript != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "scroll.fill")
                        .foregroundStyle(.indigo)
                    Text(vm.phase == .scriptReady ? "剧本（可编辑）" : "剧本")
                        .font(.headline)
                    Spacer()
                    Text("\(vm.generatedScript?.panels.count ?? 0) 格")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if vm.phase == .scriptReady {
                    Text("AI 帮你写好了剧本草稿。你可以直接修改里面任何一格的描述、对白、旁白、拟声词，然后再点「用这个剧本作画」。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // 标题
                if vm.phase == .scriptReady {
                    TextField("漫画标题", text: titleBinding())
                        .font(.title3.bold())
                        .textFieldStyle(.roundedBorder)
                    TextField("剧情简介（一句话）", text: synopsisBinding(), axis: .vertical)
                        .lineLimit(2...4)
                        .font(.subheadline)
                        .textFieldStyle(.roundedBorder)
                } else {
                    if let s = vm.generatedScript {
                        Text(s.title).font(.title3).bold()
                        Text(s.synopsis).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Divider()

                // 各分镜
                if let count = vm.generatedScript?.panels.count {
                    ForEach(0..<count, id: \.self) { idx in
                        panelEditor(index: idx)
                        if idx < count - 1 {
                            Divider().padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding()
            .background(Color.indigo.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private func panelEditor(index idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("第 \(idx + 1) 格")
                .font(.caption).bold()
                .foregroundStyle(.indigo)

            if vm.phase == .scriptReady {
                // 编辑模式
                fieldLabel("画面描述（英文，给绘图模型看）", icon: "photo")
                TextField("", text: panelFieldBinding(idx, \.description), axis: .vertical)
                    .lineLimit(2...4)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)

                fieldLabel("对白（角色：内容）", icon: "bubble.left.fill")
                TextField("（无对白则留空）", text: panelOptionalBinding(idx, \.dialogue), axis: .vertical)
                    .lineLimit(1...3)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)

                fieldLabel("旁白", icon: "text.alignleft")
                TextField("（无旁白则留空）", text: panelOptionalBinding(idx, \.narration), axis: .vertical)
                    .lineLimit(1...3)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)

                fieldLabel("拟声词", icon: "burst.fill")
                TextField("（如「ドン!」「砰!」）", text: panelOptionalBinding(idx, \.sfx))
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
            } else {
                // 只读
                if let p = vm.generatedScript?.panels[idx] {
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
            }
        }
        .padding(.vertical, 4)
    }

    private func fieldLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    // MARK: - Bindings

    private func titleBinding() -> Binding<String> {
        Binding(
            get: { vm.generatedScript?.title ?? "" },
            set: { newVal in vm.generatedScript?.title = newVal }
        )
    }

    private func synopsisBinding() -> Binding<String> {
        Binding(
            get: { vm.generatedScript?.synopsis ?? "" },
            set: { newVal in vm.generatedScript?.synopsis = newVal }
        )
    }

    /// 必填字段（description）的 Binding
    private func panelFieldBinding(_ idx: Int,
                                   _ keyPath: WritableKeyPath<MangaPanel, String>) -> Binding<String> {
        Binding(
            get: {
                guard let panels = vm.generatedScript?.panels,
                      panels.indices.contains(idx) else { return "" }
                return panels[idx][keyPath: keyPath]
            },
            set: { newVal in
                guard vm.generatedScript?.panels.indices.contains(idx) == true else { return }
                vm.generatedScript?.panels[idx][keyPath: keyPath] = newVal
            }
        )
    }

    /// 可选字段（dialogue / narration / sfx）的 Binding —— 空字符串视为 nil
    private func panelOptionalBinding(_ idx: Int,
                                      _ keyPath: WritableKeyPath<MangaPanel, String?>) -> Binding<String> {
        Binding(
            get: {
                guard let panels = vm.generatedScript?.panels,
                      panels.indices.contains(idx) else { return "" }
                let v = panels[idx][keyPath: keyPath] ?? ""
                return v.lowercased() == "null" ? "" : v
            },
            set: { newVal in
                guard vm.generatedScript?.panels.indices.contains(idx) == true else { return }
                let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                vm.generatedScript?.panels[idx][keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("生成结果").font(.headline)
            ForEach(Array(vm.generatedImages.enumerated()), id: \.offset) { _, img in
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            }
            if let saved = vm.lastSaved {
                Button {
                    detailItem = saved
                } label: {
                    Label("查看详情 / 分享 / 收藏", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.top, 6)
            }
        }
    }
}

// MARK: - Bubble Mode Chip

private struct BubbleModeChip: View {
    let id: String
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor.opacity(0.15) : Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(selected ? Color.accentColor : Color.gray.opacity(0.25),
                                lineWidth: selected ? 2 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Color Mode Card

private struct ColorModeCard: View {
    let isColor: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ColorModePreview(isColor: isColor, size: 28)
                Text(isColor ? "全彩" : "黑白").font(.subheadline.weight(.medium))
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor.opacity(0.12) : Color(.systemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: selected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 已载入角色的小卡

private struct LoadedCharacterChip: View {
    let character: Character
    let selectedView: CharacterView?
    @ObservedObject private var store = CharacterStore.shared

    private var thumb: UIImage? {
        if let v = selectedView ?? character.preferredCoverView {
            return store.image(named: v.imageName)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray4))
                if let img = thumb {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill").foregroundStyle(.secondary)
                }
            }
            .frame(width: 70, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(character.name).font(.caption2).lineLimit(1)
        }
        .frame(width: 80)
    }
}

// MARK: - 角色选择器（从角色库挑）

private struct CharacterPickerSheet: View {
    let selected: [UUID]
    let selectedReferenceViewIDs: [UUID: UUID]
    let onToggle: (Character, CharacterView?) -> Void
    let onRemove: (Character) -> Void
    @ObservedObject private var store = CharacterStore.shared
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if store.characters.isEmpty {
                    ContentUnavailableView(
                        "角色库还是空的",
                        systemImage: "person.crop.rectangle.stack",
                        description: Text("先去「角色库」Tab 创建一个角色吧")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(store.characters) { c in
                                Button {
                                    let view = selectedView(for: c)
                                    onToggle(c, view)
                                } label: {
                                    pickerCell(c)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("选择角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func pickerCell(_ c: Character) -> some View {
        let isSelected = selected.contains(c.id)
        let view = selectedView(for: c)
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray5))
                if let v = view,
                   let img = store.image(named: v.imageName) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .indigo)
                        .padding(6)
                }
            }
            .frame(width: 90, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.indigo : Color.clear, lineWidth: 2)
            )
            Text(c.name).font(.caption).lineLimit(1)
            if c.views.count > 1 {
                Text(view?.label ?? "选择风格")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            if c.views.count > 1 {
                Menu {
                    ForEach(c.views) { view in
                        Button {
                            onToggle(c, view)
                        } label: {
                            if selectedReferenceViewIDs[c.id] == view.id {
                                Label(view.label, systemImage: "checkmark")
                            } else {
                                Text(view.label)
                            }
                        }
                    }
                    if isSelected {
                        Divider()
                        Button("移除角色", role: .destructive) {
                            onRemove(c)
                        }
                    }
                } label: {
                    Label("切换风格", systemImage: "swatchpalette")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func selectedView(for character: Character) -> CharacterView? {
        if let selectedID = selectedReferenceViewIDs[character.id],
           let view = character.views.first(where: { $0.id == selectedID }) {
            return view
        }
        return character.referencePortraitView ?? character.preferredCoverView
    }
}

// MARK: - 前一张选择器（本工程历史 / 相册）

private struct PreviousPagePickerSheet: View {
    let project: MangaProject
    let onPickHistory: (MangaItem) -> Void
    let onPickLibrary: () -> Void

    @ObservedObject private var storage = MangaStorage.shared

    private var historyItems: [MangaItem] {
        storage.items(in: project.id)
    }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 从相册选
                Button(action: onPickLibrary) {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title3)
                            .foregroundStyle(.indigo)
                        VStack(alignment: .leading) {
                            Text("从相册选").font(.subheadline.weight(.medium))
                            Text("用一张外部图片作为风格基准")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                }
                .buttonStyle(.plain)
                .background(Color(.systemBackground))

                Divider()

                // 本工程历史
                if historyItems.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("这个工程还没有作品")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(historyItems) { item in
                                Button {
                                    onPickHistory(item)
                                } label: {
                                    historyThumb(item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("选择前一张")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func historyThumb(_ item: MangaItem) -> some View {
        if let name = item.outputImageNames.first,
           let img = storage.image(named: name) {
            VStack(spacing: 4) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 130)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Style Chip

private struct StyleChip: View {
    let style: MangaStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                StylePreviewIcon(style: style, size: 44)
                Text(style.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}
