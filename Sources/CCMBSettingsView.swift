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
                    sshTargetSection
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
                    Text("놀이터 서버 (SSH)").tag(CCMBIntegration.sourceNAS)
                    Text("이 Mac (로컬 수집)").tag(CCMBIntegration.sourceLocalMac)
                }
                .pickerStyle(.segmented)

                Text(integration.dataSource == CCMBIntegration.sourceNAS
                     ? "원격 놀이터 NAS의 SSH 연결을 통해 AI 사용량·작업 상태를 수집합니다 (기본값)."
                     : "현재 실행 중인 로컬 Mac의 자원을 직접 수집합니다 (명시적으로 선택한 경우에만 수집).")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
            .padding(16)
            .background(palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - SSH 대상 서버 설정

    private var sshTargetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH 대상 서버 설정")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SSH 호스트 별칭 또는 주소")
                        .font(.subheadline.weight(.medium))
                    Text("~/.ssh/config에 정의된 호스트 별칭(예: my-server) 또는 호스트명/IP(예: nas.example.com)를 입력하세요. HTTP/HTTPS 웹 주소 단독으로는 동작하지 않으며, SSH 인증(키 기반)이 미리 구성되어 있어야 합니다.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }

                HStack(spacing: 8) {
                    TextField("호스트명 또는 SSH 별칭 (예: my-server)", text: $integration.targetDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)

                    Button("적용") {
                        integration.applyTargetDraft()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplyDisabled)
                }

                if case .invalid(let message) = targetValidation {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                } else if integration.targetDraft.isEmpty {
                    Text("대상이 비어 있으면 아무런 SSH 연결도 시도하지 않는 안전한 미설정 상태가 유지됩니다.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                } else if integration.targetDraft != integration.serverTarget {
                    Text("수정된 대상이 아직 적용되지 않았습니다. '적용' 버튼을 눌러주세요.")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                } else {
                    Text("현재 적용된 대상: \(integration.serverTarget)")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
            }
            .padding(16)
            .background(palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
