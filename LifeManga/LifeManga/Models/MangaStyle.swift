//
//  MangaStyle.swift
//  LifeManga
//
//  漫画风格定义。每种风格包含中文名、副标题、Emoji 图标，
//  以及发送给 OpenAI 的英文 Prompt。
//
//  ‼️ Prompt 设计原则（避免出现"脏画面"）：
//      - 强调 CLEAN, CONFIDENT INK LINES（干净自信的描线）
//      - 强调 GENEROUS WHITE SPACE（大量留白）
//      - 屏蔽掉过度的 crosshatching / stippling / sketchy
//      - 用现代主流日漫作品做参考（间谍过家家 / 咒术回战 / 我推的孩子 等）
//

import Foundation
import SwiftUI

enum MangaStyle: String, Codable, CaseIterable, Identifiable {
    case shonenJump
    case sliceOfLife
    case darkSeinen
    case retroGekiga
    case chibi4Koma
    case sportsHotBlooded
    case scifiMecha
    case horrorJunjiIto
    case americanSuperhero
    case shogakukanKids
    case shojoRomance
    case hotBloodAdventure
    case nostalgicChildhood
    case youth4Koma
    case navigationGuide

    var id: String { rawValue }

    /// 中文显示名
    var displayName: String {
        switch self {
        case .shonenJump:       return "经典少年Jump风"
        case .sliceOfLife:      return "日常治愈风"
        case .darkSeinen:       return "暗黑剧情风"
        case .retroGekiga:      return "复古剧画风"
        case .chibi4Koma:       return "萌系四格风"
        case .sportsHotBlooded: return "运动热血风"
        case .scifiMecha:       return "科幻机甲风"
        case .horrorJunjiIto:   return "悬疑氛围风"
        case .americanSuperhero:return "美漫英雄风"
        case .shogakukanKids:   return "日本小学馆漫画风"
        case .shojoRomance:     return "少女漫风"
        case .hotBloodAdventure:return "热血漫画风"
        case .nostalgicChildhood:return "细节童年风"
        case .youth4Koma:       return "四格青春风"
        case .navigationGuide:  return "导航案内"
        }
    }

    /// 风格描述（设置页里展示给用户）
    var subtitle: String {
        switch self {
        case .shonenJump:       return "间谍过家家 / 咒术回战 那种现代少年漫干净线条"
        case .sliceOfLife:      return "辉夜大小姐 / 邻家女孩 那种温柔日常感"
        case .darkSeinen:       return "我推的孩子 / 链锯人 那种有质感的剧情漫画"
        case .retroGekiga:      return "70-80 年代写实剧画，浓厚老派气息"
        case .chibi4Koma:       return "Q 版四格漫画，可爱搞笑"
        case .sportsHotBlooded: return "灌篮高手 / 排球少年 那种动感燃系"
        case .scifiMecha:       return "攻壳机动队 / AKIRA 那种赛博机械感"
        case .horrorJunjiIto:   return "Monster / 死亡笔记 那种紧张心理悬疑感（非暴力）"
        case .americanSuperhero:return "现代主流超级英雄月刊感，强动态强透视"
        case .shogakukanKids:   return "经典日本少儿漫画，清爽圆润、轻科幻喜剧"
        case .shojoRomance:     return "清透纤细的现代少女恋爱漫画感"
        case .hotBloodAdventure:return "王道少年冒险战斗，燃、冲、连载感强"
        case .nostalgicChildhood:return "怀旧童年日常，温暖闹腾、老单行本质感"
        case .youth4Koma:       return "校园社团四格，轻萌青春、吐槽节奏快"
        case .navigationGuide:  return "街景地图 + 俯视路线 + 角色带路，像路线指引漫画"
        }
    }

    /// SF Symbol 图标名（保证在所有 iOS 设备上能正常渲染）
    var symbolName: String {
        switch self {
        case .shonenJump:       return "bolt.fill"
        case .sliceOfLife:      return "leaf.fill"
        case .darkSeinen:       return "theatermasks.fill"
        case .retroGekiga:      return "text.book.closed.fill"
        case .chibi4Koma:       return "heart.fill"
        case .sportsHotBlooded: return "flame.fill"
        case .scifiMecha:       return "cpu.fill"
        case .horrorJunjiIto:   return "eye.fill"
        case .americanSuperhero:return "shield.lefthalf.filled"
        case .shogakukanKids:   return "books.vertical.fill"
        case .shojoRomance:     return "sparkles"
        case .hotBloodAdventure:return "bolt.badge.clock.fill"
        case .nostalgicChildhood:return "figure.child"
        case .youth4Koma:       return "rectangle.grid.1x2.fill"
        case .navigationGuide:  return "map.fill"
        }
    }

