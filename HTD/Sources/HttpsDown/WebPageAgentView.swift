import Foundation
import SwiftUI
import AppKit
import WebKit

// MARK: - Planner WebView NSViewRepresentable Container

struct WebPageAgentPlannerWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    var nativeInputAllowed: () -> Bool = { true }

    init(webView: WKWebView, nativeInputAllowed: @escaping () -> Bool = { true }) {
        self.webView = webView
        self.nativeInputAllowed = nativeInputAllowed
    }

    func makeNSView(context: Context) -> LoginWebViewRepresentable.Container {
        let container = LoginWebViewRepresentable.Container()
        container.nativeInputAllowed = nativeInputAllowed
        container.attach(webView)
        return container
    }

    func updateNSView(_ nsView: LoginWebViewRepresentable.Container, context: Context) {
        nsView.nativeInputAllowed = nativeInputAllowed
        nsView.attach(webView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LoginWebViewRepresentable.Container, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
    }
}

// MARK: - Work Mode Top Planner Panel View

struct WebPageAgentPlannerPanelView: View {
    @ObservedObject var coordinator: WebPageAgentCoordinator
    @ObservedObject var appModel: AppModel
    let availableWidth: CGFloat
    let onClose: () -> Void
    @Environment(\.bkPalette) private var palette

    private var activeService: AIService {
        appModel.aiServices.selectedService
    }

    init(coordinator: WebPageAgentCoordinator, appModel: AppModel, availableWidth: CGFloat, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.appModel = appModel
        self.availableWidth = availableWidth
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundColor(palette.accentColor)
                    .font(.caption)

                Text("\(activeService.name) 자율 작업 플래너")
                    .font(.caption.bold())
                    .foregroundColor(palette.textColor)
                    .lineLimit(1)

                Spacer()

                Button(action: {
                    coordinator.transport.plannerWebView?.reload()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("플래너 대화창 새로고침")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("패널 닫기")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(palette.surface2Color)

            Divider()

            if let plannerWV = coordinator.transport.plannerWebView {
                WebPageAgentPlannerWebViewRepresentable(webView: plannerWV, nativeInputAllowed: {
                    appModel.selectedTab == .browser
                })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 32))
                        .foregroundColor(palette.accentColor)

                    Text("AI 플래너 대화창 준비 중...")
                        .font(.caption)
                        .foregroundColor(palette.textColor)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bgColor)
            }
        }
        .background(palette.cardColor)
    }
}

// MARK: - Work Mode Bottom Composer Control View

struct WebPageAgentWorkControlView: View {
    @ObservedObject var coordinator: WebPageAgentCoordinator
    @ObservedObject var tabModel: LoginBrowserModel
    @ObservedObject var appModel: AppModel
    let panelWidth: CGFloat
    @Environment(\.bkPalette) private var palette

    init(coordinator: WebPageAgentCoordinator, tabModel: LoginBrowserModel, appModel: AppModel, panelWidth: CGFloat) {
        self.coordinator = coordinator
        self.tabModel = tabModel
        self.appModel = appModel
        self.panelWidth = panelWidth
    }

