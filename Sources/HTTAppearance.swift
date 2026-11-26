import AppKit
import Combine
import HTTThemeCore
import SwiftUI

// MARK: - 병기스타일 테마 (Byungki-Style Themes)

/// 병기스타일 공통 5개 테마 선택지 ID (고정 순서: auto -> light -> friday -> jarvis -> ultron -> auto)
public enum HTTTheme: String, CaseIterable, Identifiable {
    case auto = "auto"
    case light = "light"
    case friday = "friday"
    case jarvis = "jarvis"
    case ultron = "ultron"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "자동 (시스템 설정)"
        case .light: return "라이트"
        case .friday: return "프라이데이"
        case .jarvis: return "자비스"
        case .ultron: return "울트론"
        }
    }

    public var next: HTTTheme {
        switch self {
        case .auto: return .light
        case .light: return .friday
        case .friday: return .jarvis
        case .jarvis: return .ultron
        case .ultron: return .light
        }
    }

    /// 저장값 마이그레이션 및 파싱
    public static func from(storedString: String?) -> HTTTheme {
        guard let stored = storedString?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty else {
            return .auto
        }
        if stored == "medium" { return .light }
        if stored == "dark" { return .jarvis }
        return HTTTheme(rawValue: stored) ?? .auto
    }
}

// MARK: - 병기스타일 테마 팔레트 (Palette Tokens)

public struct HTTThemePalette {
    public let bg: Color
    public let card: Color
    public let surface: Color
    public let surface2: Color
    public let text: Color
    public let text2: Color
    public let muted: Color
    public let border: Color
    public let border2: Color
    public let accent: Color
    public let accentStrong: Color
    public let accentSoft: Color
    public let onAccent: Color
    public let warn: Color
    public let warnSoft: Color
    public let warnInk: Color
    public let danger: Color
    public let dangerSoft: Color

    /// 색 값은 HTTThemeCore의 공용 팔레트 하나에서만 온다.
    public static let light = HTTThemePalette(tokens: .light)
    public static let friday = HTTThemePalette(tokens: .friday)
    public static let jarvis = HTTThemePalette(tokens: .jarvis)
    public static let ultron = HTTThemePalette(tokens: .ultron)
}

extension HTTThemePalette {
    public init(tokens t: HTTPaletteTokens) {
        self.init(
            bg: .htt(t.paper), card: .htt(t.card), surface: .htt(t.surface), surface2: .htt(t.surface2),
            text: .htt(t.ink), text2: .htt(t.ink2), muted: .htt(t.muted), border: .htt(t.line), border2: .htt(t.line2),
            accent: .htt(t.olive), accentStrong: .htt(t.oliveDeep), accentSoft: .htt(t.oliveSoft), onAccent: .htt(t.onAccent),
            warn: .htt(t.orange), warnSoft: .htt(t.orangeSoft), warnInk: .htt(t.warnInk),
            danger: .htt(t.red), dangerSoft: .htt(t.redSoft))
    }
}
// MARK: - 병기스타일 아이콘 스타일 (Icon Styles)

public enum HTTIconStyle: String, CaseIterable, Identifiable {
    case simple = "simple"
    case dimension = "dimension"
    case realistic = "realistic"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .simple: return "심플"
        case .dimension: return "입체"
        case .realistic: return "리얼"
        }
    }

    public var folderName: String {
        "\(rawValue)-design"
    }
}

// MARK: - 외관 저장소 (Appearance Store)

@MainActor
public final class HTTAppearanceStore: ObservableObject {
    public static let shared = HTTAppearanceStore()

    private let iconStyleKey = "HTTIconStyleSelection"
    private let center = HTTThemeCenter.shared
    private var centerObservation: AnyCancellable?

    /// 공용 테마 원본(`HTTThemeCenter`)의 값. 대입은 사용자의 직접 선택이며, 로그인 상태면 계정에 저장한다.
    public var theme: HTTTheme {
        get { HTTTheme(rawValue: center.selection.rawValue) ?? .auto }
        set { center.select(HTTThemeSelection(rawValue: newValue.rawValue) ?? .auto) }
    }

    /// 계정 연동 상태 안내.
    public var accountStatusText: String { center.status.label }

    @Published public var iconStyle: HTTIconStyle {
        didSet {
            UserDefaults.standard.set(iconStyle.rawValue, forKey: iconStyleKey)
        }
    }