    /// 全局"清爽线条"硬性指令（除了剧画/伊藤润二那种本身就该密集的风格之外）
    private var globalCleanInkRule: String {
        """
        CRITICAL DRAWING RULES (override anything else if conflict):
        - CLEAN, CONFIDENT INK LINES with strong weight variation, like a printed manga page that just came off a professional inker's desk.
        - This must look HAND-DRAWN AND ILLUSTRATED, not like a filtered photo, painted-over photo, rotoscoped image, or lightly edited live-action still.
        - Aggressively TRANSLATE real-world photo details into manga/anime drawing language: simplified shapes, selective detail, clear silhouette design, and inked contour lines around important forms.
        - GENEROUS WHITE SPACE. Faces and clothing should be mostly white with just a few decisive shadow shapes.
        - DO NOT use sketchy, scribbly, pencil-rough, charcoal, or photo-realistic textures.
        - DO NOT preserve camera-realistic lens detail, photographic micro-texture, or documentary realism. Reduce real-world clutter and redraw it as stylized comic scenery.
        - Use SOLID FLAT BLACKS for major shadows, screen-tone dot patterns ONLY where appropriate (hair, clothing folds), NOT scattered everywhere.
        - Avoid heavy crosshatching/stippling on faces and skin — keep skin almost entirely white.
        - Backgrounds should be SIMPLIFIED: clean perspective lines, geometric shapes, lots of white. No noisy textures.
        - When the source image is a real street, room, building, or landscape, RE-DRAW it as a stylized manga background with clearer outlines, cleaner planes, and more graphic value grouping instead of preserving raw photographic detail.
        - Speech bubbles must be perfectly clean ovals with crisp single-line borders.
        - The page should look CRISP and READABLE at thumbnail size.
        """
    }

