import SwiftUI
import AppKit

// MARK: - 병기스타일 테마 (byungki-style-theme)

/// The persisted choice. Fixed order; the last one cycles back to the first. `auto` is not a palette: it follows
/// the system (light → `light`, dark → `jarvis`).
enum ThemeChoice: String, CaseIterable {
    case auto, light, friday, jarvis, ultron

    var label: String {
        switch self {
        case .auto: return "자동"
        case .light: return "라이트"
        case .friday: return "프라이데이"
        case .jarvis: return "자비스"
        case .ultron: return "울트론"
        }
    }

    var menuTitle: String { self == .auto ? "자동 (시스템 설정)" : label }

    var next: ThemeChoice {
        switch self {
        case .auto, .ultron: return .light
        case .light: return .friday
        case .friday: return .jarvis
        case .jarvis: return .ultron
        }
    }

    func resolved(systemIsDark: Bool) -> Palette {
        switch self {
        case .auto: return systemIsDark ? .jarvis : .light
        case .light: return .light
        case .friday: return .friday
        case .jarvis: return .jarvis
        case .ultron: return .ultron
        }
    }

    /// Stored value → choice. Legacy `medium`/`dark` migrate; anything else unknown is `auto`.
    static func fromStored(_ raw: String?) -> (choice: ThemeChoice, migrated: Bool) {
        guard let raw = raw else { return (.auto, false) }
        if let c = ThemeChoice(rawValue: raw) { return (c, false) }
        switch raw {
        case "medium": return (.light, true)
        case "dark": return (.jarvis, true)
        default: return (.auto, true)   // includes the old "default" name of 자동
        }
    }
}

/// Exact token values of the reference palette table.
struct Palette: Equatable {
    let id: String
    let isDark: Bool
    let bg, card, surface, surface2, text, text2, muted, border, border2: UInt32
    let accent, accentStrong, accentSoft, onAccent, warn, warnSoft, warnInk, danger, dangerSoft: UInt32

    static let light = Palette(
        id: "light", isDark: false,
        bg: 0xf5f4f0, card: 0xfbfaf7, surface: 0xffffff, surface2: 0xecebe4, text: 0x1f211c, text2: 0x4a4c44,
        muted: 0x666860, border: 0xe2dfd5, border2: 0xd0cdc0, accent: 0x5c6b3c, accentStrong: 0x46532c,
        accentSoft: 0xe8ebdb, onAccent: 0xffffff, warn: 0x9c5415, warnSoft: 0xf7e9d8, warnInk: 0x6d3c10,
        danger: 0x9c3b2a, dangerSoft: 0xf6e3de)
    static let friday = Palette(
        id: "friday", isDark: false,
        bg: 0xf7efe3, card: 0xfffaf1, surface: 0xfffdf8, surface2: 0xf0e2cc, text: 0x2a1f16, text2: 0x55422f,
        muted: 0x725b45, border: 0xe8d8c0, border2: 0xd3bb98, accent: 0x9a4a12, accentStrong: 0x743508,
        accentSoft: 0xf6dfc0, onAccent: 0xffffff, warn: 0x8a5a00, warnSoft: 0xf8e6b8, warnInk: 0x6d3c10,
        danger: 0xa3204a, dangerSoft: 0xf8dce4)
    static let jarvis = Palette(
        id: "jarvis", isDark: true,
        bg: 0x0c1420, card: 0x121c2b, surface: 0x162337, surface2: 0x1c2d44, text: 0xe3edf7, text2: 0xb3c4d6,
        muted: 0x8da2b8, border: 0x20324a, border2: 0x2d4663, accent: 0x4cc2e6, accentStrong: 0x8fdcf3,
        accentSoft: 0x12324a, onAccent: 0x04202b, warn: 0xf0b45c, warnSoft: 0x3a2d16, warnInk: 0xf4cf94,
        danger: 0xf28b82, dangerSoft: 0x3d2126)
    static let ultron = Palette(
        id: "ultron", isDark: true,
        bg: 0x121316, card: 0x1a1c20, surface: 0x202328, surface2: 0x272a30, text: 0xe6e7ea, text2: 0xb8bbc2,
        muted: 0x8e929b, border: 0x2b2e34, border2: 0x3b3f47, accent: 0xf2566a, accentStrong: 0xff8a95,
        accentSoft: 0x3a1a20, onAccent: 0x1a0508, warn: 0xe8a24f, warnSoft: 0x36291a, warnInk: 0xf2c27f,
        danger: 0xff9a9a, dangerSoft: 0x3e1f22)
}