    var body: some View {
        VStack(spacing: 6) {
            // Target page info chip
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.caption2)
                    .foregroundColor(palette.accentColor)

                Text(tabModel.pageTitle.isEmpty ? (tabModel.currentURL?.host ?? "웹 페이지") : tabModel.pageTitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)

                Spacer()

                if coordinator.isBusy {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("단계 \(coordinator.currentStep)/\(coordinator.maxSteps)")
                            .font(.caption2)
                            .foregroundColor(palette.textColor.opacity(0.8))
                    }
                } else if coordinator.currentStep > 0 {
                    Text("단계 \(coordinator.currentStep)/\(coordinator.maxSteps)")
                        .font(.caption2)
                        .foregroundColor(palette.textColor.opacity(0.6))
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            // Goal Input Field
            HStack(spacing: 6) {
                TextField("수행할 작업을 입력하세요 (예: 최신 글 클릭, 목록 요약)", text: $coordinator.userGoal)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(coordinator.isBusy)
                    .onSubmit {
                        guard !coordinator.isBusy && !coordinator.userGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        coordinator.start(tab: tabModel, appModel: appModel, goal: coordinator.userGoal)
                    }

                // Control Action Buttons
                if coordinator.isBusy {
                    Button("직접 조작") {
                        coordinator.takeoverManual()
                    }
                    .font(.caption2.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("AI 작업을 일시 정지하고 브라우저를 직접 조작합니다")

                    Button("중단") {
                        coordinator.stop()
                    }
                    .font(.caption2.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(palette.dangerColor)
                    .controlSize(.small)
                    .help("진행 중인 AI 작업을 즉시 중단합니다")
                } else if coordinator.mode == .userControl || coordinator.mode == .stopped {
                    Button("다시 맡기기") {
                        coordinator.resume(tab: tabModel, appModel: appModel)
                    }
                    .font(.caption2.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accentColor)
                    .controlSize(.small)
                    .help("현재 변경된 화면을 기준으로 작업을 계속 진행합니다")

                    Button("중단") {
                        coordinator.stop()
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if coordinator.mode == .needsUser {
                    Button("직접 조작") {
                        coordinator.takeoverManual()
                    }
                    .font(.caption2.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("중단") {
                        coordinator.stop()
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("작업 시작") {
                        coordinator.start(tab: tabModel, appModel: appModel, goal: coordinator.userGoal)
                    }
                    .font(.caption2.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accentColor)
                    .controlSize(.small)
                    .disabled(coordinator.userGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tabModel.isShowingHome || tabModel.currentURL == nil)
                }
            }
            .padding(.horizontal, 8)

            // External Effect Gate Approval Banner
            if let pending = coordinator.pendingApproval {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(palette.warnColor)
                            .font(.caption2)

                        Text("외부 실행 승인 필요: [\(pending.targetElement?.name ?? pending.action.ref ?? "동작")]")
                            .font(.caption2.bold())
                            .foregroundColor(palette.textColor)
                            .lineLimit(1)
                    }

                    Text(pending.reason)
                        .font(.caption2)
                        .foregroundColor(palette.textColor.opacity(0.8))
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Button("취소") {
                            coordinator.cancelPendingGate()
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        Button("승인하여 계속") {
                            coordinator.approvePendingGate(tab: tabModel, appModel: appModel)
                        }
                        .font(.caption2.bold())
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accentColor)
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.warnSoftColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.warnColor.opacity(0.4), lineWidth: 1))
                .padding(.horizontal, 8)
            }

            // Status message strip
            HStack(spacing: 6) {
                Image(systemName: statusIconName)
                    .font(.caption2)
                    .foregroundColor(statusIconColor)

                Text(coordinator.statusMessage)
                    .font(.caption2)
                    .foregroundColor(palette.textColor)
                    .lineLimit(1)

                Spacer()

                if let resultText = coordinator.lastCompletedResult, coordinator.mode == .completed {
                    Button("결과 복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resultText, forType: .string)
                    }
                    .font(.caption2.bold())
                    .buttonStyle(.plain)
                    .foregroundColor(palette.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusBackgroundColor)

            // Security transparency notice
            Text("현재 페이지의 구조와 텍스트 정보가 선택된 AI 서비스에 전송됩니다.")
                .font(.system(size: 9))
                .foregroundColor(palette.textColor.opacity(0.5))
                .lineLimit(1)
                .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity)
        .background(palette.cardColor)
    }

    private var statusIconName: String {
        switch coordinator.mode {
        case .idle: return "info.circle"
        case .reading: return "eye.fill"
        case .thinking: return "brain.head.profile"
        case .acting: return "cursorarrow.click.2"
        case .needsUser: return "person.fill.questionmark"
        case .userControl: return "hand.raised.fill"
        case .stopped: return "stop.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusIconColor: Color {
        switch coordinator.mode {
        case .idle, .reading, .thinking: return palette.accentColor
        case .acting: return palette.accentColor
        case .needsUser: return palette.warnColor
        case .userControl: return palette.warnColor
        case .stopped: return palette.textColor.opacity(0.6)
        case .completed: return palette.accentColor
        case .error: return palette.dangerColor
        }
    }

    private var statusBackgroundColor: Color {
        switch coordinator.mode {
        case .error: return palette.dangerSoftColor
        case .needsUser, .userControl: return palette.warnSoftColor
        default: return palette.accentSoftColor
        }
    }
}
