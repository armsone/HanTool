import SwiftUI
import ServiceManagement
import HTTHTDCore

// 앱 설정: AISettingsView를 scope별로 재사용한다.
// .browser: 네트워크 속도 표시 위치 + 브라우저 호출 단축키 (doubletap)
// .translation: Mail 연동 + 현재 페이지 외부 번역 전송 동의 + 외부 AI 옵션(계정/동의/세션/진단)
// .macManagement: 로그인 시 자동 시작 + 잠자기 해제 시 실행

public enum AISettingsScope: Hashable, Sendable {
    case browser
    case translation
    case macManagement
}

struct AISettingsView: View {
    var scope: AISettingsScope = .browser

    @State private var accounts = AIBIAccounts.shared
    @State private var webConsents = WebTranslatorConsentStore.shared
    @State private var webConsentRequest: WebTranslator?
    /// 현재 페이지 1회성 번역(Google·DeepL) 동의를 묻는 중인 서비스. 서비스마다 따로 묻고 따로 기억한다.
    @State private var pageConsentRequest: WebTranslator?
    @ObservedObject private var diagnostics = AIBIDiagnosticsStore.shared
    @ObservedObject private var networkRateDisplay = NetworkRateDisplayStore.shared
    @State private var mailButtonEnabled = MailToolbarButton.shared.isEnabled
    @State private var confirmClear = false
    @State private var loginItem = LoginItemManager()
    @State private var loginEnabled = false
    @State private var loginStatus = ""
    @State private var loginNeedsApproval = false
    @State private var wakeManager = WakeLaunchManager()
    @State private var wakeEnabled = true
    @State private var wakeStatus = ""
    @State private var wakeNeedsApproval = false
    @ObservedObject private var doubleTapShortcut = BrowserDoubleTapShortcut.shared