extension Palette {
    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255, opacity: 1)
    }
    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    var bgColor: Color { Self.color(bg) }
    var cardColor: Color { Self.color(card) }
    var surfaceColor: Color { Self.color(surface) }
    var surface2Color: Color { Self.color(surface2) }
    var textColor: Color { Self.color(text) }
    var text2Color: Color { Self.color(text2) }
    var mutedColor: Color { Self.color(muted) }
    var borderColor: Color { Self.color(border) }
    var border2Color: Color { Self.color(border2) }
    var accentColor: Color { Self.color(accent) }
    var accentStrongColor: Color { Self.color(accentStrong) }
    var accentSoftColor: Color { Self.color(accentSoft) }
    var onAccentColor: Color { Self.color(onAccent) }
    var warnColor: Color { Self.color(warn) }
    var warnSoftColor: Color { Self.color(warnSoft) }
    var warnInkColor: Color { Self.color(warnInk) }
    var dangerColor: Color { Self.color(danger) }
    var dangerSoftColor: Color { Self.color(dangerSoft) }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = .light
}

extension EnvironmentValues {
    var bkPalette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Selection + live system appearance. Loaded synchronously in `init` (before the first render); only the
/// production configuration reads or writes UserDefaults, so isolated runs never touch the real preference.
@MainActor
final class AppearanceStore: ObservableObject {
    static let defaultsKey = "byungkiTheme"

    @Published private(set) var choice: ThemeChoice
    @Published private(set) var systemIsDark: Bool
    private let persists: Bool
    private var observation: NSKeyValueObservation?

    var palette: Palette { choice.resolved(systemIsDark: systemIsDark) }

    init(persists: Bool = AppConfiguration.production().usesUserDefaults) {
        self.persists = persists
        let stored = persists ? HTDBrowserDefaults.standard.string(forKey: Self.defaultsKey) : nil
        let (choice, migrated) = ThemeChoice.fromStored(stored)
        self.choice = choice
        if let app = NSApp as NSApplication? {
            systemIsDark = Self.isDark(app.effectiveAppearance)
        } else {
            systemIsDark = HTDBrowserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }
        if persists && migrated { HTDBrowserDefaults.standard.set(choice.rawValue, forKey: Self.defaultsKey) }
        startObservingSystem()
    }

    /// Follows the system light/dark setting live (the app never sets NSApp.appearance, only window appearance).
    func startObservingSystem() {
        guard observation == nil, let app = NSApp as NSApplication? else { return }
        systemIsDark = Self.isDark(app.effectiveAppearance)
        observation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshSystem() }
        }
    }

    private func refreshSystem() {
        guard let app = NSApp as NSApplication? else { return }
        let dark = Self.isDark(app.effectiveAppearance)
        if systemIsDark != dark { systemIsDark = dark }
    }

    func select(_ choice: ThemeChoice) {
        self.choice = choice
        if persists { HTDBrowserDefaults.standard.set(choice.rawValue, forKey: Self.defaultsKey) }
    }

    func cycle() { select(choice.next) }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Applying the palette

extension View {
    /// Palette tokens for text/tint/environment plus the matching native control appearance for the hosting window.
    func byungkiThemed(_ palette: Palette) -> some View {
        self
            .environment(\.bkPalette, palette)
            // Primary only (foregroundColor): a two-level foregroundStyle(text, muted) makes native .bordered/Menu bezels
            // fill with the muted secondary level (solid dark gray / brown on 라이트·프라이데이). Secondary text falls
            // back to the system secondary for the colorScheme set below.
            .foregroundColor(palette.textColor)
            .tint(palette.accentColor)
            // Drives SwiftUI's colorScheme (adaptive Color.secondary, Divider, system alerts, sheets) from the palette
            // instead of the OS setting; the bridge below still sets the NSWindow side.
            .preferredColorScheme(palette.isDark ? .dark : .light)
            .background(WindowAppearanceBridge(palette: palette))
    }
}

/// Sets the hosting window's NSAppearance (aqua / darkAqua) so native controls stay readable on the palette.
struct WindowAppearanceBridge: NSViewRepresentable {
    let palette: Palette

    final class BridgeView: NSView {
        var palette: Palette = .light
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            guard let window = window else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self, weak window] in
                guard let self = self, let targetWindow = window, self.window === targetWindow else { return }
                self.apply()
            }
        }
        func apply() {
            guard let window = window else { return }
            let name: NSAppearance.Name = palette.isDark ? .darkAqua : .aqua
            if window.appearance?.name != name { window.appearance = NSAppearance(named: name) }
            window.backgroundColor = Palette.nsColor(palette.bg)
        }
    }

    func makeNSView(context: Context) -> BridgeView {
        let v = BridgeView()
        v.palette = palette
        return v
    }

    func updateNSView(_ nsView: BridgeView, context: Context) {
        nsView.palette = palette
        nsView.apply()
    }
}

