//
//  MangaItem.swift
//  LifeManga
//
//  数据模型：MangaProject（工程）+ MangaItem（一次生成结果）+ 剧本结构。
//

import Foundation

// MARK: - 工程

enum ProjectMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case comicLife
    case navigationGuide

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .comicLife: return "漫画人生"
        case .navigationGuide: return "导航案内"
        }
    }

    var subtitle: String {
        switch self {
        case .comicLife:
            return "延续现在的创作方式，偏日常、故事、角色和风格漫画"
        case .navigationGuide:
            return "用地图、街景和角色带路，生成路线说明式导览漫画"
        }
    }

    var symbolName: String {
        switch self {
        case .comicLife: return "books.vertical.fill"
        case .navigationGuide: return "map.fill"
        }
    }
}

struct MangaProject: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var mode: ProjectMode
    let createdAt: Date
    var updatedAt: Date
    /// 用作封面的 MangaItem.id（可选）
    var coverItemId: UUID?
    /// 备注 / 故事大纲（可选）
    var notes: String?

    init(id: UUID = UUID(),
         name: String,
         mode: ProjectMode = .comicLife,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         coverItemId: UUID? = nil,
         notes: String? = nil) {
        self.id = id
        self.name = name
        self.mode = mode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.coverItemId = coverItemId
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, mode, createdAt, updatedAt, coverItemId, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        mode = (try? c.decode(ProjectMode.self, forKey: .mode)) ?? .comicLife
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        coverItemId = try? c.decode(UUID.self, forKey: .coverItemId)
        notes = try? c.decode(String.self, forKey: .notes)
    }
}

// MARK: - 故事模式：剧本结构

struct MangaPanel: Codable, Equatable, Hashable {
    var description: String
    var dialogue: String?
    var dialogueJa: String?
    var narration: String?
    var narrationJa: String?
    var sfx: String?
}

struct MangaStoryScript: Codable, Equatable, Hashable {
    var title: String
    var synopsis: String
    var panels: [MangaPanel]
}

struct DiaryStamp: Codable, Equatable, Hashable {
    var capturedAt: Date
    var weatherText: String?

    var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f.string(from: capturedAt)
    }

    var timeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: capturedAt)
    }
}

enum MangaFeedbackState: String, Codable, CaseIterable, Identifiable, Hashable {
    case liked
    case disliked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liked: return "满意"
        case .disliked: return "不满意"
        }
    }

    var symbolName: String {
        switch self {
        case .liked: return "hand.thumbsup.fill"
        case .disliked: return "hand.thumbsdown.fill"
        }
    }
}

enum MangaFeedbackTag: String, Codable, CaseIterable, Identifiable, Hashable {
    case characterAccurate
    case compositionStrong
    case expressionGood
    case storyClear
    case detailRich
    case styleOnPoint
    case characterOff
    case anatomyOff
    case compositionMessy
    case storyWeak
    case styleOff
    case textAwkward

    var id: String { rawValue }

    var sentiment: MangaFeedbackState {
        switch self {
        case .characterAccurate, .compositionStrong, .expressionGood, .storyClear, .detailRich, .styleOnPoint:
            return .liked
        case .characterOff, .anatomyOff, .compositionMessy, .storyWeak, .styleOff, .textAwkward:
            return .disliked
        }
    }

    var title: String {
        switch self {
        case .characterAccurate: return "人物像"
        case .compositionStrong: return "构图好"
        case .expressionGood: return "表情好"
        case .storyClear: return "剧情顺"
        case .detailRich: return "细节丰富"
        case .styleOnPoint: return "风格对"
        case .characterOff: return "人物不像"
        case .anatomyOff: return "动作别扭"
        case .compositionMessy: return "构图乱"
        case .storyWeak: return "剧情弱"
        case .styleOff: return "风格不对"
        case .textAwkward: return "字或对白怪"
        }
    }

