import AppKit
import HTTThemeCore

/// Selectable visual theme for the usage panel based on Byungki-style themes.
/// Requested themes and order: light, friday, jarvis, ultron.
enum UsagePanelTheme: String, CaseIterable {
    case light = "light"
    case friday = "friday"
    case jarvis = "jarvis"
    case ultron = "ultron"

    var displayName: String {
        switch self {
        case .light: return "라이트"
        case .friday: return "프라이데이"
        case .jarvis: return "자비스"
        case .ultron: return "울트론"
        }
    }

    var isDark: Bool {
        switch self {
        case .light, .friday: return false
        case .jarvis, .ultron: return true
        }
    }

    var paletteID: HTTPaletteID { HTTPaletteID(rawValue: rawValue) ?? .light }

    init(_ id: HTTPaletteID) { self = UsagePanelTheme(rawValue: id.rawValue) ?? .light }

    var nextTheme: UsagePanelTheme {
        switch self {
        case .light: return .friday
        case .friday: return .jarvis
        case .jarvis: return .ultron
        case .ultron: return .light
        }
    }

    var palette: BKThemePalette { BKThemePalette(paletteID.tokens) }
}

/// Official Byungki-style palette token set
struct BKThemePalette {
    let bg: NSColor
    let card: NSColor
    let surface: NSColor
    let surface2: NSColor
    let text: NSColor
    let text2: NSColor
    let muted: NSColor
    let border: NSColor
    let border2: NSColor
    let accent: NSColor
    let accentStrong: NSColor
    let accentSoft: NSColor
    let onAccent: NSColor
    let warn: NSColor
    let warnSoft: NSColor
    let warnInk: NSColor
    let danger: NSColor
    let dangerSoft: NSColor

    /// 색 값은 HTTThemeCore의 공용 팔레트 하나에서만 온다.
    init(_ t: HTTPaletteTokens) {
        bg = .htt(t.paper); card = .htt(t.card); surface = .htt(t.surface); surface2 = .htt(t.surface2)
        text = .htt(t.ink); text2 = .htt(t.ink2); muted = .htt(t.muted); border = .htt(t.line); border2 = .htt(t.line2)
        accent = .htt(t.olive); accentStrong = .htt(t.oliveDeep); accentSoft = .htt(t.oliveSoft); onAccent = .htt(t.onAccent)
        warn = .htt(t.orange); warnSoft = .htt(t.orangeSoft); warnInk = .htt(t.warnInk)
        danger = .htt(t.red); dangerSoft = .htt(t.redSoft)
    }
}

enum UsagePanelThemeStore {
    static let defaultsKey = "usagePanelThemeV1"

    /// Migrates old stored strings safely to the 4 Byungki style themes:
    /// - classic, daytime -> light
    /// - bk, night, dark -> jarvis
    /// - casual -> friday
    /// - light -> light
    /// - friday -> friday
    /// - jarvis -> jarvis
    /// - ultron -> ultron
    /// - unknown/default -> light
    static func migrate(raw: String?) -> UsagePanelTheme {
        guard let raw = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .light
        }
        switch raw {
        case "light", "라이트", "밝은":
            return .light
        case "friday", "프라이데이":
            return .friday
        case "jarvis", "자비스":
            return .jarvis
        case "ultron", "울트론":
            return .ultron
        case "classic", "daytime", "기본":
            return .light
        case "bk", "bk style", "night", "dark", "어두운", "중간", "medium":
            return .jarvis
        case "casual":
            return .friday
        default:
            return .light
        }
    }

    /// 업데이트 전에 서버 현황에서만 고른 값. 계정 테마를 읽거나 새로 고르기 전까지 그대로 보인다(지우거나 덮어쓰지 않는다).
    static var legacyChoice: UsagePanelTheme? {
        CCMBPreferences.shared.defaults.string(forKey: defaultsKey).map { migrate(raw: $0) }
    }

    /// 지금 서버 현황에 적용할 테마(공용 원본).
    static var current: UsagePanelTheme { UsagePanelTheme(HTTThemeSnapshot.ccmb.id) }

    /// 사용자의 직접 선택. 로그인 상태면 계정에 저장한다.
    @MainActor
    static func select(_ theme: UsagePanelTheme) {
        HTTThemeCenter.shared.select(HTTThemeSelection(theme.paletteID))
    }
}

