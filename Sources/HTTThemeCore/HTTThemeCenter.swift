import AppKit
import Combine
import OSLog

/// 사용자가 고를 수 있는 값. `auto`는 이 Mac에서만 쓰는 값이며(시스템 밝음 → light, 어두움 → jarvis) 계정에 저장하지 않는다.
public enum HTTThemeSelection: String, CaseIterable, Sendable {
    case auto, light, friday, jarvis, ultron

    public init(_ palette: HTTPaletteID) { self = HTTThemeSelection(rawValue: palette.rawValue) ?? .auto }

    public var palette: HTTPaletteID? { HTTPaletteID(rawValue: rawValue) }

    /// 저장값 → 선택. 예전 값 `medium`/`dark`는 옮기고, 모르는 값은 `auto`.
    public static func fromStored(_ raw: String?) -> HTTThemeSelection {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .auto }
        if raw == "medium" { return .light }
        if raw == "dark" { return .jarvis }
        return HTTThemeSelection(rawValue: raw) ?? .auto
    }
}

/// 계정 연동 상태. 메뉴·설정에 그대로 보여 "계정 확인 불가"와 "로그인됨"을 구분한다.
public enum HTTThemeAccountStatus: Equatable, Sendable {
    case unknown, signedOut, signedIn, unavailable, unsupported, saveFailed

    public var label: String {
        switch self {
        case .unknown: return "계정 확인 전 · 이 Mac 설정"
        case .signedOut: return "하나 로그아웃 상태 · 이 Mac 설정"
        case .signedIn: return "놀이터 계정 테마와 연동 중"
        case .unavailable: return "계정 확인 불가 · 현재 화면 유지"
        case .unsupported: return "서버가 계정 테마를 아직 지원하지 않음 · 이 Mac 설정"
        case .saveFailed: return "계정에 저장하지 못함 · 이 Mac에만 임시 적용"
        }
    }
}

/// 한 번의 계정 읽기/쓰기 결과. `account`는 메모리에서만 비교하는 계정 구분값이며 저장하지 않는다.
public enum HTTAccountThemeResult: Equatable, Sendable {
    case signedIn(account: String, supportsTheme: Bool, theme: HTTPaletteID?)
    case signedOut
    /// 요청 도중 로그인 계정이 바뀌었다. 결과를 적용하지 않고 다시 읽는다.
    case accountChanged
    case unavailable
}

/// 신뢰하는 놀이터 웹 세션으로 계정 설정을 읽고 쓰는 쪽(하나 패널). 반드시 한 번 끝나야 한다.
@MainActor
public protocol HTTAccountThemeTransport: AnyObject {
    func readAccountTheme() async -> HTTAccountThemeResult
    func writeAccountTheme(_ theme: HTTPaletteID, expectedAccount: String) async -> HTTAccountThemeResult
}

/// 그리기 코드(AppKit `draw`, 정적 색 토큰)가 어디서든 읽는 현재 값. 메인 스레드에서 `HTTThemeCenter`만 바꾼다.
public enum HTTThemeSnapshot {
    nonisolated(unsafe) public fileprivate(set) static var app: HTTPaletteTokens = .light
    nonisolated(unsafe) public fileprivate(set) static var ccmb: HTTPaletteTokens = .light
}

/// 테마의 단일 원본. 이 Mac의 선택, 로그인한 계정의 테마, 두 값의 우선순위와 계정 동기화 순서를 소유한다.
///
/// - 계정 값은 메모리에만 두고 이 Mac의 저장값에 쓰지 않는다. 로그아웃·계정 전환 때 이전 계정 값은 남지 않는다.
/// - 서버 쓰기는 `select(_:)`(사용자가 직접 고른 경우)에서만 생기며, 고른 순간의 계정에만 보낸다.
/// - 읽기·쓰기는 한 번에 하나씩 처리하고, 그 사이 새 선택이나 새 문서가 생기면 늦은 결과를 버린다.
@MainActor
public final class HTTThemeCenter: ObservableObject {
    public static let shared = HTTThemeCenter(drivesSnapshot: true)

    /// 팔레트가 바뀐 직후(동기). AppKit 화면은 이 알림에서 색을 다시 입힌다.
    public static let didChangeNotification = Notification.Name("HTTThemeCenterDidChange")
    /// 계정 저장이 서버에서 확인된 직후.
    public static let accountThemeSavedNotification = Notification.Name("HTTThemeCenterAccountThemeSaved")

    static let selectionKey = "HTTThemeSelection"
    static let unifiedKey = "HTTThemeUnifiedSelection"

