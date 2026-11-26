import AppKit
import SwiftUI

/// 놀이터 계정·하나·웹·HanTool이 함께 쓰는 네 가지 테마 ID. 서버 `/api/ui-preferences`의 `theme` 값과 같다.
public enum HTTPaletteID: String, CaseIterable, Sendable {
    case light, friday, jarvis, ultron

    public var isDark: Bool { self == .jarvis || self == .ultron }

    public var tokens: HTTPaletteTokens {
        switch self {
        case .light: return .light
        case .friday: return .friday
        case .jarvis: return .jarvis
        case .ultron: return .ultron
        }
    }
}

/// Mac 전체(작업 창·브라우저·하나 패널·서버 현황)의 유일한 색 원본.
/// 값은 웹 작업실 CSS 변수와 1:1이다: paper, card, surface, surface-2, ink, ink-2, muted, line, line-2,
/// olive, olive-deep, olive-soft, on-accent, orange, orange-soft, warn-ink, warn-line, red, red-soft 등.
public struct HTTPaletteTokens: Equatable, Sendable {
    public let id: HTTPaletteID
    public let paper, card, surface, surface2: UInt32
    public let ink, ink2, muted: UInt32
    public let line, line2: UInt32
    public let olive, oliveDeep, oliveSoft, onAccent: UInt32
    public let orange, orangeSoft, warnInk, warnLine: UInt32
    public let red, redSoft: UInt32
    public let codeBg, approvalBg, ringTrack: UInt32
    /// 밝은 테마에서만 막대 가장자리를 그린다(--bar-edge). 어두운 테마는 투명.
    public let barEdgeAlpha: Double

    public var isDark: Bool { id.isDark }

    public static let light = HTTPaletteTokens(
        id: .light,
        paper: 0xf5f4f0, card: 0xfbfaf7, surface: 0xffffff, surface2: 0xecebe4,
        ink: 0x1f211c, ink2: 0x4a4c44, muted: 0x666860,
        line: 0xe2dfd5, line2: 0xd0cdc0,
        olive: 0x5c6b3c, oliveDeep: 0x46532c, oliveSoft: 0xe8ebdb, onAccent: 0xffffff,
        orange: 0x9c5415, orangeSoft: 0xf7e9d8, warnInk: 0x6d3c10, warnLine: 0xe6c49c,
        red: 0x9c3b2a, redSoft: 0xf6e3de,
        codeBg: 0xf0eee7, approvalBg: 0xfffaf3, ringTrack: 0xc4bdad,
        barEdgeAlpha: 0.35)

    public static let friday = HTTPaletteTokens(
        id: .friday,
        paper: 0xd9d3c7, card: 0xe6e1d6, surface: 0xece8df, surface2: 0xcfc8ba,
        ink: 0x1f211c, ink2: 0x3a3a34, muted: 0x4f4d46,
        line: 0xbdb6a7, line2: 0xa9a292,
        olive: 0x46532c, oliveDeep: 0x38431f, oliveSoft: 0xcdd0b8, onAccent: 0xffffff,
        orange: 0x7d420f, orangeSoft: 0xe3cfae, warnInk: 0x6d3c10, warnLine: 0xb8975f,
        red: 0x8a2f1f, redSoft: 0xe6cfc6,
        codeBg: 0xcdc6b8, approvalBg: 0xe6dcc6, ringTrack: 0x8f8878,
        barEdgeAlpha: 0.35)

    public static let jarvis = HTTPaletteTokens(
        id: .jarvis,
        paper: 0x0c1420, card: 0x121c2b, surface: 0x162337, surface2: 0x1c2d44,
        ink: 0xe3edf7, ink2: 0xb3c4d6, muted: 0x8da2b8,
        line: 0x20324a, line2: 0x2d4663,
        olive: 0x4cc2e6, oliveDeep: 0x8fdcf3, oliveSoft: 0x12324a, onAccent: 0x04202b,
        orange: 0xf0b45c, orangeSoft: 0x3a2d16, warnInk: 0xf4cf94, warnLine: 0x6b5127,
        red: 0xf28b82, redSoft: 0x3d2126,
        codeBg: 0x0f1a29, approvalBg: 0x1d2a3b, ringTrack: 0x3a5778,
        barEdgeAlpha: 0)