/// Central BK Style material tokens driven by the current theme palette.
enum BKStyleTokens {
    static var currentPalette: BKThemePalette { UsagePanelThemeStore.current.palette }

    /// Structural accent / signal color from theme palette
    static var signalRed: NSColor { currentPalette.accent }

    static var cardFill: NSColor { currentPalette.card }
    static var panelBackground: NSColor { currentPalette.bg }
    static var wellFill: NSColor { currentPalette.surface2 }

    static var charcoalInk: NSColor { currentPalette.text }
    static var bodyInk: NSColor { currentPalette.text }
    static var secondaryInk: NSColor { currentPalette.text2 }
    static var mutedInk: NSColor { currentPalette.muted }

    /// Default bar colors.
    static var barGreen: NSColor { CCMBColors.success }
    static var barLow: NSColor { CCMBColors.warn }
    static var barTrack: NSColor { currentPalette.surface2 }

    static var chromeLine: NSColor { currentPalette.border }
    static var chromeHighlight: NSColor { currentPalette.border2 }

    /// Dark themes (Jarvis cyan / Ultron crimson) carry their identity in the
    /// structural lines: card rims, top hairlines and header rule. Light and
    /// Friday keep the plain chrome tokens.
    static var isAccentTheme: Bool { UsagePanelThemeStore.current.isDark }
    static var cardRim: NSColor { isAccentTheme ? currentPalette.border2 : currentPalette.border }
    static var structureHairline: NSColor {
        isAccentTheme ? currentPalette.accent.withAlphaComponent(0.55) : currentPalette.border2
    }
    static var contactShadow: NSColor {
        UsagePanelThemeStore.current.isDark ? NSColor(white: 0, alpha: 0.42) : NSColor(white: 0, alpha: 0.10)
    }