    private init() {
        let storedIcon = UserDefaults.standard.string(forKey: iconStyleKey)
        if let storedIcon, let parsed = HTTIconStyle(rawValue: storedIcon) {
            self.iconStyle = parsed
        } else {
            self.iconStyle = .simple
            UserDefaults.standard.set(HTTIconStyle.simple.rawValue, forKey: iconStyleKey)
        }
        centerObservation = NotificationCenter.default.publisher(for: HTTThemeCenter.didChangeNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
    }

    public func palette(for systemColorScheme: ColorScheme) -> HTTThemePalette {
        HTTThemePalette(tokens: center.paletteID.tokens)
    }

    public func effectiveColorScheme(for systemColorScheme: ColorScheme) -> ColorScheme? {
        // `auto`도 공용 원본이 시스템 외형을 따라 팔레트를 고르므로 창은 시스템 설정에 맡긴다.
        theme == .auto ? nil : (center.paletteID.isDark ? .dark : .light)
    }

    public func cycleTheme() {
        theme = theme.next
    }
}

// MARK: - 아이콘 로더 및 뷰 (HTTIconView)

public struct HTTIconView: View {
    public let id: String
    public var size: CGFloat = 20

    @ObservedObject private var store = HTTAppearanceStore.shared

    public init(id: String, size: CGFloat = 20) {
        self.id = id
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = loadIconImage() {
                if store.iconStyle == .simple {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                } else {
                    Image(nsImage: image)
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                }
            } else {
                fallbackSymbol
            }
        }
    }

    private func loadIconImage() -> NSImage? {
        let packFolder = store.iconStyle.folderName
        // 번들 내부 Resources/InterfaceIcons/<pack>-design/png/256/<id>.png
        let relativePath = "InterfaceIcons/\(packFolder)/png/256/\(id).png"

        var url: URL?
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                url = candidate
            }
        }
        if url == nil {
            // 프로젝트 빌드 경로 및 리소스 탐색 대체
            let candidate = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(relativePath)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                url = candidate
            }
        }

        guard let targetURL = url, let image = NSImage(contentsOf: targetURL) else {
            return nil
        }

        if store.iconStyle == .simple {
            image.isTemplate = true
        }
        return image
    }

    @ViewBuilder
    private var fallbackSymbol: some View {
        let symbolName: String = {
            switch id {
            case "home": return "house.fill"
            case "browser": return "globe"
            case "mail": return "envelope.fill"
            case "screen": return "text.viewfinder"
            case "edit": return "pencil"
            case "device_files": return "internaldrive.fill"
            case "settings": return "gearshape.fill"
            case "help": return "questionmark.circle.fill"
            case "shield": return "shield.fill"
            case "theme": return "paintpalette.fill"
            default: return "app.fill"
            }
        }()

        Image(systemName: symbolName)
            .font(.system(size: size * 0.9))
            .frame(width: size, height: size)
    }
}

// MARK: - 병기스타일 테마 아이콘 벡터 렌더러 (HTTThemeIconShape)

public struct HTTThemeIconView: View {
    public let theme: HTTTheme
    public var size: CGFloat = 20