    private struct Account: Equatable {
        let key: String
        var theme: HTTPaletteID?
        /// 계정 값보다 우선하는 이번 로그인 동안의 선택: 저장 중/저장 실패한 값, 또는 `auto`.
        var override: HTTThemeSelection?
    }

    private struct PendingWrite {
        let theme: HTTPaletteID
        let account: String
        let sequence: Int
    }

    private let defaults: UserDefaults
    private let systemIsDarkProvider: (() -> Bool)?
    private var localChoice: HTTThemeSelection
    private var ccmbLegacy: HTTPaletteID?
    private var account: Account?
    private var systemIsDark = false
    private var appearanceObservation: NSKeyValueObservation?

    private weak var transport: HTTAccountThemeTransport?
    /// 첫 갱신 요청 때 연결 통로를 만든다(아직 준비할 수 없으면 nil).
    public var transportProvider: (@MainActor () -> HTTAccountThemeTransport?)?
    private var documentEpoch = 0
    private var writeSequence = 0
    private var pendingWrite: PendingWrite?
    private var refreshRequested = false
    private var busy = false
    private let drivesSnapshot: Bool
    private var lastLoggedState = ""
    private static let logger = Logger(subsystem: "com.local.screentranslator", category: "ThemeSync")

    @Published public private(set) var status: HTTThemeAccountStatus = .unknown
    /// 선택·팔레트·상태가 바뀔 때마다 증가한다.
    @Published public private(set) var revision = 0

    public init(defaults: UserDefaults = .standard, systemIsDark: (() -> Bool)? = nil, drivesSnapshot: Bool = false) {
        self.defaults = defaults
        self.drivesSnapshot = drivesSnapshot
        self.systemIsDarkProvider = systemIsDark
        let stored = defaults.string(forKey: Self.selectionKey)
        localChoice = HTTThemeSelection.fromStored(stored)
        if stored != localChoice.rawValue { defaults.set(localChoice.rawValue, forKey: Self.selectionKey) }
        self.systemIsDark = currentSystemIsDark()
        observeSystemAppearance()
        updateSnapshots()
    }

    // MARK: - 현재 값

    /// 화면에 표시하는 선택값(계정 > 이 Mac).
    public var selection: HTTThemeSelection {
        if let account {
            if let override = account.override { return override }
            if let theme = account.theme { return HTTThemeSelection(theme) }
        }
        return localChoice
    }

    public var paletteID: HTTPaletteID { resolve(selection) }

    /// 서버 현황(CCMB)의 팔레트. 로그인 계정을 확인하기 전(오프라인·로그아웃)이고 업데이트 뒤 직접 고른 적이 없으면
    /// CCMB의 예전 선택을 그대로 둔다. 그 밖에는 앱 전체와 같다.
    public var ccmbPaletteID: HTTPaletteID {
        if account == nil, !defaults.bool(forKey: Self.unifiedKey), let ccmbLegacy { return ccmbLegacy }
        return paletteID
    }

    public var isAccountLinked: Bool { account != nil }

    /// 계정 값이 있거나 사용자가 이 Mac에서 직접 고른 뒤에만 하나 웹 화면에도 같은 테마를 보인다.
    /// 그 전에는 웹 화면의 예전 선택을 그대로 둔다.
    public var hasUnifiedChoice: Bool {
        if let account, account.override != nil || account.theme != nil { return true }
        return defaults.bool(forKey: Self.unifiedKey)
    }

    private func resolve(_ choice: HTTThemeSelection) -> HTTPaletteID {
        choice.palette ?? (systemIsDark ? .jarvis : .light)
    }

    public func registerCCMBLegacy(_ palette: HTTPaletteID?) {
        guard ccmbLegacy != palette else { return }
        ccmbLegacy = palette
        publish()
    }

    // MARK: - 사용자 선택

    /// 사용자가 테마를 직접 고른 경우에만 호출한다.
    public func select(_ choice: HTTThemeSelection) {
        if var account {
            writeSequence += 1
            account.override = choice
            self.account = account
            pendingWrite = choice.palette.map { PendingWrite(theme: $0, account: account.key, sequence: writeSequence) }
        } else {
            localChoice = choice
            defaults.set(choice.rawValue, forKey: Self.selectionKey)
            defaults.set(true, forKey: Self.unifiedKey)
        }
        publish()
        pump()
    }

    // MARK: - 계정 동기화

    public func attach(transport: HTTAccountThemeTransport) {
        self.transport = transport
        requestAccountRefresh()
    }

    public func requestAccountRefresh() {
        refreshRequested = true
        if transport == nil, let made = transportProvider?() { transport = made }
        pump()
    }