    var promptCue: String {
        switch self {
        case .characterAccurate:
            return "strong character likeness and face consistency"
        case .compositionStrong:
            return "clean composition and readable panel flow"
        case .expressionGood:
            return "expressive faces and natural emotion"
        case .storyClear:
            return "clear visual storytelling and logical scene progression"
        case .detailRich:
            return "rich but controlled details"
        case .styleOnPoint:
            return "a style match that feels exactly on target"
        case .characterOff:
            return "poor resemblance, face drift, or inconsistent character design"
        case .anatomyOff:
            return "awkward anatomy, stiff poses, or unnatural motion"
        case .compositionMessy:
            return "cluttered composition or confusing panel layout"
        case .storyWeak:
            return "weak story logic or unclear scene progression"
        case .styleOff:
            return "a style mismatch versus the selected manga style"
        case .textAwkward:
            return "awkward dialogue rendering, text placement, or bubble treatment"
        }
    }
}

// MARK: - 一次生成的结果

struct MangaItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    /// 所属工程（旧数据迁移后会回填此字段）
    var projectId: UUID
    let createdAt: Date
    let style: MangaStyle
    let inputImageNames: [String]
    let outputImageNames: [String]
    let userPrompt: String?
    var storyScript: MangaStoryScript?
    var isFavorite: Bool
    var previousPageImageName: String?
    var loadedCharacterIds: [UUID]?
    var loadedCharacterSelections: [CharacterReferenceSelection]?
    var bubbleTextMode: String?
    var isColorOutput: Bool?
    var imageCount: Int?
    var imageSize: String?
    var imageQuality: String?
    var feedbackState: MangaFeedbackState?
    var feedbackTags: [MangaFeedbackTag]
    var diaryStamp: DiaryStamp?

    init(id: UUID = UUID(),
         projectId: UUID,
         createdAt: Date = Date(),
         style: MangaStyle,
         inputImageNames: [String],
         outputImageNames: [String],
         userPrompt: String? = nil,
         storyScript: MangaStoryScript? = nil,
         isFavorite: Bool = false,
         previousPageImageName: String? = nil,
         loadedCharacterIds: [UUID]? = nil,
         loadedCharacterSelections: [CharacterReferenceSelection]? = nil,
         bubbleTextMode: String? = nil,
         isColorOutput: Bool? = nil,
         imageCount: Int? = nil,
         imageSize: String? = nil,
         imageQuality: String? = nil,
         feedbackState: MangaFeedbackState? = nil,
         feedbackTags: [MangaFeedbackTag] = [],
         diaryStamp: DiaryStamp? = nil) {
        self.id = id
        self.projectId = projectId
        self.createdAt = createdAt
        self.style = style
        self.inputImageNames = inputImageNames
        self.outputImageNames = outputImageNames
        self.userPrompt = userPrompt
        self.storyScript = storyScript
        self.isFavorite = isFavorite
        self.previousPageImageName = previousPageImageName
        self.loadedCharacterIds = loadedCharacterIds
        self.loadedCharacterSelections = loadedCharacterSelections
        self.bubbleTextMode = bubbleTextMode
        self.isColorOutput = isColorOutput
        self.imageCount = imageCount
        self.imageSize = imageSize
        self.imageQuality = imageQuality
        self.feedbackState = feedbackState
        self.feedbackTags = feedbackTags
        self.diaryStamp = diaryStamp
    }

    // 兼容旧数据：projectId 在旧版本里不存在，解码时若缺失则置为 nil-UUID
    // 之后 ProjectStore 会在加载时把这些"孤儿"绑到默认工程上。
    enum CodingKeys: String, CodingKey {
        case id, projectId, createdAt, style, inputImageNames,
             outputImageNames, userPrompt, storyScript, isFavorite,
             previousPageImageName, loadedCharacterIds, loadedCharacterSelections, bubbleTextMode,
             isColorOutput, imageCount, imageSize, imageQuality,
             feedbackState, feedbackTags, diaryStamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        // 旧数据兼容：缺 projectId 时用一个 sentinel UUID
        self.projectId = (try? c.decode(UUID.self, forKey: .projectId))
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.style = try c.decode(MangaStyle.self, forKey: .style)
        self.inputImageNames = try c.decode([String].self, forKey: .inputImageNames)
        self.outputImageNames = try c.decode([String].self, forKey: .outputImageNames)
        self.userPrompt = try? c.decode(String.self, forKey: .userPrompt)
        self.storyScript = try? c.decode(MangaStoryScript.self, forKey: .storyScript)
        self.isFavorite = (try? c.decode(Bool.self, forKey: .isFavorite)) ?? false
        self.previousPageImageName = try? c.decode(String.self, forKey: .previousPageImageName)
        self.loadedCharacterIds = try? c.decode([UUID].self, forKey: .loadedCharacterIds)
        self.loadedCharacterSelections = try? c.decode([CharacterReferenceSelection].self,
                                                       forKey: .loadedCharacterSelections)
        self.bubbleTextMode = try? c.decode(String.self, forKey: .bubbleTextMode)
        self.isColorOutput = try? c.decode(Bool.self, forKey: .isColorOutput)
        self.imageCount = try? c.decode(Int.self, forKey: .imageCount)
        self.imageSize = try? c.decode(String.self, forKey: .imageSize)
        self.imageQuality = try? c.decode(String.self, forKey: .imageQuality)
        self.feedbackState = try? c.decode(MangaFeedbackState.self, forKey: .feedbackState)
        self.feedbackTags = (try? c.decode([MangaFeedbackTag].self, forKey: .feedbackTags)) ?? []
        self.diaryStamp = try? c.decode(DiaryStamp.self, forKey: .diaryStamp)
    }
}