    public init(theme: HTTTheme, size: CGFloat = 20) {
        self.theme = theme
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 24.0
            var path = Path()

            switch theme {
            case .auto:
                let center = CGPoint(x: 12 * scale, y: 12 * scale)
                let radius = 8 * scale
                path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(path, with: .color(.primary), lineWidth: 1.7 * scale)

                var halfCircle = Path()
                halfCircle.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                halfCircle.closeSubpath()
                context.fill(halfCircle, with: .color(.primary))

            case .light:
                let center = CGPoint(x: 12 * scale, y: 12 * scale)
                let r = 3.8 * scale
                path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                // Rays
                let rays: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                    (12, 3.5, 12, 5.7), (12, 18.3, 12, 20.5), (3.5, 12, 5.7, 12), (18.3, 12, 20.5, 12),
                    (6, 6, 7.6, 7.6), (16.4, 16.4, 18, 18), (6, 18, 7.6, 16.4), (16.4, 7.6, 18, 6)
                ]
                for ray in rays {
                    path.move(to: CGPoint(x: ray.0 * scale, y: ray.1 * scale))
                    path.addLine(to: CGPoint(x: ray.2 * scale, y: ray.3 * scale))
                }
                context.stroke(path, with: .color(.primary), lineWidth: 1.7 * scale)

            case .friday:
                path.move(to: CGPoint(x: 12 * scale, y: 3 * scale))
                path.addLine(to: CGPoint(x: 19.8 * scale, y: 7.5 * scale))
                path.addLine(to: CGPoint(x: 19.8 * scale, y: 16.5 * scale))
                path.addLine(to: CGPoint(x: 12 * scale, y: 21 * scale))
                path.addLine(to: CGPoint(x: 4.2 * scale, y: 16.5 * scale))
                path.addLine(to: CGPoint(x: 4.2 * scale, y: 7.5 * scale))
                path.closeSubpath()
                context.stroke(path, with: .color(.primary), lineWidth: 1.7 * scale)

                var innerCircle = Path()
                let center = CGPoint(x: 12 * scale, y: 12 * scale)
                innerCircle.addEllipse(in: CGRect(x: center.x - 3 * scale, y: center.y - 3 * scale, width: 6 * scale, height: 6 * scale))
                context.fill(innerCircle, with: .color(.primary))

            case .jarvis:
                let center = CGPoint(x: 12 * scale, y: 12 * scale)
                let r1 = 9 * scale
                path.addEllipse(in: CGRect(x: center.x - r1, y: center.y - r1, width: r1 * 2, height: r1 * 2))
                context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 1.7 * scale, dash: [15.4 * scale, 3.45 * scale]))

                var innerCircle = Path()
                let r2 = 5 * scale
                innerCircle.addEllipse(in: CGRect(x: center.x - r2, y: center.y - r2, width: r2 * 2, height: r2 * 2))
                context.stroke(innerCircle, with: .color(.primary), lineWidth: 1.4 * scale)

                var dot = Path()
                let r3 = 1.7 * scale
                dot.addEllipse(in: CGRect(x: center.x - r3, y: center.y - r3, width: r3 * 2, height: r3 * 2))
                context.fill(dot, with: .color(.primary))

            case .ultron:
                path.move(to: CGPoint(x: 6 * scale, y: 4 * scale))
                path.addLine(to: CGPoint(x: 18 * scale, y: 4 * scale))
                path.addLine(to: CGPoint(x: 20.5 * scale, y: 9 * scale))
                path.addLine(to: CGPoint(x: 20.5 * scale, y: 15 * scale))
                path.addLine(to: CGPoint(x: 16.5 * scale, y: 20 * scale))
                path.addLine(to: CGPoint(x: 7.5 * scale, y: 20 * scale))
                path.addLine(to: CGPoint(x: 3.5 * scale, y: 15 * scale))
                path.addLine(to: CGPoint(x: 3.5 * scale, y: 9 * scale))
                path.closeSubpath()
                context.stroke(path, with: .color(.primary), lineWidth: 1.7 * scale)

                var mouth = Path()
                mouth.move(to: CGPoint(x: 9.5 * scale, y: 16.5 * scale))
                mouth.addLine(to: CGPoint(x: 14.5 * scale, y: 16.5 * scale))
                context.stroke(mouth, with: .color(.primary), lineWidth: 1.4 * scale)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 병기스타일 테마 전환 버튼 (HTTThemeButton)

public struct HTTThemeButton: View {
    @ObservedObject private var store = HTTAppearanceStore.shared
    @State private var showMenu = false
    @State private var longPressed = false

    public init() {}

    public var body: some View {
        Button {
            if !longPressed {
                store.cycleTheme()
            }
            longPressed = false
        } label: {
            HStack(spacing: 6) {
                HTTThemeIconView(theme: store.theme, size: 16)
                Text(store.theme.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    longPressed = true
                    showMenu = true
                }
        )
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("병기스타일 테마")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                Divider()
                ForEach(HTTTheme.allCases) { item in
                    Button {
                        store.theme = item
                        showMenu = false
                    } label: {
                        HStack {
                            HTTThemeIconView(theme: item, size: 14)
                            Text(item.displayName)
                            Spacer()
                            if store.theme == item {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                Divider()
                Text(store.accountStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
            .padding(6)
            .frame(width: 190)
        }
        .contextMenu {
            ForEach(HTTTheme.allCases) { item in
                Button {
                    store.theme = item
                } label: {
                    if store.theme == item {
                        Label(item.displayName, systemImage: "checkmark")
                    } else {
                        Text(item.displayName)
                    }
                }
            }
        }
        .accessibilityLabel("병기스타일 테마: \(store.theme.displayName) (누르면 \(store.theme.next.displayName), 길게 누르면 목록)")
    }
}
