//
//  SettingsView.swift
//  LifeManga
//
//  - VPS 后端地址 / API Key 配置（Key 保存到 Keychain）
//  - 默认漫画风格选择
//  - 生成参数（数量、分辨率、质量）
//

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject var settings: AppSettings
    @State private var backendURLInput: String = ""
    @State private var backendKeyInput: String = ""
    @State private var showSavedToast = false

    var body: some View {
        NavigationStack {
            Form {

                // MARK: Backend
                Section {
                    TextField("https://manga.areu.pro", text: $backendURLInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    TextField("后端 API Key", text: $backendKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button {
                            saveBackendConfig()
                        } label: {
                            Label("保存后端配置", systemImage: "externaldrive.badge.checkmark")
                        }
                        .disabled(backendURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                  backendKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        if settings.hasBackendAPIKey {
                            Button(role: .destructive) {
                                KeychainService.shared.deleteBackendAPIKey()
                                settings.refreshBackendStatus()
                                backendKeyInput = ""
                            } label: {
                                Text("清除 Key").font(.subheadline)
                            }
                        }
                    }
                } header: {
                    Text("漫画后端")
                } footer: {
                    Text("这里填你的 VPS 后端地址和后端 API Key。Key 只保存在这台设备的 iOS Keychain 里；真正的 OpenAI Key 只放在你的服务器上，不再放在手机端。")
                }

                // MARK: 默认风格
                Section("默认漫画风格") {
                    Picker("默认风格", selection: Binding(
                        get: { settings.defaultStyle },
                        set: { settings.defaultStyle = $0 })
                    ) {
                        ForEach(MangaStyle.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    NavigationLink {
                        StyleGalleryView()
                    } label: {
                        Label("浏览全部风格", systemImage: "books.vertical")
                    }
                }

                // MARK: 生成参数
                Section {
                    Stepper("一次生成 \(settings.imageCount) 张",
                            value: $settings.imageCount,
                            in: 1...4)

                    Picker("分辨率", selection: $settings.imageSize) {
                        ForEach(AppSettings.availableSizes, id: \.self) { Text($0) }
                    }

                    Picker("画质", selection: $settings.imageQuality) {
                        ForEach(AppSettings.availableQualities, id: \.self) { q in
                            Text(qualityLabel(q)).tag(q)
                        }
                    }
                } header: {
                    Text("生成参数")
                } footer: {
                    Text("画质越高越慢、消耗的 OpenAI 额度越多。建议先用 medium 试。")
                }

                // MARK: 色彩
                Section {
                    Toggle(isOn: $settings.isColor) {
                        HStack {
                            Image(systemName: settings.isColor ? "paintpalette.fill" : "circle.lefthalf.filled")
                                .foregroundStyle(settings.isColor ? .pink : .primary)
                            Text(settings.isColor ? "默认全彩" : "默认黑白")
                        }
                    }
                } header: {
                    Text("色彩模式")
                } footer: {
                    Text("主页可以随时切换，这里只是设定默认值。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("漫画感强度")
                            Spacer()
                            Text(settings.mangaStylizationLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.mangaStylizationStrength, in: 0...1, step: 0.05)
                        HStack {
                            Text("偏实景")
                            Spacer()
                            Text("偏漫画")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("漫画感")
                } footer: {
                    Text("控制“照片参考”到“漫画重绘”的力度。漫画人生适合偏高；导航案内建议偏低，这样更容易保留道路、地标、招牌和可识别场景。")
                }

                // MARK: 对话框
                Section {
                    Picker("对话框模式", selection: $settings.bubbleTextMode) {
                        ForEach(AppSettings.bubbleTextModes, id: \.id) { item in
                            Text(item.label).tag(item.id)
                        }
                    }
                } header: {
                    Text("对话框")
                } footer: {
                    Text("普通模式 + 故事模式都生效。\n• 中文：气泡里画中文台词（推荐）\n• 日语：气泡里画日语台词，允许汉字和假名\n• 英文：海外漫画风\n• 留空：画出气泡造型但不写字\n• 无对话框：完全不画对话框，纯视觉漫画")
                }

                // MARK: 故事模式
                Section {
                    Toggle("默认开启故事模式", isOn: $settings.storyModeOn)
                    Picker("默认分镜数", selection: $settings.panelCount) {
                        ForEach([4, 6, 8], id: \.self) { Text("\($0) 格").tag($0) }
                    }
                    Picker("编剧模型", selection: $settings.scriptModel) {
                        Text("gpt-5.4-nano（最快最便宜）").tag("gpt-5.4-nano")
                        Text("gpt-5.4-mini（推荐，平衡）").tag("gpt-5.4-mini")
                        Text("gpt-5.5（最聪明，更贵）").tag("gpt-5.5")
                    }
                } header: {
                    Text("故事模式")
                } footer: {
                    Text("故事模式会先用视觉模型读图编剧本（中文+日文双语），再用 gpt-image-2 渲染成多格漫画页。会消耗更多 token。")
                }

                // MARK: 关于
                Section("关于") {
                    LabeledContent("App 名称", value: "漫画人生")
                    LabeledContent("图片模型", value: "gpt-image-2（服务端调用）")
                    LabeledContent("版本", value: "1.0.0")
                    Link(destination: URL(string: settings.normalizedBackendBaseURL) ?? URL(string: "https://manga.areu.pro")!) {
                        Label("打开漫画后端", systemImage: "safari")
                    }
                }
            }
            .onAppear {
                if backendURLInput.isEmpty {
                    backendURLInput = settings.normalizedBackendBaseURL
                }
                if backendKeyInput.isEmpty {
                    backendKeyInput = KeychainService.shared.loadBackendAPIKey() ?? ""
                }
            }
            .navigationTitle("设置")
            .overlay(alignment: .top) {
                if showSavedToast {
                    Text("已保存 ✓")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            withAnimation { showSavedToast = false }
                        }
                }
            }
        }
    }

    private func saveBackendConfig() {
        let trimmedURL = backendURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty {
            settings.backendBaseURL = trimmedURL
        }

        let trimmedKey = backendKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            KeychainService.shared.saveBackendAPIKey(trimmedKey)
        }

        settings.refreshBackendStatus()
        backendURLInput = settings.normalizedBackendBaseURL
        withAnimation { showSavedToast = true }
    }

    private func qualityLabel(_ q: String) -> String {
        switch q {
        case "low":    return "低（快/省）"
        case "medium": return "中（推荐）"
        case "high":   return "高（精细/慢）"
        case "auto":   return "自动"
        default:       return q
        }
    }
}

// MARK: - 风格画廊（展示全部风格的描述）

struct StyleGalleryView: View {
    var body: some View {
        List(MangaStyle.allCases) { s in
            HStack(alignment: .center, spacing: 12) {
                StylePreviewIcon(style: s, size: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.displayName).font(.headline)
                    Text(s.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("漫画风格")
    }
}