    var body: some View {
        Form {
            switch scope {
            case .browser:
                browserSections
            case .translation:
                translationSections
            case .macManagement:
                macManagementSections
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aibiHiddenSurface()
        .confirmationDialog("외부 AI·웹 번역 세션을 모두 지울까요?", isPresented: $confirmClear) {
            Button("모두 지우기", role: .destructive) {
                Task { await accounts.clearAllSessions() }
            }
        } message: {
            Text("ChatGPT·Claude·Gemini 모두 다시 로그인해야 합니다. 진행 중인 외부 AI 번역과 웹 번역(DeepL·Google 번역·Papago)이 모두 취소됩니다.")
        }
        .alert(webConsentRequest.map { "\($0.title) 전송에 동의할까요?" } ?? "",
               isPresented: Binding(get: { webConsentRequest != nil }, set: { if !$0 { webConsentRequest = nil } }),
               presenting: webConsentRequest) { translator in
            Button("동의") { webConsents.grant(translator) }
            Button("취소", role: .cancel) {}
        } message: { translator in
            Text(WebTranslatorConsentStore.message(for: translator))
        }
        .alert(pageConsentRequest.map { "\($0 == .deepl ? "DeepL로" : "Google 번역으로") 현재 페이지를 전송할까요?" } ?? "",
               isPresented: Binding(get: { pageConsentRequest != nil }, set: { if !$0 { pageConsentRequest = nil } }),
               presenting: pageConsentRequest) { translator in
            Button("동의") { webConsents.grant(translator) }
            Button("취소", role: .cancel) {}
        } message: { translator in
            Text(WebTranslatorConsentStore.pageMessage(for: translator))
        }
        .onAppear {
            switch scope {
            case .browser:
                doubleTapShortcut.updateAccessibilityStatus()
            case .translation:
                mailButtonEnabled = MailToolbarButton.shared.isEnabled
                if TranslationBackend.externalOptionsVisible { accounts.refreshAll() }
            case .macManagement:
                refreshLoginStatus()
                refreshWakeStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if scope == .macManagement {
                refreshWakeStatus()
            }
        }
    }

    // MARK: - .browser Sections

    @ViewBuilder
    private var browserSections: some View {
        Section {
            HStack {
                Text("네트워크 속도 표시 위치")
                Spacer()
                Picker("", selection: $networkRateDisplay.location) {
                    Text("한툴 상단").tag(NetworkRateDisplayLocation.appTop)
                    Text("macOS 메뉴 막대").tag(NetworkRateDisplayLocation.menuBar)
                }
                .pickerStyle(.menu)
                .frame(width: 170)
            }
        } header: {
            Text("네트워크 속도")
        } footer: {
            Text("실시간 네트워크 속도를 한툴 상단 또는 macOS 메뉴 막대에 표시합니다.")
        }

        Section {
            HStack {
                Text("두 번 누를 키")
                Spacer()
                Picker("", selection: $doubleTapShortcut.selectedModifier) {
                    ForEach(BrowserDoubleTapModifier.allCases) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 170)
            }

            if doubleTapShortcut.selectedModifier != .off && !doubleTapShortcut.isAccessibilityTrusted {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("다른 앱 실행 중 전역 키 감지에는 손쉬운 사용 권한이 필요합니다. 권한이 없으면 한툴 앱 외부에서의 두 번 누름이 동작하지 않을 수 있습니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("손쉬운 사용 권한 설정 열기…") {
                        InputMateCoordinator.shared.appState.requestAccessibilityAndRetry()
                        doubleTapShortcut.updateAccessibilityStatus()
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("브라우저 호출 단축키")
        } footer: {
            Text("기존 조합 단축키(⇧⌃⌥⌘B)는 그대로 유지되며, Command 키 또는 Shift 키를 짧게 두 번 눌러 HTD 브라우저를 빠르게 앞으로 가져올 수 있습니다. 원하는 경우 기본 설정을 변경할 수 있습니다.")
        }
    }

    // MARK: - .translation Sections

    @ViewBuilder
    private var translationSections: some View {
        Section {
            Toggle("Mail 위에 번역 버튼 표시", isOn: Binding(
                get: { mailButtonEnabled },
                set: { enabled in
                    if enabled { MailToolbarButton.shared.enable() } else { MailToolbarButton.shared.disable() }
                    mailButtonEnabled = MailToolbarButton.shared.isEnabled
                }
            ))
        } header: {
            Text("Mail 연동")
        } footer: {
            Text("Mail에서 선택한 메일을 번역하는 버튼입니다.")
        }

        Section {
            ForEach(WebTranslatorConsentStore.pageTranslators) { translator in
                HStack {
                    Text(translator.title).frame(width: 90, alignment: .leading)
                    Text(webConsents.hasConsent(translator) ? "동의함" : "아직 동의하지 않음")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if webConsents.hasConsent(translator) {
                        Button("동의 철회") { webConsents.revoke(translator) }
                    } else {
                        Button("동의…") { pageConsentRequest = translator }
                    }
                }
            }
        } header: {
            Text("현재 페이지 외부 번역 전송 동의")
        } footer: {
            Text("브라우저 확장의 '구글'·'DeepL' 버튼을 쓸 때만 필요하며, 서비스마다 따로 동의하고 철회합니다. 동의하면 그 버튼을 누른 탭의 현재 페이지 일반 글자와 이미지에서 이 Mac이 인식한 글자만 고른 서비스의 공식 웹페이지로 보냅니다. 스크린샷·이미지·페이지 HTML·주소는 이 Mac에만 남습니다. 동의해도 전역 자동 번역은 바뀌지 않으며, 다른 외부 AI에는 영향이 없습니다.")
        }

        if TranslationBackend.externalOptionsVisible {
            Section {
                ForEach(AIProvider.allCases) { provider in
                    HStack {
                        Text(provider.title).frame(width: 80, alignment: .leading)
                        statusLabel(accounts.statuses[provider])
                        Spacer()
                        Button(accounts.statuses[provider] == .authenticated ? "로그인 화면 열기" : "로그인…") {
                            accounts.openLogin(provider)
                        }
                        .disabled(accounts.isClearing)
                    }
                }
                HStack {
                    Spacer()
                    Button("상태 다시 확인") { accounts.refreshAll() }
                        .disabled(accounts.isClearing || accounts.statuses.values.contains(.checking))
                }
            } header: {
                Text("외부 AI 웹 계정")
            } footer: {
                Text("각 서비스에 직접 로그인하며, 비밀번호는 저장하지 않습니다.")
            }

            Section {
                Toggle("AI 브라우저 항상 보기", isOn: $accounts.alwaysShowBrowser)
            } header: {
                Text("표시 방식")
            } footer: {
                Text("켜면 번역 시작부터 브라우저를 표시합니다.")
            }

            Section {
                ForEach(AIProvider.allCases) { provider in
                    HStack {
                        Text(provider.title).frame(width: 80, alignment: .leading)
                        Text(accounts.hasConsent(provider) ? "동의함" : "아직 동의하지 않음")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("동의 철회") { accounts.revokeConsent(provider) }
                            .disabled(!accounts.hasConsent(provider))
                    }
                }
            } header: {
                Text("외부 AI 전송 동의")
            } footer: {
                Text("동의한 AI에 메일·화면의 글자만 전송합니다.")
            }

            Section {
                ForEach(WebTranslator.allCases) { translator in
                    HStack {
                        Text(translator.title).frame(width: 90, alignment: .leading)
                        Text(webConsents.hasConsent(translator) ? "동의함" : "아직 동의하지 않음")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if webConsents.hasConsent(translator) {
                            Button("동의 철회") { webConsents.revoke(translator) }
                        } else {
                            Button("동의…") { webConsentRequest = translator }
                        }
                    }
                }
            } header: {
                Text("웹 번역 전송 동의")
            } footer: {
                Text("선택하고 동의한 번역 서비스에 글자만 전송합니다.")
            }

            Section {
                Button("외부 AI·웹 번역 세션 모두 지우기…", role: .destructive) { confirmClear = true }
                    .disabled(accounts.isClearing)
            } header: {
                Text("세션")
            } footer: {
                Text("이 앱의 로그인 정보를 지우고 진행 중인 번역을 취소합니다.")
            }

            Section {
                if let url = diagnostics.exportURL {
                    ShareLink(item: url) { Label("최근 외부 AI 진단 로그 공유…", systemImage: "square.and.arrow.up") }
                } else {
                    Text("아직 기록된 외부 AI 실행이 없습니다.").foregroundStyle(.secondary)
                }
                if let error = diagnostics.storageError {
                    Text(error).foregroundStyle(.orange)
                }
            } header: {
                Text("진단")
            } footer: {
                Text("내용을 제외한 최근 10회 실행 정보를 기기에 보관합니다.")
            }
        }
    }

    // MARK: - .macManagement Sections

    @ViewBuilder
    private var macManagementSections: some View {
        Section {
            Toggle("로그인 시 자동 시작", isOn: Binding(
                get: { loginEnabled },
                set: { enabled in
                    loginItem.setEnabled(enabled)
                    refreshLoginStatus()
                }
            ))
            .disabled(!loginItem.isInstalledInApplications)
            if loginNeedsApproval {
                Button("로그인 항목 설정 열기") { loginItem.openSystemSettings() }
            }

            Toggle("잠자기에서 깨어나면 한툴 실행", isOn: Binding(
                get: { wakeEnabled },
                set: { enabled in
                    wakeManager.setEnabled(enabled)
                    refreshWakeStatus()
                }
            ))
            .disabled(!wakeManager.isInstalledInApplications)
            if wakeNeedsApproval {
                Button("로그인 항목 설정 열기") { wakeManager.openSystemSettings() }
            }
        } header: {
            Text("시작")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(loginStatus)
                Text("한툴이 꺼져 있을 때만 실행합니다. 이미 실행 중인 한툴은 그대로 둡니다. (\(wakeStatus))")
            }
        }
    }

    private func refreshLoginStatus() {
        loginEnabled = loginItem.status == .enabled || loginItem.status == .requiresApproval
        loginNeedsApproval = loginItem.status == .requiresApproval
        loginStatus = loginItem.lastError ?? loginItem.statusDescription
    }

    private func refreshWakeStatus() {
        wakeEnabled = wakeManager.isPreferenceEnabled
        wakeNeedsApproval = wakeManager.status == .requiresApproval
        wakeStatus = wakeManager.lastError ?? wakeManager.statusDescription
    }

    @ViewBuilder
    private func statusLabel(_ status: AIBILoginStatus?) -> some View {
        switch status {
        case .authenticated?:
            Label(AIBILoginStatus.authenticated.label, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .loginRequired?:
            Label(AIBILoginStatus.loginRequired.label, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .checking?:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(AIBILoginStatus.checking.label) }.foregroundStyle(.secondary)
        case .unknown?, nil:
            Label(AIBILoginStatus.unknown.label, systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}