extension MangaItem {
    static let orphanProjectId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

// MARK: - 任务日志（仅内存）

struct JobLogEntry: Identifiable, Equatable {
    let id: UUID = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    enum Level: String {
        case info     // ℹ
        case success  // ✓
        case warning  // ⚠
        case error    // ✗
        case detail   // ·  (低强度细节)
    }

    init(level: Level = .info, message: String) {
        self.timestamp = Date()
        self.level = level
        self.message = message
    }

    var symbolName: String {
        switch level {
        case .info:    return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        case .detail:  return "circle.fill"
        }
    }

    var color: String {
        switch level {
        case .info:    return "blue"
        case .success: return "green"
        case .warning: return "orange"
        case .error:   return "red"
        case .detail:  return "gray"
        }
    }
}

// MARK: - 角色设定稿艺术风格

enum CharacterArtStyle: String, CaseIterable, Codable, Identifiable, Hashable {
    case jpAnime
    case usComics
    case krManhwa
    case kawaii
    case chibi
    case render3D
    case semiReal
    case watercolor
    case pixelArt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jpAnime:    return "日漫风"
        case .usComics:   return "美漫风"
        case .krManhwa:   return "韩漫风"
        case .kawaii:     return "可爱风"
        case .chibi:      return "Q 版"
        case .render3D:   return "3D 渲染"
        case .semiReal:   return "皮克斯风"
        case .watercolor: return "水彩风"
        case .pixelArt:   return "像素风"
        }
    }

    var subtitle: String {
        switch self {
        case .jpAnime:    return "京阿尼 / 新海诚 现代动画风"
        case .usComics:   return "Marvel / DC 美式漫画"
        case .krManhwa:   return "顶级 webtoon · 精致细腻"
        case .kawaii:     return "粉嫩、大眼、软萌"
        case .chibi:      return "2~3 头身 SD 缩小可爱"
        case .render3D:   return "皮克斯 / 平行宇宙 3D 渲染"
        case .semiReal:   return "欧美动画电影角色设定感"
        case .watercolor: return "水彩晕染 + 纸纹"
        case .pixelArt:   return "16-bit JRPG / 复古游戏立绘"
        }
    }

    var symbolName: String {
        switch self {
        case .jpAnime:    return "sparkles"
        case .usComics:   return "bolt.fill"
        case .krManhwa:   return "crown.fill"
        case .kawaii:     return "heart.fill"
        case .chibi:      return "face.smiling.fill"
        case .render3D:   return "cube.fill"
        case .semiReal:   return "movieclapper.fill"
        case .watercolor: return "drop.fill"
        case .pixelArt:   return "square.grid.3x3.fill"
        }
    }

    /// 给 gpt-image-2 的英文风格 prompt
    /// 注意：避免提及具体品牌（Marvel/DC）、武打作品（镖人）、儿童相关词汇等可能触发安全系统的词
    var prompt: String {
        switch self {
        case .jpAnime:
            return """
            Modern Japanese anime/manga character illustration style. Clean cel-shaded \
            coloring with crisp confident lineart. Large expressive anime eyes with \
            highlights, stylized hair with shine, vibrant clean color palette. \
            Polished modern TV-anime production aesthetic.
            """
        case .usComics:
            return """
            Modern American graphic-novel character illustration style. Bold confident \
            inking with strong line-weight variation. Realistic body proportions with \
            slightly stylized features. Strong cel-shading with dramatic but tasteful \
            shadows. Polished, painterly, professional comic illustration aesthetic. \
            (No specific franchise; original character design.)
            """
        case .krManhwa:
            return """
            Modern Korean webtoon character illustration style — polished glossy digital \
            illustration with clean painterly cel-shading. Realistic body proportions \
            with softly anime-influenced features, beautifully detailed expressive eyes, \
            sharp confident lineart, vibrant modern color palette, smooth gradient \
            shading on skin and hair. High-production-value webtoon aesthetic with \
            cinematic lighting and dramatic poses. Original character design.
            """
        case .kawaii:
            return """
            Soft kawaii illustration style with a pastel palette (pinks, peaches, \
            lavenders, mint). Large sparkly round eyes, simplified soft features, \
            gentle rounded shapes, dreamy peaceful atmosphere. Cute mascot-friendly \
            aesthetic. (Adult character; cute style only — keep adult facial structure \
            and proportions.)
            """
        case .chibi:
            return """
            Stylized chibi / super-deformed cartoon ART STYLE applied to an ADULT \
            character — playfully exaggerated proportions (about 3-4 heads tall), \
            simplified rounded body, large expressive eyes, simplified hands. \
            IMPORTANT: this is an adult character rendered in chibi STYLE (like an \
            adult mascot or comedic short-form animation spinoff). NOT a depiction of a \
            child, baby, or minor — keep the adult outfit, adult bearing, and any adult \
            props (work bag, glasses, etc) visible. Cute, comedic cartoon aesthetic.
            """
        case .render3D:
            return """
            Modern 3D-animated film character illustration style — soft realistic \
            lighting with subtle sub-surface skin scattering, painterly fabric textures, \
            stylized but rendered look, gentle depth of field. Polished feature-film CG \
            aesthetic. Original character design (no specific franchise).
            """
        case .semiReal:
            return """
            Stylized western animated feature-film character design style. Friendly \
            family-animation appeal with large expressive eyes, rounded appealing facial \
            features, confident eyebrow shapes, clean stylized anatomy, and polished soft \
            3D-like shading. Feels like a premium animation-studio character sheet with \
            expressive turnarounds, expression heads, and pose-friendly silhouette design. \
            Warm, charming, original animated-movie aesthetic.
            """
        case .watercolor:
            return """
            Traditional watercolor illustration style. Soft loose washes of color, \
            organic blooming edges, visible paper texture, painterly imperfection. \
            Controlled detail in the face with looser strokes elsewhere. Romantic, \
            gentle, hand-painted feel. Studio-Ghibli-inspired concept-art aesthetic.
            """
        case .pixelArt:
            return """
            16-bit JRPG pixel-art character illustration style. Clean visible square \
            pixels, limited vivid retro color palette, color blocking with deliberate \
            dithering for shading. Distinct chunky pixel shapes for hair, eyes, and \
            clothing. SNES / Game Boy Advance era role-playing game character portrait \
            aesthetic. Render every element (character, callouts, expressions, items) \
            in pixel-art form with a clearly visible pixel grid. Do NOT smooth the \
            pixels into a normal illustration.
            """
        }
    }
}