/// Filled accent button using `accent` / `onAccent` (system prominent buttons always draw white text, which is
/// unreadable on the light cyan of 자비스).
struct BKProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        @Environment(\.bkPalette) private var palette
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize

        var body: some View {
            let small = controlSize == .small || controlSize == .mini
            configuration.label
                .font(.system(size: small ? 11 : 13, weight: .semibold))
                .foregroundStyle(palette.onAccentColor)
                .padding(.horizontal, small ? 8 : 10)
                .padding(.vertical, small ? 2 : 4)
                .background(
                    RoundedRectangle(cornerRadius: small ? 5 : 6)
                        .fill(configuration.isPressed ? palette.accentStrongColor : palette.accentColor))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

extension ButtonStyle where Self == BKProminentButtonStyle {
    static var bkProminent: BKProminentButtonStyle { BKProminentButtonStyle() }
}

// MARK: - Theme button (header)

/// Short click / Enter / Space: next theme. 500ms press, right click, ↓, Shift+F10 or the menu key: native list of all
/// five. AppKit-backed so press timing, click suppression and keyboard focus behave like a native control.
struct ThemeButton: NSViewRepresentable {
    @ObservedObject var store: AppearanceStore

    func makeNSView(context: Context) -> ThemeButtonView {
        let v = ThemeButtonView()
        update(v)
        return v
    }

    func updateNSView(_ nsView: ThemeButtonView, context: Context) {
        update(nsView)
    }

    private func update(_ v: ThemeButtonView) {
        let s = store   // lives for the whole app (App @StateObject)
        v.choice = s.choice
        v.palette = s.palette
        v.onSelect = { s.select($0) }
        v.needsDisplay = true
    }
}

final class ThemeButtonView: NSView {
    var choice: ThemeChoice = .auto { didSet { if oldValue != choice { refreshAccessibility() } } }
    var palette: Palette = .light
    var onSelect: (ThemeChoice) -> Void = { _ in }

    private static let side: CGFloat = 26
    private static let glyph: CGFloat = 20
    private var pressTimer: Timer?
    private var pressStart: NSPoint?
    private var pressActive = false
    private var suppressClick = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        refreshAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var accessibilityText: String {
        "병기스타일 테마: \(choice.label) (누르면 \(choice.next.label), 길게 누르면 목록)"
    }

    private func refreshAccessibility() {
        toolTip = accessibilityText
        NSAccessibility.post(element: self, notification: .titleChanged)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityText }
    override func accessibilityValue() -> Any? { choice.label }
    override func accessibilityPerformPress() -> Bool { cycle(); return true }
    override func accessibilityPerformShowMenu() -> Bool { showMenu(fromKeyboard: true); return true }

    // MARK: Drawing

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        cancelPress()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        let fill = (pressActive || hovering) ? palette.surface2 : palette.surface
        Palette.nsColor(fill).setFill()
        box.fill()
        Palette.nsColor(palette.border2).setStroke()
        box.lineWidth = 1
        box.stroke()

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let inset = (bounds.width - Self.glyph) / 2
        ctx.translateBy(x: inset, y: (bounds.height - Self.glyph) / 2)
        ctx.scaleBy(x: Self.glyph / 24, y: Self.glyph / 24)
        ThemeGlyph.draw(choice, in: ctx, color: Palette.nsColor(palette.accent).cgColor)
        ctx.restoreGState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        cancelPress()
        needsDisplay = true
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        suppressClick = false   // a click swallowed by an earlier menu never carries over to a new press
        pressActive = true
        pressStart = convert(event.locationInWindow, from: nil)
        needsDisplay = true
        pressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.longPressFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pressTimer = timer
    }

    private func longPressFired() {
        guard pressActive else { return }
        pressActive = false
        pressTimer = nil
        suppressClick = true   // the click that follows the long press must not also cycle
        needsDisplay = true
        showMenu(fromKeyboard: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressActive, let start = pressStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - start.x, p.y - start.y) > 10 || !bounds.contains(p) { cancelPress() }
    }

    override func mouseUp(with event: NSEvent) {
        pressTimer?.invalidate()
        pressTimer = nil
        if suppressClick {
            suppressClick = false
            return
        }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let wasActive = pressActive
        pressActive = false
        needsDisplay = true
        if wasActive && inside { cycle() }
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelPress()
        showMenu(fromKeyboard: false)
    }

    private func cancelPress() {
        pressTimer?.invalidate()
        pressTimer = nil
        if pressActive {
            pressActive = false
            needsDisplay = true
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49:   // Return, keypad Enter, Space
            cycle()
        case 125:          // ↓
            showMenu(fromKeyboard: true)
        case 109 where event.modifierFlags.contains(.shift):   // Shift+F10
            showMenu(fromKeyboard: true)
        case 110:          // menu (contextual) key
            showMenu(fromKeyboard: true)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Actions

    private func cycle() {
        onSelect(choice.next)
    }

    private func showMenu(fromKeyboard: Bool) {
        let menu = NSMenu(title: "병기스타일 테마")
        menu.autoenablesItems = false
        for c in ThemeChoice.allCases {
            let item = NSMenuItem(title: c.menuTitle, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.rawValue
            item.state = c == choice ? .on : .off   // native checkmark = checked menu item for VoiceOver
            menu.addItem(item)
        }
        // Opens below the button; arrows / Return / Esc are the native menu keys.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        if fromKeyboard || window?.firstResponder === self {
            window?.makeFirstResponder(self)   // Esc / selection returns focus to the button
        }
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let c = ThemeChoice(rawValue: raw) else { return }
        onSelect(c)
    }
}

/// The reference 24×24 glyphs (stroke 1.7, round caps/joins, colour = accent), drawn in a y-down 24-unit space.
enum ThemeGlyph {
    static func draw(_ choice: ThemeChoice, in ctx: CGContext, color: CGColor) {
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(1.7)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let c = CGPoint(x: 12, y: 12)

        func circle(_ r: CGFloat) -> CGRect { CGRect(x: 12 - r, y: 12 - r, width: 2 * r, height: 2 * r) }
        func lines(_ segs: [(CGFloat, CGFloat, CGFloat, CGFloat)], width: CGFloat = 1.7) {
            ctx.setLineWidth(width)
            for s in segs {
                ctx.move(to: CGPoint(x: s.0, y: s.1))
                ctx.addLine(to: CGPoint(x: s.2, y: s.3))
            }
            ctx.strokePath()
            ctx.setLineWidth(1.7)
        }
        func polygon(_ pts: [(CGFloat, CGFloat)]) {
            ctx.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
            for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
            ctx.closePath()
        }

        switch choice {
        case .auto:
            // <circle r=8/><path d="M12 4a8 8 0 0 0 0 16z" fill/> — left half filled.
            ctx.strokeEllipse(in: circle(8))
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: 12, height: 24))
            ctx.fillEllipse(in: circle(8))
            ctx.restoreGState()
        case .light:
            ctx.strokeEllipse(in: circle(3.8))
            lines([(12, 3.5, 12, 5.7), (12, 18.3, 12, 20.5), (3.5, 12, 5.7, 12), (18.3, 12, 20.5, 12),
                   (6, 6, 7.6, 7.6), (16.4, 16.4, 18, 18), (6, 18, 7.6, 16.4), (16.4, 7.6, 18, 6)])
        case .jarvis:
            // r=9, dasharray 15.4 3.45, rotate(-80): three arcs starting at -80°, clockwise on screen.
            ctx.saveGState()
            let start = -80 * CGFloat.pi / 180
            ctx.addArc(center: c, radius: 9, startAngle: start, endAngle: start + 2 * .pi, clockwise: false)
            ctx.setLineDash(phase: 0, lengths: [15.4, 3.45])
            ctx.strokePath()
            ctx.restoreGState()
            ctx.setLineWidth(1.4)
            ctx.strokeEllipse(in: circle(5))
            ctx.fillEllipse(in: circle(1.7))
        case .friday:
            polygon([(12, 3), (19.8, 7.5), (19.8, 16.5), (12, 21), (4.2, 16.5), (4.2, 7.5)])
            ctx.strokePath()
            ctx.fillEllipse(in: circle(3))
            lines([(12, 9, 12, 6.5), (12, 17.5, 12, 15), (9, 12, 6.5, 12), (17.5, 12, 15, 12)], width: 1.4)
        case .ultron:
            polygon([(6, 4), (18, 4), (20.5, 9), (20.5, 15), (16.5, 20), (7.5, 20), (3.5, 15), (3.5, 9)])
            ctx.strokePath()
            polygon([(7.4, 10.4), (11, 11.7), (10.7, 13.1), (7.4, 12.2)])
            polygon([(16.6, 10.4), (13, 11.7), (13.3, 13.1), (16.6, 12.2)])
            ctx.fillPath()
            lines([(9.5, 16.5, 14.5, 16.5)], width: 1.4)
        }
    }
}