    public static let ultron = HTTPaletteTokens(
        id: .ultron,
        paper: 0x121316, card: 0x1a1c20, surface: 0x202328, surface2: 0x272a30,
        ink: 0xe6e7ea, ink2: 0xb8bbc2, muted: 0x8e929b,
        line: 0x2b2e34, line2: 0x3b3f47,
        olive: 0xf2566a, oliveDeep: 0xff8a95, oliveSoft: 0x3a1a20, onAccent: 0x1a0508,
        orange: 0xe8a24f, orangeSoft: 0x36291a, warnInk: 0xf2c27f, warnLine: 0x6b5127,
        red: 0xff9a9a, redSoft: 0x3e1f22,
        codeBg: 0x16181b, approvalBg: 0x241d1f, ringTrack: 0x4a4f59,
        barEdgeAlpha: 0)
}

/// 공급자 정체성 색(--c-*). 모든 테마에서 같은 값으로 차트 계열을 구분한다.
public enum HTTProviderColors {
    public static let codex: UInt32 = 0x10a37f
    public static let codexSpark: UInt32 = 0x6fd3b4
    public static let claude: UInt32 = 0xd97757
    public static let claudeWeekly: UInt32 = 0xc45d42
    public static let claudeFable: UInt32 = 0xe69a7f
    public static let geminiBlue: UInt32 = 0x4285f4
    public static let geminiRed: UInt32 = 0xea4335
    public static let geminiYellow: UInt32 = 0xfbbc05
    public static let geminiGreen: UInt32 = 0x34a853
}

public extension NSColor {
    /// sRGB 6자리 값. CSS 값과 같은 화면 색이 나오도록 calibrated 색 공간은 쓰지 않는다.
    static func htt(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

public extension Color {
    static func htt(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

public extension HTTPaletteTokens {
    /// 정상·성공 표시. CSS에 없는 값이라 공급자 초록 계열을 밝기에 맞춰 쓴다(강조색이 빨강인 테마에서도 구분된다).
    var success: UInt32 { isDark ? 0x6fd3b4 : (id == .friday ? 0x1e5c3c : 0x27754c) }
}

/// SwiftUI 화면이 쓰는 색 이름.
public enum HTTToken: Sendable {
    case paper, card, surface, surface2, ink, muted, line, accent, accentSoft, onAccent
    case success, warn, warnSoft, danger, dangerSoft

    public func hex(in t: HTTPaletteTokens) -> UInt32 {
        switch self {
        case .paper: return t.paper
        case .card: return t.card
        case .surface: return t.surface
        case .surface2: return t.surface2
        case .ink: return t.ink
        case .muted: return t.muted
        case .line: return t.line
        case .accent: return t.olive
        case .accentSoft: return t.oliveSoft
        case .onAccent: return t.onAccent
        case .success: return t.success
        case .warn: return t.orange
        case .warnSoft: return t.orangeSoft
        case .danger: return t.red
        case .dangerSoft: return t.redSoft
        }
    }
}

private struct HTTPaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue: HTTPaletteTokens? = nil
}

public extension EnvironmentValues {
    /// 작업 창 루트가 넣는 현재 팔레트. 바뀌면 `HTTStyle`을 쓰는 화면이 바로 다시 칠해진다.
    var httPalette: HTTPaletteTokens? {
        get { self[HTTPaletteEnvironmentKey.self] }
        set { self[HTTPaletteEnvironmentKey.self] = newValue }
    }
}

/// 환경의 팔레트에서 색을 고르는 스타일(루트 밖의 창은 현재 값을 쓴다).
public struct HTTStyle: ShapeStyle, Sendable {
    public let token: HTTToken
    public init(_ token: HTTToken) { self.token = token }
    public func resolve(in environment: EnvironmentValues) -> Color {
        Color.htt(token.hex(in: environment.httPalette ?? HTTThemeSnapshot.app))
    }
}

public extension ShapeStyle where Self == HTTStyle {
    static var httPaper: HTTStyle { HTTStyle(.paper) }
    static var httCard: HTTStyle { HTTStyle(.card) }
    static var httSurface: HTTStyle { HTTStyle(.surface) }
    static var httSurface2: HTTStyle { HTTStyle(.surface2) }
    static var httMuted: HTTStyle { HTTStyle(.muted) }
    static var httAccent: HTTStyle { HTTStyle(.accent) }
    static var httAccentSoft: HTTStyle { HTTStyle(.accentSoft) }
    static var httOnAccent: HTTStyle { HTTStyle(.onAccent) }
    static var httSuccess: HTTStyle { HTTStyle(.success) }
    static var httWarn: HTTStyle { HTTStyle(.warn) }
    static var httWarnSoft: HTTStyle { HTTStyle(.warnSoft) }
    static var httDanger: HTTStyle { HTTStyle(.danger) }
}