    /// 给 OpenAI 的"基础风格 prompt" —— 不含色彩指令，由 effectivePrompt 注入
    var prompt: String {
        switch self {

        case .shonenJump:
            return """
            Modern mainstream Weekly Shonen Jump manga style, in the vein of Spy x Family, \
            Jujutsu Kaisen, Chainsaw Man, My Hero Academia, or Oshi no Ko. \
            Clean confident inking with strong line-weight variation. Big expressive eyes \
            with sharp highlights, dynamic but readable poses, sharp angular hair drawn as \
            simple solid black silhouettes. \
            Use screen-tone halftones SPARINGLY (only on hair, eyes, and one or two key \
            shadow areas). Plenty of white space. Speed lines used purposefully — not \
            scattered all over the page. The page must read crisp and clean.
            """

        case .sliceOfLife:
            return """
            Gentle modern Japanese slice-of-life manga style, like Kaguya-sama: Love is War, \
            Komi Can't Communicate, or Yotsuba&!. Soft, very clean ink lines. Mostly white \
            faces with subtle delicate shading. Calm warm composition, lots of negative space. \
            Speech bubbles are clean rounded rectangles or soft ovals. Backgrounds are \
            simplified and uncluttered. NO heavy crosshatching, NO sketchy lines.
            """

        case .darkSeinen:
            return """
            Modern seinen manga style, in the vein of Oshi no Ko, Chainsaw Man, or 20th \
            Century Boys. Sharp confident inking with strong contrast: large solid-black \
            shadow shapes versus clean white skin. Mature realistic proportions but still \
            stylized. Atmospheric lighting through bold black silhouettes, NOT through \
            scribbly hatching. Use screen tones for clothing and dramatic gradients. \
            Keep faces and skin clean — let the silhouettes carry the mood.
            """

        case .retroGekiga:
            return """
            Vintage 1970s-80s Japanese dramatic manga illustration style. Realistic but still \
            clearly stylized — confident hand-inked lines, deliberate classic crosshatching on \
            clothing, architecture, and major shadow shapes, vintage screen-tone patterns, and \
            restrained editorial composition. Faces should stay readable and expressive rather \
            than overly gritty. The result should feel like a finished old-school printed manga \
            page with mature atmosphere, careful staging, and period print charm.
            """

        case .chibi4Koma:
            return """
            Cute chibi 4-koma comedy manga style, like Lucky Star, K-On!, or Azumanga Daioh. \
            Super-deformed rounded character proportions, large simple eyes, clean thin \
            confident ink lines. Almost no shading — just a tiny bit of light screen tone. \
            Tons of white space, light and airy composition. Add small cute symbols \
            (sparkles, sweat drops, music notes, hearts) tastefully. \
            Speech bubbles are perfect clean ovals.
            """

        case .sportsHotBlooded:
            return """
            Modern sports manga style, like Haikyuu!!, Kuroko no Basket, or Blue Lock. \
            Dynamic action with confident clean inking, dramatic foreshortened poses, \
            intense determined expressions. Speed lines used PURPOSEFULLY — radiating from \
            a single focal point, not scattered. Sweat drops and motion effects with crisp \
            clean lines. Backgrounds simplified to focus attention on the characters. \
            Keep faces and skin mostly white — let the body language carry the energy.
            """

        case .scifiMecha:
            return """
            Detailed sci-fi mecha manga style, like Ghost in the Shell, AKIRA, or modern \
            Mobile Suit Gundam manga. Mechanical and architectural elements drawn with \
            precise ruler-clean lines and accurate perspective. Characters with clean sharp \
            inking, mature stylized proportions. Use screen tones thoughtfully on metal \
            surfaces and lighting gradients. Keep human skin/faces relatively clean. \
            Cyberpunk or hard-sci-fi atmosphere through composition, not noisy textures.
            """

        case .horrorJunjiIto:
            return """
            Psychological suspense manga style with strong noir atmosphere. Dense but precise \
            and controlled crosshatching for dramatic shadow, every stroke deliberate and \
            polished. Strong cinematic chiaroscuro with deep solid blacks against crisp clean \
            whites. Build tension through composition and lighting: long shadows, off-kilter \
            camera angles, half-lit faces, fog, empty corridors, distant silhouettes, and a \
            quiet investigative mood. Keep everything grounded in an ordinary everyday world, \
            with intact fully clothed characters, clean readable anatomy, and a refined \
            detective-drama tone rather than sensational shock imagery.
            """

        case .americanSuperhero:
            return """
            Modern American superhero comic-book page style. High-energy action storytelling \
            with bold black inks, strong line-weight variation, dramatic foreshortening, \
            muscular stylized anatomy, cinematic panel composition, explosive motion, clean \
            digital-style coloring logic even in monochrome value design, and impactful sound \
            effect energy. Emphasize urban action, heroic poses, strong contrast shadows, and \
            a polished mainstream monthly comic aesthetic.
            """

        case .shogakukanKids:
            return """
            Classic Japanese children's comedy manga page style. Clean monochrome ink drawing \
            with simple rounded character designs, highly readable panel layout, expressive \
            cartoon faces, playful reaction poses, gentle everyday neighborhood atmosphere, \
            light whimsical gadget-comedy feeling, tidy speech bubbles, minimal shading, sparse \
            screen tones, and a wholesome retro family-friendly manga page aesthetic.
            """

        case .shojoRomance:
            return """
            Modern Japanese shojo romance manga page style. Delicate thin ink lines, soft \
            expressive eyes, flowing detailed hair, elegant slender character proportions, \
            emotional close-up compositions, airy screen tones, gentle grayscale shading, \
            subtle sparkles and soft background effects, clean white space, and a tender \
            romantic atmosphere. Focus on feelings, eye contact, blush, hesitation, and quiet \
            emotional tension rather than action.
            """

        case .hotBloodAdventure:
            return """
            Classic Japanese shonen action manga page style. Bold energetic ink lines, \
            exaggerated expressive faces, dynamic action composition, strong black shadow \
            shapes, dramatic speed lines, adventurous battle atmosphere, powerful character \
            silhouettes, and clear high-impact panel storytelling. Emphasize heroic energy, \
            determination, friendship, forward momentum, and emotional intensity.
            """

        case .nostalgicChildhood:
            return """
            Nostalgic Japanese childhood slice-of-life manga page style. Retro black-and-white \
            family comedy manga with expressive child characters, warm neighborhood atmosphere, \
            detailed everyday props, classic halftone shading, soft but confident ink lines, \
            playful reaction faces, and an old-school printed manga texture. Emphasize \
            childhood memory, small daily accidents, innocent mischief, cozy urban life, and \
            gentle humorous storytelling.
            """

        case .youth4Koma:
            return """
            Japanese 4-koma youth comedy manga page style. Cute youthful character design, \
            clean thin black-and-white linework, tidy four-panel layout, simple expressive \
            faces, soft halftone shading, school and club-life atmosphere, light awkward humor, \
            charming slice-of-life pacing, and a gentle retro moe manga aesthetic. Focus on \
            small daily interactions, shy reactions, subtle jokes, and relaxed youthful energy \
            rather than dramatic action.
            """

        case .navigationGuide:
            return """
            Japanese navigation-guide comic style. Create a clean, highly readable manga-like \
            wayfinding page that combines simplified overhead map panels, street-view landmark \
            panels, route arrows, destination callouts, and a friendly guide character who \
            points, gestures, or walks the viewer through the journey. Emphasize visual clarity, \
            directional flow, legible path progression, landmark recognition, and editorial \
            travel-guide energy rather than drama. Re-draw real map screenshots into polished \
            illustrated map blocks with simplified roads, blocks, station markers, crossings, \
            and route highlights. Use clear arrows, numbered steps, inset zoom panels, and \
            guide captions so the page feels like a charming hand-drawn route manual or local \
            area navigation comic.
            """
        }
    }

