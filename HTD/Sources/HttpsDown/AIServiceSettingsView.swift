import SwiftUI
import AppKit

/// Settings page for selecting preferred AI service, managing custom services,
/// and learning about official site sign-in, session persistence, and service capabilities.
public struct AIServiceSettingsView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var aiStore: AIServiceStore
    @ObservedObject var loginStatusStore = AILoginStatusStore.shared
    @ObservedObject private var hanaPanelHost = HanaPanelHost.shared
    @Environment(\.bkPalette) private var palette

    @State private var showingAddSheet = false
    @State private var servicePendingDelete: AIService? = nil
    @State private var hasRefreshedProbe = false

    public init(appModel: AppModel) {
        self.appModel = appModel
        self.aiStore = appModel.aiServices
    }

    private var selectedService: AIService {
        aiStore.selectedService
    }

    private var hasAnyEnabled: Bool {
        !aiStore.enabledServices.isEmpty
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerOverviewSection

                selectedServiceBanner

                curatedServicesSection

                customServicesSection

                SAWTeamSettingsSection(workspace: appModel.sawWorkspace)

                explanationFooterSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.bgColor)
        .background(AILoginProbeSurfaceView().frame(width: 800, height: 680))
        .sheet(isPresented: $showingAddSheet) {
            AddCustomAIServiceSheet(store: aiStore) {
                showingAddSheet = false
            }
            .byungkiThemed(palette)
        }
        .confirmationDialog(
            "‘\(servicePendingDelete?.name ?? "")’ 서비스를 목록에서 삭제할까요?",
            isPresented: Binding(get: { servicePendingDelete != nil }, set: { if !$0 { servicePendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: servicePendingDelete
        ) { target in
            Button("삭제", role: .destructive) {
                aiStore.removeCustomService(id: target.id)
                servicePendingDelete = nil
            }
            Button("취소", role: .cancel) {
                servicePendingDelete = nil
            }
        } message: { target in
            if target.id == aiStore.selectedServiceID {
                Text("이 서비스는 현재 기본 AI로 선택되어 있습니다. 삭제하면 기본 AI가 ‘하나(Hana)’로 안전하게 재설정됩니다. 브라우저 로그인 세션이나 대화 내역은 삭제되지 않습니다.")
            } else {
                Text("목록에서 서비스 설정만 삭제되며, 브라우저에 저장된 로그인 데이터나 대화 내역은 삭제되지 않습니다.")
            }
        }
        .onChange(of: aiStore.enabledServiceIDs) { newIDs in
            if newIDs.isEmpty {
                appModel.setAIPanelOpen(false)
            }
        }
        .onChange(of: hanaPanelHost.isBridgeReady) { _ in
            if let hana = aiStore.allServices.first(where: { $0.isHana }) {
                loginStatusStore.checkStatus(for: hana, store: appModel.store(for: hana))
            }
        }
        .task {
            guard !hasRefreshedProbe else { return }
            hasRefreshedProbe = true
            await Task.yield()
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let supportedIDs = ["chatgpt", "claude", "gemini", "grok", "hana", "perplexity"]
            for service in aiStore.allServices where supportedIDs.contains(service.id) {
                guard !Task.isCancelled else { break }
                loginStatusStore.checkStatus(for: service, store: appModel.store(for: service))
            }
        }
    }

    // MARK: - Header & Overview

    private var headerOverviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundColor(palette.accentColor)
                Text("AI 서비스 선택")
                    .font(.title2.bold())
                    .foregroundColor(palette.textColor)
            }
            Text("브라우저 상단 ‘AI’ 스위치를 켤 때 열리는 기본 AI 대화창 서비스를 선택합니다. 제목 ‘AI’를 클릭하면 켜져 있는 서비스만 빠른 선택 메뉴에 표시되며, 각 행의 ‘사용’ 스위치로 메뉴 표시 여부를 지정할 수 있습니다 (스위치 상태는 로그인 여부와 무관한 메뉴 표시 설정입니다).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Selected Service Banner

    private var selectedServiceBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("현재 선택된 기본 AI")
                    .font(.caption.bold())
                    .foregroundColor(palette.accentColor)
                Spacer()
                if hasAnyEnabled {
                    Text("상단 AI 스위치로 바로 열림")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("사용 안 함 (모든 AI 꺼짐)")
                        .font(.caption2.bold())
                        .foregroundColor(palette.warnColor)
                }
            }

            if hasAnyEnabled {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(selectedService.name)
                                .font(.headline)
                                .foregroundColor(palette.textColor)
                            if !selectedService.isHana {
                                Text("수동 웹 대화")
                                    .font(.caption2)
                                    .foregroundColor(palette.textColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(palette.surface2Color))
                            }
                        }
                        Text(selectedService.serviceDescription)
                            .font(.caption)
                            .foregroundColor(palette.textColor.opacity(0.8))
                        if !selectedService.isHana && !selectedService.restrictions.isEmpty {
                            Text("특징 및 제한: \(selectedService.restrictions)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button("대화창 열기") {
                            appModel.selectedTab = .browser
                            appModel.setAIPanelOpen(true)
                        }
                        .buttonStyle(.bkProminent)
                        .controlSize(.small)

                        Button("로그인 / 계정 열기") {
                            loginStatusStore.openLoginWindow(for: selectedService, store: appModel.store(for: selectedService))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("사용 안 함")
                            .font(.headline)
                            .foregroundColor(palette.textColor)
                        Text("켜져 있는 AI 서비스가 없습니다. 아래 목록에서 사용할 AI 서비스의 ‘사용’ 스위치를 켜 주세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.cardColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(hasAnyEnabled ? palette.accentColor.opacity(0.6) : palette.borderColor, lineWidth: 1.5))
    }

    // MARK: - Curated Services Section

    private var curatedServicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("공식 추천 AI 서비스 (\(aiStore.curatedServices.count)개)")
                .font(.headline)
                .foregroundColor(palette.textColor)
            Text("주요 공식 AI 대화 서비스 목록입니다. 로그인·계정 창과 사이드 대화창이 로그인 상태를 공유하므로 로그인 세션이 안전하게 유지됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(aiStore.curatedServices) { service in
                    serviceRow(service)
                }
            }
        }
    }

    // MARK: - Custom Services Section

    private var customServicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("사용자 지정 AI 서비스")
                        .font(.headline)
                        .foregroundColor(palette.textColor)
                    Text("직접 사용하는 안전한 HTTPS 웹 AI 서비스 주소를 등록해 기본 AI로 지정할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Label("AI 서비스 추가", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if aiStore.customServices.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "tray")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        Text("등록된 사용자 지정 AI 서비스가 없습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.surfaceColor))
            } else {
                VStack(spacing: 8) {
                    ForEach(aiStore.customServices) { service in
                        serviceRow(service)
                    }
                }
            }
        }
    }

    // MARK: - Service Row

    private func serviceRow(_ service: AIService) -> some View {
        let isSelected = service.id == aiStore.selectedServiceID
        let status = loginStatusStore.status(for: service.id)
        let serviceStore = appModel.store(for: service)

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(service.name)
                        .font(.subheadline.bold())
                        .foregroundColor(palette.textColor)

                    if isSelected && hasAnyEnabled {
                        Text("✓ 현재 기본")
                            .font(.caption2.bold())
                            .foregroundColor(palette.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.accentSoftColor))
                    }

                    // Honest Login Status Badge
                    statusBadge(status)
                }

                Text(service.serviceDescription)
                    .font(.caption)
                    .foregroundColor(palette.textColor.opacity(0.8))

                if !service.isHana {
                    Text("\(service.homeURL)\(service.restrictions.isEmpty ? "" : " · " + service.restrictions)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Toggle("사용", isOn: Binding(
                    get: { aiStore.isServiceEnabled(id: service.id) },
                    set: { aiStore.setServiceEnabled(id: service.id, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
                .help("상단 AI 스위치의 빠른 선택 메뉴에 표시합니다 (스위치 상태는 로그인 여부와 무관한 메뉴 표시 설정입니다).")

                if isSelected && hasAnyEnabled {
                    Text("선택됨")
                        .font(.caption)
                        .foregroundColor(palette.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else {
                    Button("기본 AI로 선택") {
                        aiStore.selectService(id: service.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button("상태 확인") {
                    loginStatusStore.checkStatus(for: service, store: serviceStore)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(status == .checking)
                .help("현재 AI 웹 세션의 로그인 상태를 직접 안전하게 확인합니다.")

                Button("로그인 / 계정 열기") {
                    loginStatusStore.openLoginWindow(for: service, store: serviceStore)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("AI 대화창과 동일한 전용 웹 세션 창에서 공식 로그인을 진행합니다. 로그인 완료 시 자동으로 인식됩니다.")

                if !service.isCurated {
                    Button(role: .destructive) {
                        servicePendingDelete = service
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(palette.dangerColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .help("사용자 지정 서비스 삭제")
                    .accessibilityLabel("‘\(service.name)’ 서비스 삭제")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((isSelected && hasAnyEnabled) ? palette.accentSoftColor.opacity(0.4) : palette.surfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((isSelected && hasAnyEnabled) ? palette.accentColor : palette.borderColor, lineWidth: 1)
        )
    }

    private func statusBadge(_ status: AILoginStatus) -> some View {
        HStack(spacing: 3) {
            switch status {
            case .checking:
                ProgressView().controlSize(.mini)
                Text(status.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(palette.textColor)
            case .loggedIn, .connected:
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(status.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.green)
            case .notLoggedIn:
                Circle().fill(palette.textColor.opacity(0.4)).frame(width: 6, height: 6)
                Text(status.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(palette.textColor.opacity(0.7))
            case .unknown:
                Circle().fill(palette.textColor.opacity(0.2)).frame(width: 6, height: 6)
                Text(status.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(palette.textColor.opacity(0.6))
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(palette.surface2Color))
    }

    // MARK: - Explanation Footer

    private var explanationFooterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("안내 및 보안 원칙")
                .font(.caption.bold())
                .foregroundColor(palette.textColor)
            Text("• 로그인 세션 일관성: 모든 서드파티 AI 서비스는 로그인·계정 창과 사이드 대화창이 로그인 상태를 공유하여 세션이 항상 일치합니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("• 공식 로그인 보안: Google, Apple, Microsoft 등 계정 로그인은 공식 사이트의 안전한 팝업 창을 통해 직접 이루어지며, 앱은 로그인 비밀번호를 수집하거나 가로채지 않습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("• 빠른 선택 메뉴 표시: 각 서비스의 ‘사용’ 스위치 설정은 상단 ‘AI’ 메뉴를 클릭했을 때 빠른 선택 목록에 표시할 항목을 정하는 것이며, 실제 로그인 여부를 나타내거나 변경하지 않습니다. 필요한 AI만 선택하여 켜 둘 수 있습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("• 사용자 주소창 보호: 서드파티 AI가 선택되어 있어도 ‘하나 [질문]’ 형식의 명령은 기존 전용 하나 창으로 바르게 연결되어 의도치 않은 서비스 오전송을 방지합니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("• 서비스 가용성 및 로그인 유의사항: 각 AI 서비스의 지역별 제공 여부, 계정 정책 및 로그인 지원 상태는 서비스 제공사의 정책에 따라 다를 수 있으며, 모든 외부 서비스의 로그인 또는 이용을 보증하지 않습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("• 지원 범위: 주요 공식 AI 대화 서비스 외에 필요한 다른 안전한 대화형 웹 AI는 상단의 ‘AI 서비스 추가’를 통해 직접 HTTPS 주소를 등록하여 이용할 수 있습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.cardColor))
    }
}

// MARK: - Add Custom Service Sheet

struct AddCustomAIServiceSheet: View {
    @ObservedObject var store: AIServiceStore
    let onClose: () -> Void
    @Environment(\.bkPalette) private var palette

    @State private var name: String = ""
    @State private var urlString: String = "https://"
    @State private var desc: String = ""
    @State private var errorMessage: String? = nil

    private var validationProblem: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if case .failure(let err) = AIServiceStore.validateCustom(name: name, urlString: urlString, existing: store.allServices) {
            return err.errorDescription ?? err.localizedDescription
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("사용자 지정 AI 서비스 추가")
                .font(.headline)
                .foregroundColor(palette.textColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("서비스 이름")
                    .font(.caption.bold())
                    .foregroundColor(palette.textColor)
                TextField("예: 네이버 클로바X", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("웹 주소 (HTTPS)")
                    .font(.caption.bold())
                    .foregroundColor(palette.textColor)
                TextField("https://...", text: $urlString)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("간단 설명 (선택)")
                    .font(.caption.bold())
                    .foregroundColor(palette.textColor)
                TextField("예: 개인 사용 웹 챗봇", text: $desc)
                    .textFieldStyle(.roundedBorder)
            }

            if let err = errorMessage ?? validationProblem {
                Text(err)
                    .font(.caption)
                    .foregroundColor(palette.dangerColor)
            }

            HStack {
                Spacer()
                Button("취소") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button("등록") {
                    save()
                }
                .buttonStyle(.bkProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validationProblem != nil)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 420)
        .background(palette.cardColor)
    }

    private func save() {
        if let err = store.addCustomService(name: name, urlString: urlString, description: desc) {
            errorMessage = err
        } else {
            onClose()
        }
    }
}