    static func drawCard(in rect: NSRect, radius: CGFloat) {
        guard rect.width > 2, rect.height > 2 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        // Contact shadow: a soft hairline directly under the card only.
        contactShadow.setFill()
        NSBezierPath(
            roundedRect: rect.offsetBy(dx: 0, dy: 1).insetBy(dx: 1.5, dy: 0),
            xRadius: radius,
            yRadius: radius
        ).fill()

        cardFill.setFill()
        path.fill()

        // Top highlight kept inside the rim.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        structureHairline.setFill()
        NSBezierPath(rect: NSRect(x: rect.minX + radius / 2, y: rect.minY + 0.5, width: rect.width - radius, height: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()

        cardRim.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Small enamel icon well with a thin chrome rim, shared by every
    /// principal section title.
    static func drawIconWell(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        wellFill.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        chromeHighlight.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: NSRect(x: rect.minX + 2, y: rect.minY + 0.5, width: rect.width - 4, height: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()
        cardRim.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
/// Code-drawn 16pt glyph vocabulary for section titles. Drawn by hand (like
/// the existing provider marks) so the deployment target never depends on
/// SF Symbols availability, and every glyph shares one stroke weight.
enum BKIconGlyph {
    /// Dial with a needle — usage/quota.
    case gauge
    /// Clock face — reset schedules.
    case clock
    /// Card outline with a stripe — credits/spend.
    case creditCard
    /// Three bars — per-model limits and estimates.
    case chart
    /// Prompt chevron — a local CLI source.
    case terminal
    /// Circle with meridians — a web source.
    case globe
}

/// The icon-well unit: an enamel/chrome well (BK theme) or a bare glyph
/// (기본 theme), always drawn in charcoal ink at one shared optical scale.
final class BKIconWellView: NSView {
    var glyph: BKIconGlyph = .gauge { didSet { needsDisplay = true } }
    var theme: UsagePanelTheme = .light { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let wellRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        BKStyleTokens.drawIconWell(in: wellRect)
        let ink = BKStyleTokens.charcoalInk
        drawGlyph(in: bounds.insetBy(dx: 3.5, dy: 3.5), ink: ink)
    }

    private func drawGlyph(in rect: NSRect, ink: NSColor) {
        guard rect.width > 2, rect.height > 2 else { return }
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        switch glyph {
        case .gauge:
            // Open dial arc plus a needle to the upper right. Angles are in
            // the flipped coordinate space, so "up" is a negative-y sweep.
            path.appendArc(withCenter: center, radius: radius, startAngle: 200, endAngle: -20, clockwise: true)
            path.move(to: center)
            path.line(to: NSPoint(x: center.x + radius * 0.62, y: center.y - radius * 0.62))
        case .clock:
            path.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            path.move(to: center)
            path.line(to: NSPoint(x: center.x, y: center.y - radius * 0.58))
            path.move(to: center)
            path.line(to: NSPoint(x: center.x + radius * 0.42, y: center.y + radius * 0.18))
        case .creditCard:
            let card = NSRect(
                x: rect.minX,
                y: rect.minY + rect.height * 0.16,
                width: rect.width,
                height: rect.height * 0.68
            )
            path.appendRoundedRect(card, xRadius: 1.5, yRadius: 1.5)
            path.move(to: NSPoint(x: card.minX, y: card.minY + card.height * 0.34))
            path.line(to: NSPoint(x: card.maxX, y: card.minY + card.height * 0.34))
        case .chart:
            let baseline = rect.maxY
            let heights: [CGFloat] = [0.45, 0.8, 0.6]
            let step = rect.width / 3
            for (index, height) in heights.enumerated() {
                let x = rect.minX + step * (CGFloat(index) + 0.5)
                path.move(to: NSPoint(x: x, y: baseline))
                path.line(to: NSPoint(x: x, y: baseline - rect.height * height))
            }
        case .terminal:
            path.move(to: NSPoint(x: rect.minX, y: rect.minY + rect.height * 0.2))
            path.line(to: NSPoint(x: rect.minX + rect.width * 0.42, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - rect.height * 0.2))
            path.move(to: NSPoint(x: rect.midX, y: rect.maxY - rect.height * 0.12))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.12))
        case .globe:
            path.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            path.move(to: NSPoint(x: rect.minX, y: center.y))
            path.line(to: NSPoint(x: rect.maxX, y: center.y))
            path.appendOval(in: NSRect(
                x: center.x - radius * 0.45,
                y: rect.minY,
                width: radius * 0.9,
                height: rect.height
            ))
        }

        ink.setStroke()
        path.stroke()
    }
}

/// 상태·계열 색. 모두 공용 팔레트와 공급자 정체성 색에서 나온다.
enum CCMBColors {
    static var tokens: HTTPaletteTokens { HTTThemeSnapshot.ccmb }
    static var ink: NSColor { .htt(tokens.ink) }
    static var secondary: NSColor { .htt(tokens.ink2) }
    static var muted: NSColor { .htt(tokens.muted) }
    static var line: NSColor { .htt(tokens.line) }
    static var accent: NSColor { .htt(tokens.olive) }
    static var success: NSColor { .htt(tokens.success) }
    static var warn: NSColor { .htt(tokens.orange) }
    static var danger: NSColor { .htt(tokens.red) }
    static var info: NSColor { series(UsageBrandColors.geminiMainAccount) }

    /// 밝은 바탕에서는 공급자 색을 먹색 쪽으로 눌러 글자·선이 읽히게 하되 색상 차이는 유지한다.
    static func series(_ color: NSColor) -> NSColor {
        guard !tokens.isDark else { return color }
        return color.blended(withFraction: tokens.id == .friday ? 0.45 : 0.28, of: ink) ?? color
    }

    /// 밝은 테마의 막대 가장자리(--bar-edge).
    static func strokeBarEdge(_ path: NSBezierPath) {
        guard tokens.barEdgeAlpha > 0 else { return }
        NSColor.htt(tokens.ink, alpha: CGFloat(tokens.barEdgeAlpha)).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// 처음 만들 때 색을 정하는 화면이 테마 변경 때 다시 칠하는 약속.
@MainActor
protocol CCMBThemeRefreshing: AnyObject {
    func refreshTheme()
}

@MainActor
enum CCMBTheme {
    static var appearance: NSAppearance? {
        NSAppearance(named: CCMBColors.tokens.isDark ? .darkAqua : .aqua)
    }

    /// 열려 있는 화면 트리 전체에 현재 팔레트를 바로 적용한다.
    static func refresh(_ view: NSView) {
        (view as? CCMBThemeRefreshing)?.refreshTheme()
        view.needsDisplay = true
        view.subviews.forEach(refresh)
    }

    /// 메뉴 안에 놓인 화면은 시스템 메뉴 바탕 대신 팔레트 바탕을 쓴다(패널에서는 패널 배경과 투명도를 유지한다).
    static func fillMenuBackground(of view: NSView) {
        guard view.enclosingMenuItem != nil else { return }
        NSColor.htt(CCMBColors.tokens.paper).setFill()
        view.bounds.fill()
    }
}
