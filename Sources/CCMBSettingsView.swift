import SwiftUI
import HTTCCMB

/// HTT 설정 창 내의 '서버 현황' 설정 화면.
/// - CCMB 원본 대시보드(팝업, 그래프, 카드, 옵션)를 재그리지 않고 모듈 런타임의 `showDashboard()`를 통해 원본 그대로 엽니다.
/// - 기능 활성화 토글, 메뉴 막대 요약 표시 토글, 데이터 소스 선택(놀이터 서버 / 이 Mac), SSH 대상 서버 설정(초안 및 적용)을 제공합니다.
public struct CCMBSettingsView: View {
    @ObservedObject private var integration = CCMBIntegration.shared
    @ObservedObject private var appearance = HTTAppearanceStore.shared
    @Environment(\.colorScheme) private var systemColorScheme

    public init() {}

    private var palette: HTTThemePalette {
        appearance.palette(for: systemColorScheme)
    }

    private var targetValidation: CCMBIntegration.TargetValidationResult {
        CCMBIntegration.validateTarget(integration.targetDraft)
    }

    private var isApplyDisabled: Bool {
        !targetValidation.isValid || integration.targetDraft == integration.serverTarget
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerView
                statusBannerView
                featureTogglesSection
                dataSourceSection
                if integration.dataSource == CCMBIntegration.sourceNAS {
                    playgroundTargetSection
                }
                lifecycleProtectionNote
            }
            .padding(24)
        }
        .background(palette.bg)
    }

    // MARK: - 상단 헤더

    private var headerView: some View {
        HStack(spacing: 12) {
            HTTIconView(id: "device_files", size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("서버 현황")
                    .font(.title2.weight(.bold))
                Text("놀이터 서버나 이 Mac의 AI 사용량과 남은 한도를 확인합니다.")
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
            }
            Spacer()
        }
    }

    // MARK: - 현재 상태 및 대시보드 진입 배너

    private var statusBannerView: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: integration.isEnabled ? "server.rack" : "pause.circle")
                .font(.system(size: 24))
                .foregroundStyle(integration.isEnabled ? Color.accentColor : palette.muted)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(integration.statusSummary)
                        .font(.headline)
                    if integration.isEnabled {
                        Text(integration.isRunning ? "기능 켜짐" : "기능 꺼짐")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(integration.isRunning ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                            .foregroundStyle(integration.isRunning ? Color.green : Color.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(integration.statusDescription)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }

            Spacer()

            Button {
                integration.showDashboard()
            } label: {
                Label("대시보드 패널 열기", systemImage: "macwindow.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!integration.isEnabled)
            .help("서버 현황 모니터링 창을 엽니다. 메뉴 막대 아이콘이 숨겨져 있어도 열 수 있습니다.")
        }
        .padding(16)
        .background(palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 기능 활성화 및 메뉴 막대 토글

    private var featureTogglesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("기능 제어")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { integration.isEnabled },
                    set: { integration.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("서버 현황 모니터링 켜기")
                            .font(.body.weight(.medium))
                        Text("백그라운드에서 주기적으로 서버 상태를 수집합니다. 끄면 모든 수집 및 관련 창이 종료됩니다.")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                }
                .toggleStyle(.checkbox)

                Divider()

                Toggle(isOn: Binding(
                    get: { integration.showMenuBar },
                    set: { integration.setShowMenuBar($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("메뉴 막대에 상태 아이콘 표시")
                            .font(.body.weight(.medium))
                        Text("macOS 메뉴 막대에 AI 사용량·남은 한도 요약 아이콘을 표시합니다. 끄더라도 모니터링은 유지되며 위 버튼으로 대시보드를 열 수 있습니다.")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(16)
            .background(palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - 수집 대상 (데이터 소스)

    private var dataSourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("수집 대상 (데이터 소스)")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Picker("데이터 소스", selection: Binding(
                    get: { integration.dataSource },
                    set: { integration.setDataSource($0) }
                )) {
                    Text("놀이터 서버").tag(CCMBIntegration.sourceNAS)
                    Text("이 Mac (로컬 수집)").tag(CCMBIntegration.sourceLocalMac)
                }
                .pickerStyle(.segmented)

                Text(integration.dataSource == CCMBIntegration.sourceNAS
                     ? "놀이터 서버의 웹 연결을 통해 AI 사용량과 작업 상태를 수집합니다 (기본값)."
                     : "현재 실행 중인 로컬 Mac의 지원 항목을 직접 수집합니다. Gemini·Grok은 별도 CLI 설치 없이 앱 내 제공사 화면에서 확인할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
            .padding(16)
            .background(palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - 놀이터 서버 설정

    private var playgroundTargetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("놀이터 서버 설정")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("놀이터 주소")
                        .font(.subheadline.weight(.medium))
                    Text("놀이터 서버의 HTTPS 웹 주소(예: https://nas.example.com:8443)를 입력하세요. SSH 설정이나 터미널 명령어 구성 없이 바로 연결됩니다.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }

                HStack(spacing: 8) {
                    TextField("https://nas.example.com:8443 또는 https://host/alfred", text: $integration.targetDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)

                    Button("적용") {
                        integration.applyTargetDraft()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplyDisabled)
                }

                HStack(spacing: 8) {
                    Button("연결 확인") {
                        integration.checkConnection()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!targetValidation.isValid)

                    Button("로그인") {
                        integration.openLoginWindow()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!targetValidation.isValid)

                    Spacer()
                }

                connectionStatusView

                if case .invalid(let message) = targetValidation {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                } else if integration.targetDraft.isEmpty {
                    Text("주소가 비어 있으면 연결을 시도하지 않는 안전한 미설정 상태가 유지됩니다.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                } else if integration.targetDraft != integration.serverTarget {
                    Text("수정된 주소가 아직 적용되지 않았습니다. '적용' 버튼을 눌러주세요.")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                } else {
                    Text("현재 적용된 주소: \(integration.serverTarget)")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
            }
            .padding(16)
            .background(palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch integration.connectionState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("놀이터 서버 연결 확인 중...")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
        case .connected(let authenticated, let role):
            HStack(spacing: 6) {
                Image(systemName: authenticated ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(authenticated ? Color.green : Color.orange)
                if authenticated {
                    let roleSuffix = role.map { " (역할: \($0))" } ?? ""
                    Text("연결 성공 · 로그인 완료\(roleSuffix)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.green)
                } else {
                    Text("연결 성공 · 로그인이 필요합니다. '로그인' 버튼을 눌러 로그인해 주세요.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.orange)
                }
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.red)
                Text("연결 실패: \(message)")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }

    // MARK: - 수명주기 보호 안내

    private var lifecycleProtectionNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title3)
                .foregroundStyle(palette.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text("서버 현황 창 동작 안내")
                    .font(.subheadline.weight(.medium))
                Text("서버 현황 창의 종료·다시 시작은 이 기능만 제어하며, HTT 앱과 플래너 작업은 중단 없이 계속 실행됩니다.")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
            Spacer()
        }
        .padding(14)
        .background(palette.card.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