    /// 根据彩色/黑白模式，把"风格 prompt + 全局清爽规则 + 颜色指令"拼到一起
    func effectivePrompt(isColor: Bool,
                         stylizationStrength: Double = 0.78,
                         preserveRealWorldReadability: Bool = false) -> String {
        let cleanRule = (self == .horrorJunjiIto || self == .retroGekiga)
            ? ""    // 这两个风格本身就允许密集线条，跳过全局清爽规则
            : "\n\n" + globalCleanInkRule

        let strength = min(max(stylizationStrength, 0), 1)
        let stylizationDirective: String = {
            switch strength {
            case ..<0.34:
                return """
                STYLIZATION STRENGTH — LOW:
                Keep the source scene highly recognizable. Preserve real-world street layout, \
                landmark placement, building silhouettes, shopfront structure, and overall scene \
                identity. Apply only light comic cleanup: mild outline enhancement, gentle color \
                unification, and subtle illustration polish. Avoid aggressive redesign, excessive \
                simplification, or heavy anime deformation.
                """
            case ..<0.67:
                return """
                STYLIZATION STRENGTH — MEDIUM:
                Balance recognizability and comic redraw. Preserve major landmarks, road geometry, \
                building massing, and scene readability, while adding clearer contour lines, shape \
                grouping, cleaner textures, and more intentional illustrated color design.
                """
            default:
                return """
                STYLIZATION STRENGTH — HIGH:
                Push the image strongly toward manga/anime illustration. Redraw the scene with \
                stronger line art, cleaner graphic shape design, clearer cel-shading or semi-cel-shading, \
                more saturated palette separation, and much less camera realism. Make it feel obviously \
                hand-drawn and artistically interpreted rather than photo-derived.
                """
            }
        }()

        let preservationDirective: String = preserveRealWorldReadability
            ? """
            REAL-WORLD READABILITY PRIORITY:
            Preserve wayfinding usefulness. Keep roads, crossings, station exits, storefront positions, \
            landmark silhouettes, spatial relationships, and scene orientation recognizable. If signage \
            or environmental text matters for identifying a place, keep its placement and visual role \
            believable instead of replacing the area with fantasy details. Prioritize navigational clarity \
            over dramatic stylization.
            """
            : ""

        let colorDirective: String
        if isColor {
            colorDirective = """
            COLOR MODE OVERRIDE — RENDER IN FULL COLOR:
            Render this page as a FULL-COLOR manga illustration with richer saturation, clearer hue \
            separation, stronger line art, and obvious hand-drawn anime/comic stylization. Use clean \
            cel-shading or semi-cel-shading, simplified illustrated textures, bold contour lines, and \
            polished manga/anime color design rather than realistic photo rendering. Keep the world \
            looking redrawn, graphic, and intentionally illustrated. Use vivid, harmonious colors, \
            slightly boosted saturation, natural but stylized skin tones, and atmospheric lighting. \
            Prioritize ink outlines and shape design over camera realism. Polished anime/manga \
            color palette. IGNORE any "black and white", "no color", "monochrome", "screen tone \
            only", or "pure ink" instructions in the style guide below — those are overridden by \
            this full-color directive. Keep ink linework strong, clean, and confident.

            \(stylizationDirective)
            \(preservationDirective)

            STYLE GUIDE:
            \(prompt)\(cleanRule)
            """
        } else {
            colorDirective = """
            COLOR MODE OVERRIDE — PURE BLACK AND WHITE:
            Pure black-and-white manga ink art. No colors. Solid blacks for shadow shapes, \
            screen-tone halftone dots used sparingly and deliberately. Follow the style guide \
            below.

            \(stylizationDirective)
            \(preservationDirective)

            STYLE GUIDE:
            \(prompt)\(cleanRule)
            """
        }
        return colorDirective
    }
}