    /// 하나 문서가 바뀌기 시작했다. 이전 문서에서 보낸 요청의 결과는 버린다.
    public func accountDocumentWillChange() {
        documentEpoch += 1
    }

    private func pump() {
        guard !busy, let transport else { return }
        if let write = pendingWrite {
            pendingWrite = nil
            busy = true
            let epoch = documentEpoch
            Task { @MainActor [weak self] in
                let result = await transport.writeAccountTheme(write.theme, expectedAccount: write.account)
                guard let self else { return }
                self.busy = false
                self.finishWrite(result, write: write, epoch: epoch)
                self.pump()
            }
        } else if refreshRequested {
            refreshRequested = false
            busy = true
            let epoch = documentEpoch
            let sequence = writeSequence
            Task { @MainActor [weak self] in
                let result = await transport.readAccountTheme()
                guard let self else { return }
                self.busy = false
                self.finishRead(result, epoch: epoch, sequence: sequence)
                self.pump()
            }
        }
    }

    private func finishRead(_ result: HTTAccountThemeResult, epoch: Int, sequence: Int) {
        // 읽는 동안 문서가 바뀌었거나 사용자가 새로 골랐으면 옛 결과다.
        guard epoch == documentEpoch else { return }
        guard sequence == writeSequence else { refreshRequested = true; return }
        switch result {
        case let .signedIn(key, supportsTheme, theme):
            guard supportsTheme else {
                account = nil
                pendingWrite = nil
                status = .unsupported
                break
            }
            if var current = account, current.key == key {
                // 서버 값이 바뀌었으면 서버가 이긴다. 그대로면 이 Mac의 `auto` 선택만 유지한다.
                if current.theme != theme || current.override != .auto { current.override = nil }
                current.theme = theme
                account = current
            } else {
                account = Account(key: key, theme: theme, override: nil)
                pendingWrite = nil
            }
            status = .signedIn
        case .signedOut:
            account = nil
            pendingWrite = nil
            status = .signedOut
        case .accountChanged:
            account = nil
            pendingWrite = nil
            status = .unknown
            refreshRequested = true
        case .unavailable:
            status = .unavailable
        }
        publish()
    }

    private func finishWrite(_ result: HTTAccountThemeResult, write: PendingWrite, epoch: Int) {
        guard epoch == documentEpoch, write.sequence == writeSequence, account?.key == write.account else {
            refreshRequested = true
            return
        }
        switch result {
        case let .signedIn(key, true, theme) where key == write.account && theme == write.theme:
            account?.theme = theme
            account?.override = nil
            status = .signedIn
            publish()
            NotificationCenter.default.post(name: Self.accountThemeSavedNotification, object: self)
        case .signedOut:
            account = nil
            status = .signedOut
            publish()
        case .accountChanged:
            account = nil
            status = .unknown
            refreshRequested = true
            publish()
        case .signedIn, .unavailable:
            // 자동 재시도하지 않는다. 다음에 서버 값을 읽으면 계정 값으로 돌아간다.
            status = .saveFailed
            publish()
        }
    }

    // MARK: - 반영

    private func publish() {
        updateSnapshots()
        // 계정 정보 없이 상태와 팔레트 이름만 남긴다.
        let state = "status=\(String(describing: status)) palette=\(paletteID.rawValue) ccmb=\(ccmbPaletteID.rawValue)"
        if drivesSnapshot, state != lastLoggedState {
            lastLoggedState = state
            Self.logger.notice("\(state, privacy: .public)")
        }
        revision &+= 1
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func updateSnapshots() {
        guard drivesSnapshot else { return }
        HTTThemeSnapshot.app = paletteID.tokens
        HTTThemeSnapshot.ccmb = ccmbPaletteID.tokens
    }

    // MARK: - 시스템 외형

    private func currentSystemIsDark() -> Bool {
        if let systemIsDarkProvider { return systemIsDarkProvider() }
        guard let app = NSApp as NSApplication? else {
            return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }
        return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 앱은 `NSApp.appearance`를 바꾸지 않으므로 이 값은 시스템 설정을 따른다.
    public func observeSystemAppearance() {
        guard systemIsDarkProvider == nil, appearanceObservation == nil, let app = NSApp as NSApplication? else { return }
        appearanceObservation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshSystemAppearance() }
        }
        refreshSystemAppearance()
    }

    private func refreshSystemAppearance() {
        let dark = currentSystemIsDark()
        guard dark != systemIsDark else { return }
        systemIsDark = dark
        publish()
    }
}