// MARK: - 角色库

/// 一个角度 / 动作下的角色立绘
struct CharacterView: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    /// 视图类型描述（"正面 / 背面 / 侧面 / 战斗姿势" 等）
    var label: String
    /// 本地存储的图片文件名
    var imageName: String
    let createdAt: Date

    init(id: UUID = UUID(),
         label: String,
         imageName: String,
         createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.imageName = imageName
        self.createdAt = createdAt
    }
}

struct CharacterReferenceSelection: Identifiable, Codable, Equatable, Hashable {
    var characterId: UUID
    var viewId: UUID?

    var id: UUID { characterId }
}

extension CharacterView {
    var isStandardPortrait: Bool {
        label.contains("标准立绘")
    }

    var isAdvancedSheet: Bool {
        label.contains("高级设定图")
    }

    var isPoseSheet: Bool {
        label.hasPrefix("动作合集")
    }
}

enum CharacterAgeGroup: String, CaseIterable, Codable, Identifiable, Hashable {
    case baby
    case child
    case teen
    case youngAdult
    case middleAged
    case elderly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .baby: return "小宝宝"
        case .child: return "小孩子"
        case .teen: return "少年"
        case .youngAdult: return "青年"
        case .middleAged: return "中年"
        case .elderly: return "老年"
        }
    }

    var promptPhrase: String {
        switch self {
        case .baby: return "a baby"
        case .child: return "a young child"
        case .teen: return "a teenager"
        case .youngAdult: return "a young adult"
        case .middleAged: return "a middle-aged adult"
        case .elderly: return "an elderly adult"
        }
    }

    var isMinor: Bool {
        self == .baby || self == .child
    }
}