// MARK: - 视觉缩略图（替代 emoji，给用户直观预览风格的"调子"）

/// 每种风格的微型预览卡。使用 SwiftUI 自绘，渲染极快、无需图片资源。
struct StylePreviewIcon: View {
    let style: MangaStyle
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            backgroundLayer
            symbolLayer
        }
        .frame(width: size * 1.25, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: 背景层 —— 每种风格的特征视觉

    @ViewBuilder
    private var backgroundLayer: some View {
        switch style {

        case .shonenJump:
            // 白底 + 放射速度线（最具代表性的少年漫元素）
            ZStack {
                Color.white
                Canvas { ctx, sz in
                    let center = CGPoint(x: sz.width * 0.2, y: sz.height * 1.1)
                    for angle in stride(from: 10, through: 100, by: 7) {
                        var p = Path()
                        p.move(to: center)
                        let a = Double(angle) * .pi / 180
                        p.addLine(to: CGPoint(
                            x: center.x + cos(a) * sz.width * 1.6,
                            y: center.y - sin(a) * sz.height * 1.6
                        ))
                        ctx.stroke(p, with: .color(.black), lineWidth: 0.7)
                    }
                }
            }

        case .sliceOfLife:
            // 柔和粉橘渐变 —— 治愈感
            LinearGradient(
                colors: [Color(red: 1.0, green: 0.88, blue: 0.92),
                         Color(red: 1.0, green: 0.96, blue: 0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

        case .darkSeinen:
            // 高对比黑白 —— 戏剧感
            ZStack {
                Color.black
                // 一抹白光斜切
                LinearGradient(
                    colors: [Color.white.opacity(0.0), Color.white.opacity(0.25), Color.white.opacity(0.0)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }

        case .retroGekiga:
            // 米色泛黄纸 + 横纹 —— 老派印刷感
            ZStack {
                Color(red: 0.96, green: 0.92, blue: 0.78)
                Canvas { ctx, sz in
                    for i in 0..<8 {
                        let y = sz.height * Double(i) / 8
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: sz.width, y: y))
                        ctx.stroke(p, with: .color(Color(red: 0.55, green: 0.42, blue: 0.25).opacity(0.18)), lineWidth: 0.4)
                    }
                }
            }

        case .chibi4Koma:
            // 粉色波点 —— 萌系
            ZStack {
                Color(red: 1.0, green: 0.92, blue: 0.96)
                Canvas { ctx, sz in
                    for i in 0..<6 {
                        for j in 0..<5 {
                            let x = sz.width * (0.15 + Double(i) * 0.15)
                            let y = sz.height * (0.15 + Double(j) * 0.18)
                            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)),
                                     with: .color(Color.pink.opacity(0.25)))
                        }
                    }
                }
            }

        case .sportsHotBlooded:
            // 火焰橘红渐变 + 动感斜纹 —— 热血
            ZStack {
                LinearGradient(
                    colors: [Color.orange, Color.red.opacity(0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Canvas { ctx, sz in
                    for i in 0..<6 {
                        var p = Path()
                        let x = sz.width * Double(i) * 0.18 - sz.width * 0.2
                        p.move(to: CGPoint(x: x, y: sz.height))
                        p.addLine(to: CGPoint(x: x + sz.width * 0.6, y: 0))
                        ctx.stroke(p, with: .color(.white.opacity(0.18)), lineWidth: 1.5)
                    }
                }
            }

        case .scifiMecha:
            // 深蓝 + 几何线条 —— 赛博机械
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.16, blue: 0.40),
                             Color(red: 0.04, green: 0.08, blue: 0.16)],
                    startPoint: .top, endPoint: .bottom
                )
                Canvas { ctx, sz in
                    let path = Path { p in
                        p.move(to: CGPoint(x: 0, y: sz.height * 0.7))
                        p.addLine(to: CGPoint(x: sz.width * 0.4, y: sz.height * 0.7))
                        p.addLine(to: CGPoint(x: sz.width * 0.55, y: sz.height * 0.45))
                        p.addLine(to: CGPoint(x: sz.width, y: sz.height * 0.45))
                    }
                    ctx.stroke(path, with: .color(.cyan.opacity(0.65)), lineWidth: 0.8)
                }
            }

        case .horrorJunjiIto:
            // 灰黑雾化 + 半透明剪影 —— 悬疑氛围
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.32), Color(white: 0.05)],
                    startPoint: .top, endPoint: .bottom
                )
                Canvas { ctx, sz in
                    // 一道光从一侧打过来
                    let g = Gradient(colors: [.white.opacity(0.0), .white.opacity(0.18), .white.opacity(0.0)])
                    ctx.fill(
                        Path(CGRect(origin: .zero, size: sz)),
                        with: .linearGradient(g,
                                              startPoint: CGPoint(x: 0, y: 0),
                                              endPoint: CGPoint(x: sz.width, y: sz.height))
                    )
                }
            }

        case .americanSuperhero:
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.92, green: 0.28, blue: 0.20),
                             Color(red: 0.10, green: 0.28, blue: 0.70)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Canvas { ctx, sz in
                    for i in 0..<7 {
                        var p = Path()
                        let x = sz.width * Double(i) * 0.18
                        p.move(to: CGPoint(x: x - sz.width * 0.25, y: sz.height))
                        p.addLine(to: CGPoint(x: x + sz.width * 0.15, y: 0))
                        ctx.stroke(p, with: .color(.white.opacity(0.22)), lineWidth: 1.2)
                    }
                }
            }

        case .shogakukanKids:
            ZStack {
                Color.white
                Canvas { ctx, sz in
                    for i in 0..<5 {
                        let x = sz.width * (0.12 + Double(i) * 0.18)
                        let rect = CGRect(x: x, y: sz.height * 0.18, width: 5, height: sz.height * 0.64)
                        ctx.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.07)))
                    }
                }
            }

        case .shojoRomance:
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.98, green: 0.96, blue: 0.99),
                             Color(red: 0.93, green: 0.92, blue: 0.97)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Canvas { ctx, sz in
                    for _ in 0..<10 {
                        let x = sz.width * Double.random(in: 0.08...0.92)
                        let y = sz.height * Double.random(in: 0.12...0.88)
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.5, height: 2.5)),
                                 with: .color(.pink.opacity(0.22)))
                    }
                }
            }

        case .hotBloodAdventure:
            ZStack {
                Color.white
                Canvas { ctx, sz in
                    let center = CGPoint(x: sz.width * 0.52, y: sz.height * 0.55)
                    for angle in stride(from: -20, through: 200, by: 12) {
                        var p = Path()
                        p.move(to: center)
                        let a = Double(angle) * .pi / 180
                        p.addLine(to: CGPoint(x: center.x + cos(a) * sz.width,
                                              y: center.y + sin(a) * sz.height))
                        ctx.stroke(p, with: .color(.black.opacity(0.55)), lineWidth: 0.9)
                    }
                }
            }

        case .nostalgicChildhood:
            ZStack {
                Color(red: 0.95, green: 0.95, blue: 0.91)
                Canvas { ctx, sz in
                    for i in 0..<7 {
                        let y = sz.height * (0.12 + Double(i) * 0.12)
                        var p = Path()
                        p.move(to: CGPoint(x: sz.width * 0.08, y: y))
                        p.addLine(to: CGPoint(x: sz.width * 0.92, y: y))
                        ctx.stroke(p, with: .color(.black.opacity(0.08)), lineWidth: 0.6)
                    }
                }
            }

        case .youth4Koma:
            ZStack {
                Color(red: 0.98, green: 0.98, blue: 0.98)
                Canvas { ctx, sz in
                    for i in 1..<4 {
                        let x = sz.width * Double(i) / 4
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: sz.height * 0.1))
                        p.addLine(to: CGPoint(x: x, y: sz.height * 0.9))
                        ctx.stroke(p, with: .color(.black.opacity(0.16)), lineWidth: 0.8)
                    }
                }
            }

        case .navigationGuide:
            ZStack {
                Color(red: 0.95, green: 0.98, blue: 0.95)
                Canvas { ctx, sz in
                    for i in 0...5 {
                        let x = sz.width * Double(i) / 5
                        var vertical = Path()
                        vertical.move(to: CGPoint(x: x, y: 0))
                        vertical.addLine(to: CGPoint(x: x, y: sz.height))
                        ctx.stroke(vertical, with: .color(Color.green.opacity(0.12)), lineWidth: 0.7)
                    }
                    for i in 0...3 {
                        let y = sz.height * Double(i) / 3
                        var horizontal = Path()
                        horizontal.move(to: CGPoint(x: 0, y: y))
                        horizontal.addLine(to: CGPoint(x: sz.width, y: y))
                        ctx.stroke(horizontal, with: .color(Color.green.opacity(0.12)), lineWidth: 0.7)
                    }

                    var route = Path()
                    route.move(to: CGPoint(x: sz.width * 0.14, y: sz.height * 0.75))
                    route.addLine(to: CGPoint(x: sz.width * 0.32, y: sz.height * 0.62))
                    route.addLine(to: CGPoint(x: sz.width * 0.48, y: sz.height * 0.64))
                    route.addLine(to: CGPoint(x: sz.width * 0.64, y: sz.height * 0.38))
                    route.addLine(to: CGPoint(x: sz.width * 0.84, y: sz.height * 0.24))
                    ctx.stroke(route, with: .color(Color(red: 0.19, green: 0.61, blue: 0.53)), lineWidth: 2.4)

                    let start = CGRect(x: sz.width * 0.10, y: sz.height * 0.71, width: 7, height: 7)
                    let end = CGRect(x: sz.width * 0.81, y: sz.height * 0.20, width: 8, height: 8)
                    ctx.fill(Path(ellipseIn: start), with: .color(Color(red: 0.24, green: 0.48, blue: 0.95)))
                    ctx.fill(Path(ellipseIn: end), with: .color(Color(red: 0.95, green: 0.40, blue: 0.34)))
                }
            }
        }
    }

    // MARK: 前景符号

    @ViewBuilder
    private var symbolLayer: some View {
        Image(systemName: style.symbolName)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(symbolColor)
            .shadow(color: symbolShadow, radius: 1, y: 0)
    }

    private var symbolColor: Color {
        switch style {
        case .shonenJump:       return .black
        case .sliceOfLife:      return Color(red: 0.45, green: 0.65, blue: 0.45)
        case .darkSeinen:       return .white
        case .retroGekiga:      return Color(red: 0.45, green: 0.30, blue: 0.15)
        case .chibi4Koma:       return Color(red: 0.95, green: 0.45, blue: 0.62)
        case .sportsHotBlooded: return .white
        case .scifiMecha:       return .cyan
        case .horrorJunjiIto:   return Color.white.opacity(0.92)
        case .americanSuperhero:return .white
        case .shogakukanKids:   return .black.opacity(0.75)
        case .shojoRomance:     return Color(red: 0.72, green: 0.55, blue: 0.76)
        case .hotBloodAdventure:return .black
        case .nostalgicChildhood:return Color(red: 0.30, green: 0.28, blue: 0.20)
        case .youth4Koma:       return Color(red: 0.18, green: 0.18, blue: 0.18)
        case .navigationGuide:  return Color(red: 0.16, green: 0.52, blue: 0.44)
        }
    }

    private var symbolShadow: Color {
        switch style {
        case .darkSeinen, .horrorJunjiIto, .scifiMecha, .sportsHotBlooded, .americanSuperhero:
            return .black.opacity(0.4)
        default:
            return .clear
        }
    }
}

/// 色彩模式预览卡（黑白 / 全彩）
struct ColorModePreview: View {
    let isColor: Bool
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            if isColor {
                LinearGradient(
                    colors: [.pink, .orange, .yellow, .green, .blue, .purple],
                    startPoint: .leading, endPoint: .trailing
                )
            } else {
                HStack(spacing: 0) {
                    Color.black
                    Color.white
                }
            }
        }
        .frame(width: size * 1.4, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.gray.opacity(0.4), lineWidth: 0.5)
        )
    }
}
