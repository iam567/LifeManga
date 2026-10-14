//
//  AppSettings.swift
//  LifeManga
//
//  全局可观察的应用设置。后端 API Key 不在这里 —— 它存在 Keychain。
//

import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    nonisolated static let backendBaseURLKey = "backendBaseURL"
    nonisolated static let diaryOverlayAssistKey = "diaryOverlayAssistOn"
    nonisolated static let mangaStylizationStrengthKey = "mangaStylizationStrength"

    // MARK: - 用户偏好（持久化到 UserDefaults）

    @AppStorage("backendBaseURL") var backendBaseURL: String = "https://manga.areu.pro"
    @AppStorage("defaultStyle")    private var defaultStyleRaw: String = MangaStyle.shonenJump.rawValue
    @AppStorage("imageCount")      var imageCount: Int = 1
    @AppStorage("imageSize")       var imageSize: String = "1024x1536"
    @AppStorage("imageQuality")    var imageQuality: String = "medium"
    /// 故事模式开关
    @AppStorage("storyModeOn")     var storyModeOn: Bool = false
    /// 故事模式分镜格数
    @AppStorage("panelCount")      var panelCount: Int = 6
    /// 故事模式使用的视觉/编剧模型（GPT-5 系列，2026 年最新）
    @AppStorage("scriptModel")     var scriptModel: String = "gpt-5.4-mini"
    /// 气泡内文字渲染模式: "chinese" / "japanese" / "english" / "empty" / "none"
    /// gpt-image-2 已经能很好地渲染中文，所以默认用 "chinese"
    @AppStorage("bubbleTextMode")  var bubbleTextMode: String = "chinese"
    /// 全局色彩开关：true 彩色 / false 黑白
    @AppStorage("colorMode")       var isColor: Bool = false
    /// 漫画化强度：0 = 偏实景参照，1 = 偏强漫画改编
    @AppStorage("mangaStylizationStrength") var mangaStylizationStrength: Double = 0.78
    /// 日记模式：自动读取照片拍摄时间并尝试附加天气戳
    @AppStorage("diaryModeOn")     var diaryModeOn: Bool = false
    /// 日记模式下是否额外补强一个本地日期戳卡片
    @AppStorage("diaryOverlayAssistOn") var diaryOverlayAssistOn: Bool = true

    static let bubbleTextModes: [(id: String, label: String, hint: String)] = [
        ("chinese",  "中文",      "气泡里画中文台词（推荐）"),
        ("japanese", "日语",      "气泡里画日语台词，允许汉字和假名"),
        ("english",  "英文",      "气泡里画英文台词（最稳，海外漫画感）"),
        ("empty",    "留空",      "气泡画出来但里面不写字"),
        ("none",     "无对话框",   "完全不画对话框，纯视觉漫画")
    ]
    /// 是否在 Keychain 已经存了后端 API Key（仅用于 UI 展示）
    @Published var hasBackendAPIKey: Bool = false

    var normalizedBackendBaseURL: String {
        let trimmed = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "https://manga.areu.pro" : trimmed
    }

    var isBackendConfigured: Bool {
        !normalizedBackendBaseURL.isEmpty && hasBackendAPIKey
    }

    var defaultStyle: MangaStyle {
        get { MangaStyle(rawValue: defaultStyleRaw) ?? .shonenJump }
        set { defaultStyleRaw = newValue.rawValue }
    }

    /// gpt-image-2 支持的常用尺寸
    static let availableSizes = [
        "1024x1024",   // 1:1 标准
        "1024x1536",   // 2:3 漫画页（推荐）
        "1536x1024",   // 3:2 横幅
        "2048x2048",   // 2K 方形
        "2160x3840",   // 4K 漫画页（实验性）
        "3840x2160",   // 4K 横幅（实验性）
        "auto"
    ]
    static let availableQualities = ["low", "medium", "high", "auto"]

    init() {
        self.hasBackendAPIKey = (KeychainService.shared.loadBackendAPIKey() ?? "").isEmpty == false
    }

    func refreshBackendStatus() {
        hasBackendAPIKey = (KeychainService.shared.loadBackendAPIKey() ?? "").isEmpty == false
    }

    var mangaStylizationLabel: String {
        switch mangaStylizationStrength {
        case ..<0.34:
            return "偏实景参照"
        case ..<0.67:
            return "平衡"
        default:
            return "偏漫画创作"
        }
    }
}