enum CharacterGender: String, CaseIterable, Codable, Identifiable, Hashable {
    case male
    case female

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .male: return "男"
        case .female: return "女"
        }
    }

    var promptPhrase: String {
        switch self {
        case .male: return "male"
        case .female: return "female"
        }
    }
}

/// 一个角色（含多视图）
struct Character: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var bio: String?         // 性格 / 背景设定
    var ageGroup: CharacterAgeGroup
    var gender: CharacterGender
    /// 用户上传的真人参考照片（仅用于生成；不会被打包到漫画里）
    var sourcePhotoName: String?
    /// 多角度立绘集合
    var views: [CharacterView]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         bio: String? = nil,
         ageGroup: CharacterAgeGroup = .youngAdult,
         gender: CharacterGender = .male,
         sourcePhotoName: String? = nil,
         views: [CharacterView] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.bio = bio
        self.ageGroup = ageGroup
        self.gender = gender
        self.sourcePhotoName = sourcePhotoName
        self.views = views
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Character {
    var referencePortraitView: CharacterView? {
        views.first(where: \.isStandardPortrait)
    }

    var preferredCoverView: CharacterView? {
        referencePortraitView ?? views.first
    }
}

extension CharacterArtStyle {
    var standardPortraitLabel: String {
        "\(displayName) 标准立绘"
    }

    func nextAdvancedSheetLabel(existingLabels: [String]) -> String {
        let base = "\(displayName) 高级设定图"
        let count = existingLabels.filter { $0.hasPrefix(base) }.count
        return count == 0 ? base : "\(base) \(count + 1)"
    }
}
