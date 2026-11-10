import Foundation
import SwiftUI
import AppKit
import WebKit

// MARK: - Preference Keys for Viewport Bottom Tracking

private struct ChatBottomOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Shared Helpers for Status & Formatting

func sawStatusKorean(_ status: String) -> String {
    switch status {
    case "running": return "진행 중"
    case "userControl": return "직접 조작 중"
    case "paused": return "일시 중단"
    case "completed": return "완료됨"
    case "failed": return "실패"
    case "interrupted": return "중단됨"
    case "skipped": return "건너뜀"
    default: return "대기 중"
    }
}

func sawStatusColor(_ status: String, palette: Palette) -> Color {
    switch status {
    case "running": return palette.accentColor
    case "userControl", "paused": return palette.warnColor
    case "completed": return palette.accentColor
    case "failed", "interrupted": return palette.dangerColor
    case "skipped": return palette.warnColor
    default: return palette.textColor.opacity(0.6)
    }
}

private func sawStatusBackgroundColor(_ status: String, palette: Palette) -> Color {
    switch status {
    case "running": return palette.accentSoftColor
    case "userControl", "paused": return palette.warnSoftColor
    case "completed": return palette.accentSoftColor
    case "failed", "interrupted": return palette.dangerSoftColor
    case "skipped": return palette.warnSoftColor
    default: return palette.surface2Color
    }
}

private func sawStatusIconName(_ status: String) -> String {
    switch status {
    case "running": return "arrow.triangle.2.circlepath"
    case "userControl": return "hand.raised.fill"
    case "paused": return "pause.circle.fill"
    case "completed": return "checkmark.circle.fill"
    case "failed": return "exclamationmark.triangle.fill"
    case "interrupted": return "stop.circle.fill"
    case "skipped": return "clock.badge.xmark"
    default: return "clock"
    }
}

private func sawFormatDate(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
    var cal = Calendar.autoupdatingCurrent
    cal.timeZone = timeZone
    cal.locale = Locale(identifier: "ko_KR")
    let now = Date()
    let startOfTarget = cal.startOfDay(for: date)
    let startOfNow = cal.startOfDay(for: now)
    let dayDiff = cal.dateComponents([.day], from: startOfNow, to: startOfTarget).day ?? 0

    let timeF = DateFormatter()
    timeF.calendar = cal
    timeF.timeZone = timeZone
    timeF.locale = Locale(identifier: "ko_KR")
    timeF.dateFormat = "HH:mm"
    let timeStr = timeF.string(from: date)

    if dayDiff == 0 {
        return timeStr
    } else if dayDiff == 1 {
        return "내일 \(timeStr)"
    } else if dayDiff == 2 {
        return "모레 \(timeStr)"
    } else {
        let otherF = DateFormatter()
        otherF.calendar = cal
        otherF.timeZone = timeZone
        otherF.locale = Locale(identifier: "ko_KR")
        otherF.dateFormat = "MM/dd(EEE) HH:mm"
        return otherF.string(from: date)
    }
}

func sawDisplayProjectTitle(_ project: SAWProject) -> String {
    let raw = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstGoalLine: String = {
        for line in project.goal.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }()
    let isAutoTitle = raw.isEmpty || raw == "새 프로젝트" || raw == project.goal.trimmingCharacters(in: .whitespacesAndNewlines) || raw == firstGoalLine
    guard isAutoTitle else {
        return project.title
    }
    let g = project.goal
    if g.contains("제이블랙") { return "제이블랙 조사" }
    if g.contains("인스타그램") && (g.contains("댓글") || g.contains("DM") || g.contains("친구") || g.contains("팔로우") || g.contains("좋아요")) {
        return "인스타그램 관계 관리"
    }
    if g.contains("중요") && g.contains("메일") {
        return "중요 메일 확인"
    }
    if !firstGoalLine.isEmpty {
        return firstGoalLine.count > 28 ? String(firstGoalLine.prefix(28)) + "..." : firstGoalLine
    }
    return raw.isEmpty ? "새 프로젝트" : project.title
}

/// Local list/tooltip/accessibility prefix for explicitly designated test projects only. Kept out of
/// sawDisplayProjectTitle so report titles and other shared displays stay unchanged.
func sawTestProjectPrefix(_ project: SAWProject) -> String {
    project.isTestProject ? "테스트 프로젝트 · " : ""
}

@MainActor
private func sawNeedsConfirmation(_ session: SAWProjectSession) -> Bool {
    guard session.runStatus == "userControl" else { return false }
    let trimmed = session.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("사용자 직접 조작") {
        return false
    }
    if trimmed.hasPrefix("사용자 확인 필요:") {
        return true
    }
    let lower = trimmed.lowercased()
    if lower.contains("로그인") || lower.contains("인증") {
        return true
    }
    if lower.contains("실패") || lower.contains("오류") || lower.contains("준비하지못") || lower.contains("준비하지 못") {
        return true
    }
    return false
}

@MainActor
func meaningfulSummary(session: SAWProjectSession?, project: SAWProject) -> String {
    func cleanFirstLine(_ text: String, maxLength: Int) -> String {
        for line in text.components(separatedBy: .newlines) {
            let collapsed = line.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !collapsed.isEmpty {
                return String(collapsed.prefix(maxLength))
            }
        }
        return ""
    }

    if let sess = session {
        // 예상 남은 시간("남은 119초" 등)은 표시용 요약에서 제거한다 (실제 백엔드 제한 시간과 무관).
        let withoutCountdown = sess.statusMessage.replacingOccurrences(
            of: "\\(?\\s*남은\\s*(약\\s*)?\\d+\\s*(초|분)(\\s*(남음|정도))?\\s*\\)?",
            with: "",
            options: .regularExpression
        )
        let summary = cleanFirstLine(withoutCountdown, maxLength: 240)
        let isGeneric = summary.isEmpty || summary == "대기 중" || summary == "준비 중" || summary == sess.runStatus
        switch sess.runStatus {
        case "completed":
            if let last = sess.lastSummary {
                let done = cleanFirstLine(last, maxLength: 240)
                if !done.isEmpty { return done }
            }
            if let msg = project.conversation.last(where: { $0.sender == "assistant" && $0.text.hasPrefix("업무 완료:") }) {
                let done = cleanFirstLine(msg.text, maxLength: 240)
                if !done.isEmpty { return done }
            }
            return "업무 완료"
        case "running":
            if summary.contains("AI 업무 계획") { return "AI 응답 대기" }
            // 엔진 내부 단계 번호가 사용자 업무 단계처럼 보이지 않도록 선행 '단계 N:' 접두만 제거한다.
            let shown = summary.replacingOccurrences(
                of: "^단계\\s*\\d+\\s*([:：]\\s*|$)",
                with: "",
                options: .regularExpression
            )
            if !shown.isEmpty && shown != "대기 중" && shown != "준비 중" && shown != sess.runStatus {
                return shown
            }
            return "진행 중"
        case "userControl":
            return (sawNeedsConfirmation(sess) && !summary.isEmpty) ? summary : "직접 조작 중 (수동)"
        case "paused":
            let lower = summary.lowercased()
            let hasReason = lower.contains("로그인") || lower.contains("인증") || lower.contains("확인") || lower.contains("오류") || lower.contains("실패")
            return (hasReason && !summary.isEmpty) ? summary : "일시 중단됨"
        case "failed":
            return isGeneric ? "실패했습니다" : summary
        case "interrupted":
            return isGeneric ? "중단되었습니다" : summary
        default:
            return "실행 대기 중"
        }
    }
    if let lastMsg = project.conversation.last?.text {
        let summary = cleanFirstLine(lastMsg, maxLength: 240)
        if !summary.isEmpty {
            return summary
        }
    }
    let goalSummary = cleanFirstLine(project.goal, maxLength: 240)
    if !goalSummary.isEmpty {
        return goalSummary
    }
    return ""
}

// MARK: - Reusable Status Badge

struct SAWStatusBadge: View {
    let status: String
    @Environment(\.bkPalette) private var palette

    var body: some View {
        Text(sawStatusKorean(status))
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(sawStatusBackgroundColor(status, palette: palette)))
            .foregroundColor(sawStatusColor(status, palette: palette))
    }
}

// MARK: - Planning Checklist + AI Sparkle Icon

/// Simple icon combining checklist and AI sparkle (SF Symbols).
/// 16-24px legible, zero raster images, zero external dependencies.
struct SAWTelescopeIcon: View {
    init() {}

    var body: some View {
        ZStack {
            Image(systemName: "checklist")
                .font(.system(size: 13, weight: .semibold))
                .offset(x: -2, y: 1)
            Image(systemName: "sparkles")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(Color.accentColor)
                .offset(x: 6, y: -5)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("AI플레너")
    }
}



// MARK: - Native Resize Divider

final class PlannerNativeResizeHandle: NSView {
    var onBegan: (() -> Void)?
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: ((CGFloat) -> Void)?

    private var startWindowX: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("플레너 너비 조절")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityLabel("플레너 너비 조절")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        let separatorWidth: CGFloat = 1.0
        let separatorRect = NSRect(
            x: bounds.midX - (separatorWidth / 2.0),
            y: bounds.minY,
            width: separatorWidth,
            height: bounds.height
        )
        separatorRect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        startWindowX = event.locationInWindow.x
        onBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX = startWindowX else { return }
        let delta = event.locationInWindow.x - startX
        onChanged?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard let startX = startWindowX else { return }
        let delta = event.locationInWindow.x - startX
        startWindowX = nil
        onEnded?(delta)
    }
}

struct PlannerNativeResizeDivider: NSViewRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> PlannerNativeResizeHandle {
        let view = PlannerNativeResizeHandle(frame: .zero)
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: PlannerNativeResizeHandle, context: Context) {
        nsView.onBegan = onBegan
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }
}

// MARK: - Hana result question (explicit Send only)

/// Small question entry for the frozen latest completed result of this project. Sends nothing until '보내기'.
struct SAWHanaResultQuestionView: View {
    @ObservedObject var session: SAWProjectSession
    @ObservedObject var workspace: SAWWorkspace
    @ObservedObject private var hana = HanaPanelHost.shared
    @Binding var isPresented: Bool
    @Environment(\.bkPalette) private var palette

    private var trimmedCount: Int {
        session.hanaResultQuestionDraft.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
    }

    /// The assistant the user currently has selected (Hana or any catalog / custom service).
    private var selectedService: AIService { workspace.appModel.aiServices.selectedService }
    private var assistantName: String { selectedService.isHana ? "하나" : selectedService.name }
    private var assistantSession: AssistantWebSession? {
        selectedService.isHana ? HanaPanelHost.shared.plannerSession : workspace.appModel.thirdPartyAIHost.plannerSession
    }

    private func openHana() {
        workspace.appModel.selectedTab = .browser
        workspace.appModel.temporaryShowHanaPanel = selectedService.isHana
        workspace.appModel.setAIPanelOpen(true)
    }

    private func send(_ reference: SAWProjectSession.HanaResultReference) {
        // The target is captured at the press; a service without a usable host is refused, never sent to Hana.
        let service = selectedService
        let target: SAWProjectSession.ResultQuestionTarget = service.isHana
            ? .hana : .assistant(serviceID: service.id, session: workspace.appModel.thirdPartyAIHost.plannerSession)
        Task { @MainActor in
            let failure = await session.sendHanaResultQuestion(reference: reference, question: session.hanaResultQuestionDraft, target: target)
            if failure == nil {
                openHana()
                isPresented = false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(assistantName)에게 물어보기")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.textColor)
            if let reference = session.hanaResultReference {
                let projectName = workspace.store.projects.first(where: { $0.id == reference.projectID }).map { sawDisplayProjectTitle($0) } ?? "프로젝트"
                VStack(alignment: .leading, spacing: 2) {
                    Text("프로젝트: \(projectName)")
                    Text("결과: \(reference.title) · 완료 \(sawFormatDate(reference.completedAt))")
                    Text(reference.artifactID == nil
                         ? "완료 이력 요약만 전달합니다 (보고서 본문 없음)"
                         : "보낼 때 요약과 보고서 본문(앞부분 최대 4000자)을 읽어 전달합니다")
                }
                .font(.system(size: 11))
                .foregroundColor(palette.textColor.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $session.hanaResultQuestionDraft)
                    .font(.system(size: 13))
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface2Color))
                    .disabled(session.isSendingHanaResultQuestion || session.hanaResultQuestionAmbiguous)

                if trimmedCount > SAWProjectSession.hanaResultQuestionLimit {
                    Text("질문이 \(SAWProjectSession.hanaResultQuestionLimit)자를 넘습니다 (\(trimmedCount)자)")
                        .font(.system(size: 11))
                        .foregroundColor(palette.dangerColor)
                }
                if selectedService.isHana, !hana.isBridgeReady, !session.isSendingHanaResultQuestion {
                    Text("하나 대화창을 준비하는 중입니다. 준비되면 보내 주세요.")
                        .font(.system(size: 11))
                        .foregroundColor(palette.warnColor)
                } else if !selectedService.isHana, assistantSession?.binding == nil, !session.isSendingHanaResultQuestion {
                    Text("\(assistantName) 대화창이 아직 연결되지 않았습니다. 비서 화면에서 보낼 대화를 연 뒤 보내 주세요.")
                        .font(.system(size: 11))
                        .foregroundColor(palette.warnColor)
                }
                if let error = session.hanaResultQuestionError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(palette.dangerColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Button("취소") {
                        session.cancelHanaResultQuestion()
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(session.isSendingHanaResultQuestion)
                    Spacer()
                    if session.hanaResultQuestionError != nil {
                        Button(session.hanaResultQuestionAmbiguous ? "\(assistantName)에서 확인" : "\(assistantName) 열기") {
                            openHana()
                            isPresented = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(session.isSendingHanaResultQuestion)
                    }
                    if session.isSendingHanaResultQuestion {
                        ProgressView().controlSize(.small)
                    }
                    Button("보내기") { send(reference) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(session.isSendingHanaResultQuestion
                                  || session.hanaResultQuestionAmbiguous
                                  || trimmedCount == 0
                                  || trimmedCount > SAWProjectSession.hanaResultQuestionLimit)
                }
            } else {
                Text(session.hanaResultQuestionError ?? "물어볼 완료된 결과가 없습니다.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.textColor.opacity(0.8))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("닫기") { isPresented = false }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

// MARK: - Main AI플레너 View

/// AI플레너 화면: 좌측 플레너(프로젝트 목록 + 인라인 업무 지시 편집기), 우측 작업창(전용 브라우저)
struct SAWView: View {
    @ObservedObject var workspace: SAWWorkspace
    @ObservedObject private var appModel: AppModel
    var projectRevealToken: Int = 0
    var onOpenSidebar: (() -> Void)? = nil

    init(workspace: SAWWorkspace, projectRevealToken: Int = 0, onOpenSidebar: (() -> Void)? = nil) {
        self.workspace = workspace
        self._appModel = ObservedObject(wrappedValue: workspace.appModel)
        self.projectRevealToken = projectRevealToken
        self.onOpenSidebar = onOpenSidebar
    }
    @Environment(\.bkPalette) private var palette

    @State private var isTaskPanelFolded: Bool = false
    @AppStorage("sawPlannerPanelWidth.v2") private var rememberedPlannerWidth: Double = 429
    @State private var plannerDragStartWidth: CGFloat?
    @State private var plannerDragTranslation: CGFloat = 0

    private func effectiveStoredPlannerWidth() -> CGFloat {
        let raw = rememberedPlannerWidth
        if raw.isNaN || !raw.isFinite || raw <= 0 {
            return 429
        }
        return CGFloat(raw)
    }

    private func clampedPlannerWidth(availableWidth: CGFloat, requestedWidth: CGFloat) -> CGFloat {
        let minW: CGFloat = 300
        let minBrowserW: CGFloat = 320
        let dividerW: CGFloat = 16
        let maxAllowed = max(minW, availableWidth - minBrowserW - dividerW)
        return min(max(requestedWidth, minW), maxAllowed)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Persistent Store Error Banner
            if let err = workspace.store.errorMessage, !err.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(palette.dangerColor)
                    Text("저장소 오류: \(err)")
                        .font(.system(size: 14))
                        .foregroundColor(palette.textColor)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(palette.dangerSoftColor)
            }

            // Top Header: Branding, Folding
            headerView

            Divider()

            // Main Split: 플래너 (LEFT) | 작업창 (RIGHT)
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let totalHeight = geo.size.height
                let baseWidth = clampedPlannerWidth(availableWidth: totalWidth, requestedWidth: effectiveStoredPlannerWidth())
                let leftWidth = clampedPlannerWidth(availableWidth: totalWidth, requestedWidth: (plannerDragStartWidth ?? baseWidth) + plannerDragTranslation)
                let browserWidth = max(1, totalWidth - (isTaskPanelFolded ? 0 : (leftWidth + 16)))
                let browserHeight = max(1, totalHeight)

                HStack(spacing: 0) {
                    if !isTaskPanelFolded {
                        taskPanel
                            .frame(width: leftWidth)
                            .frame(maxHeight: .infinity)

                        PlannerNativeResizeDivider(
                            onBegan: {
                                plannerDragStartWidth = baseWidth
                                plannerDragTranslation = 0
                            },
                            onChanged: { delta in
                                plannerDragTranslation = delta
                            },
                            onEnded: { delta in
                                let rawTarget = (plannerDragStartWidth ?? baseWidth) + delta
                                let finalWidth = clampedPlannerWidth(availableWidth: totalWidth, requestedWidth: rawTarget)
                                rememberedPlannerWidth = Double(finalWidth)
                                plannerDragStartWidth = nil
                                plannerDragTranslation = 0
                            }
                        )
                        .frame(width: 16)
                        .frame(maxHeight: .infinity)
                        .accessibilityLabel("플래너 너비 조절")
                    }

                    browserPanel
                        .frame(width: browserWidth, height: browserHeight)
                }
                .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
            }
            .background(palette.bgColor)
        }
        .onAppear {
            workspace.ensureUsableContext()
        }
        .onChange(of: projectRevealToken) { _ in
            isTaskPanelFolded = false
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(spacing: 12) {
            Button {
                onOpenSidebar?()
            } label: {
                HStack(spacing: 8) {
                    SAWTelescopeIcon()
                        .frame(width: 20, height: 20)

                    Text(workspace.selectedProject.map { sawDisplayProjectTitle($0) } ?? "플래너")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(palette.textColor)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("사이드바 열기")
            .accessibilityLabel("사이드바 열기")

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isTaskPanelFolded.toggle()
                }
            } label: {
                Image(systemName: isTaskPanelFolded ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 14))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(isTaskPanelFolded ? "플래너 펼치기" : "플래너 접기")
            .accessibilityLabel(isTaskPanelFolded ? "플래너 펼치기" : "플래너 접기")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.cardColor)
    }

    // MARK: - Task Panel (Detail Content + Bottom Composer)

    private var taskPanel: some View {
        VStack(spacing: 0) {
            // Selected Project Details & Conversation OR Empty State
            if let project = workspace.selectedProject, let session = workspace.existingSession(for: project.id) {
                SAWTaskPanelView(
                    project: project,
                    session: session,
                    workspace: workspace,
                    isDetailsCollapsed: .constant(false)
                )
                .id(project.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Text("선택된 프로젝트가 없습니다.")
                        .font(.system(size: 13))
                        .foregroundColor(palette.textColor.opacity(0.6))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.cardColor)
    }

    // MARK: - Browser Panel (RIGHT)

    private var browserPanel: some View {
        Group {
            if let project = workspace.selectedProject, let session = workspace.existingSession(for: project.id) {
                SAWBrowserPanelView(session: session, workspace: workspace, sourceBrowser: appModel.browser)
                    .id(project.id)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("작업창을 준비하는 중입니다...")
                        .font(.system(size: 14))
                        .foregroundColor(palette.textColor.opacity(0.6))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bgColor)
                .onAppear {
                    workspace.ensureUsableContext()
                }
            }
        }
    }
}

// MARK: - Project Row Views (Observed Child Row for Real-Time Updates)

struct SAWProjectRowView: View {
    let project: SAWProject
    @ObservedObject var workspace: SAWWorkspace
    let isSelected: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var confirmDesignateTest = false

    var body: some View {
        Group {
            if let sess = workspace.existingSession(for: project.id) {
                SAWProjectRowActiveView(
                    project: project,
                    session: sess,
                    isSelected: isSelected,
                    isExpanded: isExpanded,
                    onToggle: onToggle,
                    onArchive: { workspace.archiveProject(project.id) },
                    onDesignateTest: { confirmDesignateTest = true },
                    onFinishTest: { workspace.markTestProjectFinished(project.id) }
                )
            } else {
                SAWProjectRowInactiveView(
                    project: project,
                    isSelected: isSelected,
                    isExpanded: isExpanded,
                    onToggle: onToggle,
                    onArchive: { workspace.archiveProject(project.id) },
                    onDesignateTest: { confirmDesignateTest = true },
                    onFinishTest: { workspace.markTestProjectFinished(project.id) }
                )
            }
        }
        .alert("테스트용으로 지정", isPresented: $confirmDesignateTest) {
            Button("테스트용으로 지정") { workspace.designateTestProject(project.id) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 프로젝트를 테스트용으로 지정합니다. 이후 '테스트 검증 완료'를 선택하고 실행 중인 작업이 없으면 이 프로젝트의 앱 내 기록(프로젝트와 실행 기록)만 삭제됩니다. 이미 저장된 파일은 삭제되지 않습니다.")
        }
    }
}

/// Shared context menu of both project row variants.
private struct SAWProjectRowMenu: View {
    let project: SAWProject
    let onArchive: () -> Void
    let onDesignateTest: () -> Void
    let onFinishTest: () -> Void

    var body: some View {
        if project.isTestProject {
            Text("테스트 프로젝트")
        }
        Button("프로젝트 보관") {
            onArchive()
        }
        if project.hasExplicitManualTestProvenance {
            if project.testFinishedAt == nil {
                Button("테스트 검증 완료") {
                    onFinishTest()
                }
            } else {
                Text("테스트 검증 완료됨 · 안전해지면 기록 정리")
            }
        } else if !project.isTestProject {
            Button("테스트용으로 지정…") {
                onDesignateTest()
            }
        }
    }
}

struct SAWProjectRowActiveView: View {
    let project: SAWProject
    @ObservedObject var session: SAWProjectSession
    let isSelected: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onArchive: () -> Void
    let onDesignateTest: () -> Void
    let onFinishTest: () -> Void
    @Environment(\.bkPalette) private var palette

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected && isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? palette.accentColor : palette.textColor.opacity(0.6))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(sawDisplayProjectTitle(project))
                        .help(project.goal)
                        .font(.system(size: 14, weight: isSelected ? .bold : .medium))
                        .foregroundColor(palette.textColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    let isWaitingGate = (session.runStatus == "running" || session.runStatus == "paused" || session.runStatus == "userControl")
                    let isAIWait = isWaitingGate && (
                        session.statusMessage.contains("AI 입력창을 다시 준비하고 있습니다") ||
                        session.statusMessage.contains("AI 대화창 입력란을 준비하지 못했습니다") ||
                        session.statusMessage.contains("AI 응답 오류") ||
                        (session.statusMessage.contains("계정") && (session.statusMessage.contains("대기") || session.statusMessage.contains("기다")))
                    )
                    let progressText: String = {
                        if session.runStatus == "running",
                           let currentStep = project.planSteps.first(where: { $0.status == "current" }) {
                            return currentStep.title
                        }
                        if isAIWait {
                            return "AI 연결 준비 중"
                        }
                        let rawSummary = meaningfulSummary(session: session, project: project)
                        return String(rawSummary.prefix(60))
                    }()

                    HStack(spacing: 6) {
                        if !progressText.isEmpty {
                            Text(progressText)
                                .font(.system(size: 12))
                                .foregroundColor(palette.textColor.opacity(0.65))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer()
                        }

                        if project.isTestProject {
                            Text("테스트")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(palette.textColor.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(palette.surface2Color))
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        if sawNeedsConfirmation(session) {
                            Text("확인 필요")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(palette.warnColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(palette.warnSoftColor))
                                .fixedSize(horizontal: true, vertical: false)
                        } else if isAIWait {
                            Text("AI 연결 대기")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(palette.warnColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(palette.warnSoftColor))
                                .fixedSize(horizontal: true, vertical: false)
                        } else {
                            SAWStatusBadge(status: session.runStatus)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? palette.surface2Color : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(sawTestProjectPrefix(project))\(sawDisplayProjectTitle(project)), 상태: \((sawNeedsConfirmation(session) ? "확인 필요" : sawStatusKorean(session.runStatus)))\(meaningfulSummary(session: session, project: project).isEmpty ? "" : ", 진행: \(meaningfulSummary(session: session, project: project))")")
        .help("\(sawTestProjectPrefix(project))\(sawDisplayProjectTitle(project)) - \((sawNeedsConfirmation(session) ? "확인 필요" : sawStatusKorean(session.runStatus)))")
        .contextMenu {
            SAWProjectRowMenu(project: project, onArchive: onArchive, onDesignateTest: onDesignateTest, onFinishTest: onFinishTest)
        }
    }
}

struct SAWProjectRowInactiveView: View {
    let project: SAWProject
    let isSelected: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onArchive: () -> Void
    let onDesignateTest: () -> Void
    let onFinishTest: () -> Void
    @Environment(\.bkPalette) private var palette

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected && isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? palette.accentColor : palette.textColor.opacity(0.6))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(sawDisplayProjectTitle(project))
                        .help(project.goal)
                        .font(.system(size: 14, weight: isSelected ? .bold : .medium))
                        .foregroundColor(palette.textColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    let progressText: String = {
                        let rawSummary = meaningfulSummary(session: nil, project: project)
                        return String(rawSummary.prefix(60))
                    }()

                    HStack(spacing: 6) {
                        if !progressText.isEmpty {
                            Text(progressText)
                                .font(.system(size: 12))
                                .foregroundColor(palette.textColor.opacity(0.65))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer()
                        }

                        if project.isTestProject {
                            Text("테스트")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(palette.textColor.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(palette.surface2Color))
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        SAWStatusBadge(status: "queued")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? palette.surface2Color : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(sawTestProjectPrefix(project))\(sawDisplayProjectTitle(project)), 상태: 대기 중")
        .help(project.isTestProject ? "\(sawTestProjectPrefix(project))\(sawDisplayProjectTitle(project)) - 대기 중" : "")
        .contextMenu {
            SAWProjectRowMenu(project: project, onArchive: onArchive, onDesignateTest: onDesignateTest, onFinishTest: onFinishTest)
        }
    }
}

// MARK: - Task Panel View (Details + Composer)

struct SAWTaskPanelView: View {
    let project: SAWProject
    @ObservedObject var session: SAWProjectSession
    @ObservedObject var workspace: SAWWorkspace
    @Binding var isDetailsCollapsed: Bool
    @Environment(\.bkPalette) private var palette

    @State private var didJustSend: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if !isDetailsCollapsed {
                SAWTaskDetailsView(
                    project: project,
                    session: session,
                    workspace: workspace,
                    didJustSend: $didJustSend
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }

            // Fixed Single Composer at the absolute bottom
            SAWComposerView(
                project: project,
                session: session,
                workspace: workspace,
                onSendMessage: {
                    didJustSend = true
                }
            )
        }
    }
}

// MARK: - Expanded Details View (Provider / Schedule + Status + Scrollable Middle Plan/History/Chat)

struct SAWTaskDetailsView: View {
    let project: SAWProject
    @ObservedObject var session: SAWProjectSession
    @ObservedObject var workspace: SAWWorkspace
    @Binding var didJustSend: Bool
    @Environment(\.bkPalette) private var palette

    @State private var scrollViewHeight: CGFloat = 0
    @State private var isNearBottom: Bool = true
    private let bottomAnchorID = "saw-chat-bottom-anchor"

    @State private var showScheduleHistory: Bool = false
    @State private var showArtifactList: Bool = false
    @State private var showToolList: Bool = false
    @State private var showToolSettings: Bool = false
    @State private var showHanaAsk: Bool = false
    @State private var scheduleNow: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            // Status message strip: max 2 lines summary, full details via scrollable disclosure below
            if !isPristineProject {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: sawNeedsConfirmation(session) ? "exclamationmark.circle.fill" : sawStatusIconName(session.runStatus))
                    .font(.system(size: 13))
                    .foregroundColor(sawStatusColor(session.runStatus, palette: palette))
                    .padding(.top, 2)

                Text(completedRunDocumentEntries.isEmpty
                     ? meaningfulSummary(session: session, project: project)
                     : "작업을 마쳤습니다. 아래에서 결과를 확인할 수 있습니다.")
                    .font(.system(size: 13))
                    .foregroundColor(palette.textColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if session.runStatus == "running" {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("진행 중")
                            .font(.system(size: 12))
                            .foregroundColor(palette.textColor.opacity(0.8))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(sawStatusBackgroundColor(session.runStatus, palette: palette))

            Divider()
            }

            topToolsBar

            Divider()

            // AI Planner Surface / Login Host on the LEFT (if active)
            if session.showingPlannerSurface || session.needsPlannerLogin {
                VStack(spacing: 0) {
                    HStack {
                        Text("AI 대화")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(palette.textColor)
                        Spacer()
                        Button("닫기") {
                            session.showingPlannerSurface = false
                            session.needsPlannerLogin = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(6)
                    .background(palette.surface2Color)

                    Divider()

                    if let plannerWV = session.transport.plannerWebView {
                        WebPageAgentPlannerWebViewRepresentable(webView: plannerWV, nativeInputAllowed: {
                            workspace.appModel.selectedTab == .saw &&
                            workspace.selectedProjectID == session.projectID &&
                            (session.showingPlannerSurface || session.needsPlannerLogin)
                        })
                            .frame(height: 180)
                    } else {
                        VStack {
                            Spacer()
                            Text("대화창 준비 중...")
                                .font(.system(size: 13))
                                .foregroundColor(palette.textColor.opacity(0.6))
                            Spacer()
                        }
                        .frame(height: 120)
                    }
                    Divider()
                }
            }

            // Compact Top Provider & Schedule (Always Visible at Top of Expanded Content)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Picker("AI 제공자", selection: Binding(
                        get: { project.usesAutomaticProvider ? "automatic" : project.providerID },
                        set: { newProvider in
                            workspace.mutateProject(id: project.id) { p in
                                p.usesAutomaticProvider = (newProvider == "automatic")
                                if newProvider != "automatic" {
                                    p.providerID = newProvider
                                }
                            }
                        }
                    )) {
                        Text("자동 (로그인된 AI 사용)").tag("automatic")
                        Text("ChatGPT (Codex)").tag("chatgpt")
                        Text("Claude").tag("claude")
                        Text("Gemini").tag("gemini")
                    }
                    .labelsHidden()
                    .accessibilityLabel("AI 제공자")
                    .pickerStyle(.menu)
                    .font(.system(size: 12))
                    .disabled(session.runStatus == "running")
                    .frame(minWidth: 140, alignment: .leading)

                    Picker("연결 방식", selection: Binding(
                        get: { project.connectionMode },
                        set: { newMode in
                            workspace.mutateProject(id: project.id) { p in
                                p.connectionMode = newMode
                            }
                        }
                    )) {
                        Text("자동").tag("automatic")
                        Text("CLI").tag("cli")
                        Text("웹").tag("web")
                    }
                    .labelsHidden()
                    .accessibilityLabel("연결 방식")
                    .pickerStyle(.menu)
                    .font(.system(size: 12))
                    .disabled(session.runStatus == "running")
                    .frame(minWidth: 70, alignment: .leading)

                    Spacer()

                    HStack(spacing: 4) {
                        Text("예약")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(palette.textColor.opacity(0.8))

                        Toggle("", isOn: Binding(
                            get: { project.schedule.enabled },
                            set: { val in
                                workspace.mutateProject(id: project.id) { p in
                                    let was = p.schedule.enabled
                                    p.schedule.enabled = val
                                    if val && !was { p.schedule.notBefore = Date() }
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                }

                if !session.activePlannerLabel.isEmpty {
                    Text(session.activePlannerLabel)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .help(session.activePlannerLabel)
                }

                scheduleNextLine

                if project.schedule.enabled {
                    HStack(spacing: 6) {
                        Picker("주기", selection: Binding(
                            get: { project.schedule.frequency },
                            set: { newFreq in
                                workspace.mutateProject(id: project.id) { $0.schedule.frequency = newFreq; $0.schedule.notBefore = Date() }
                            }
                        )) {
                            Text("수동").tag("manual")
                            Text("매시 정각").tag("hourly")
                            Text("매일 지정 시각").tag("daily")
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 12))

                        if project.schedule.frequency == "hourly" {
                            Text("정각 00분")
                                .font(.system(size: 12))
                                .foregroundColor(palette.textColor.opacity(0.8))
                        } else if project.schedule.frequency == "daily" {
                            Picker("시", selection: Binding(
                                get: { project.schedule.hour },
                                set: { h in workspace.mutateProject(id: project.id) { $0.schedule.hour = h; $0.schedule.notBefore = Date() } }
                            )) {
                                ForEach(0..<24) { h in Text(String(format: "%02d시", h)).tag(h) }
                            }
                            .pickerStyle(.menu)
                            .font(.system(size: 12))

                            Picker("분", selection: Binding(
                                get: { project.schedule.minute },
                                set: { m in workspace.mutateProject(id: project.id) { $0.schedule.minute = m; $0.schedule.notBefore = Date() } }
                            )) {
                                ForEach(0..<60) { m in Text(String(format: "%02d분", m)).tag(m) }
                            }
                            .pickerStyle(.menu)
                            .font(.system(size: 12))
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(palette.cardColor)

            Divider()

            // Scrollable Middle containing Full-Width Plan, Notes, History, and Chat in Chronological Order
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if !isPristineProject, let session = Optional(session) {
                            let fullMsg = session.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                            let summary = meaningfulSummary(session: session, project: project)
                            let completedRun = completedRunDocumentEntries.isEmpty ? nil : currentCompletedRun?.run
                            let completedText: String = {
                                guard let run = completedRun else { return "" }
                                let own = run.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                                return own.isEmpty ? summary : own
                            }()
                            if completedRun != nil || (!fullMsg.isEmpty && fullMsg != summary) {
                                DisclosureGroup(completedRun != nil ? "완료 내용" : "전체 상태 보기") {
                                    Text(completedRun != nil ? completedText : session.statusMessage)
                                        .font(.system(size: 13))
                                        .foregroundColor(palette.textColor)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.vertical, 4)
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(palette.textColor.opacity(0.9))
                                .padding(8)
                                .background(sawStatusBackgroundColor(session.runStatus, palette: palette).opacity(0.5))
                                .cornerRadius(6)
                            }
                        }

                        if !isPristineProject {
                            DisclosureGroup("업무 전체 내용") {
                                Text(project.goal)
                                    .font(.system(size: 12))
                                    .foregroundColor(palette.textColor.opacity(0.85))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(palette.textColor.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(palette.cardColor)

                            // 1. Full-Width Readable Progress Plan (Font 14, Wrapping, No Step Loss)
                            planSection
                        }

                        // 2. Compact Backscroll Notes & History
                        if !project.notes.isEmpty || !workspace.runs(for: project.id).isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                if !project.notes.isEmpty {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("메모")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(palette.textColor.opacity(0.7))
                                        ForEach(project.notes, id: \.self) { note in
                                            Text("• \(note)")
                                                .font(.system(size: 12))
                                                .foregroundColor(palette.textColor.opacity(0.8))
                                                .textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface2Color))
                                }

                                let runs = workspace.runs(for: project.id)
                                if !runs.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("최근 실행 기록")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(palette.textColor.opacity(0.7))
                                        ForEach(Array(runs)) { r in
                                            HStack(alignment: .top, spacing: 4) {
                                                SAWStatusBadge(status: r.status)
                                                Text(r.summary)
                                                    .font(.system(size: 12))
                                                    .foregroundColor(palette.textColor.opacity(0.8))
                                                    .textSelection(.enabled)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                Spacer()
                                                Text(sawFormatDate(r.startedAt))
                                                    .font(.system(size: 11))
                                                    .foregroundColor(palette.textColor.opacity(0.5))
                                            }
                                        }
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface2Color))
                                }
                            }
                        }

                        // 3. Conversation Chat Messages
                        if project.conversation.isEmpty {
                            VStack(alignment: .center, spacing: 6) {
                                Spacer(minLength: 24)
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 22))
                                    .foregroundColor(palette.textColor.opacity(0.3))
                                Text(isPristineProject
                                     ? "어떤 일을 도와드릴까요? 아래에 할 일을 알려주세요."
                                     : "아래 입력창에 지시사항을 입력해 작업을 시작하거나 추가 지시를 전달하세요.")
                                    .font(.system(size: 13))
                                    .foregroundColor(palette.textColor.opacity(0.5))
                                    .multilineTextAlignment(.center)
                                Spacer(minLength: 24)
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(project.conversation) { msg in
                                chatMessageRow(msg)
                                    .id(msg.id)
                            }
                        }

                        // 4. Documents produced by the current completed run (existing document rows)
                        let resultEntries = completedRunDocumentEntries
                        if !resultEntries.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("이번 업무 결과")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(palette.textColor.opacity(0.7))
                                ForEach(resultEntries) { entry in
                                    documentRow(entry)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Bottom anchor for viewport tracking & auto-scroll
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ChatBottomOffsetPreferenceKey.self,
                                        value: geo.frame(in: .named("sawChatScrollView")).maxY
                                    )
                                }
                            )
                    }
                    .padding(10)
                    .frame(minHeight: scrollViewHeight, alignment: .bottom)
                }
                .coordinateSpace(name: "sawChatScrollView")
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollViewHeightPreferenceKey.self,
                            value: geo.size.height
                        )
                    }
                )
                .onPreferenceChange(ScrollViewHeightPreferenceKey.self) { h in
                    scrollViewHeight = h
                }
                .onPreferenceChange(ChatBottomOffsetPreferenceKey.self) { bottomY in
                    if scrollViewHeight > 0 {
                        let distance = bottomY - scrollViewHeight
                        isNearBottom = (distance <= 80)
                    }
                }
                .frame(minHeight: 160, maxHeight: .infinity)
                .background(palette.bgColor)
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
                .onChange(of: project.id) { _ in
                    isNearBottom = true
                    DispatchQueue.main.async {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
                .onChange(of: project.conversation) { _ in
                    let shouldFollow = isNearBottom || didJustSend
                    if didJustSend {
                        didJustSend = false
                    }
                    if shouldFollow {
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                            }
                        }
                    }
                }
                .onChange(of: completedRunDocumentEntries.map(\.id)) { _ in
                    guard isNearBottom else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: didJustSend) { val in
                    if val {
                        didJustSend = false
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Top Tools Bar (작업 페이지 / 예약 기록 / 결과물 / 사용 도구)

    private var topToolsBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    workPagesMenu
                    topBarButton(title: "예약 기록", icon: "calendar.badge.clock") { showScheduleHistory.toggle() }
                        .popover(isPresented: $showScheduleHistory, arrowEdge: .bottom) { scheduleHistoryPopover }
                    topBarButton(title: "결과물 \(documentEntries.count)", icon: "doc.on.doc") { showArtifactList.toggle() }
                        .popover(isPresented: $showArtifactList, arrowEdge: .bottom) { artifactListPopover }
                    topBarButton(title: "사용 도구", icon: "wrench.and.screwdriver") { showToolList.toggle() }
                        .popover(isPresented: $showToolList, arrowEdge: .bottom) { toolListPopover }
                        .sheet(isPresented: $showToolSettings) {
                            SAWToolSettingsView(workspace: workspace, session: session)
                        }
                    topBarButton(title: "비서에게 물어보기", icon: "questionmark.bubble") {
                        session.prepareHanaResultQuestion()
                        workspace.appModel.temporaryShowHanaPanel = workspace.appModel.aiServices.selectedService.isHana
                        workspace.appModel.setAIPanelOpen(true)
                        showHanaAsk = true
                    }
                    .popover(isPresented: $showHanaAsk, arrowEdge: .bottom) {
                        SAWHanaResultQuestionView(session: session, workspace: workspace, isPresented: $showHanaAsk)
                    }
                }
                .padding(.vertical, 1)
            }
            Text(currentPageSummary)
                .font(.system(size: 12))
                .foregroundColor(palette.textColor.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(palette.cardColor)
    }

    private func topBarButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12))
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func pageHost(_ tab: LoginBrowserModel) -> String {
        tab.currentURL?.host ?? ""
    }

    private var workPagesMenu: some View {
        Menu {
            if session.tabs.isEmpty {
                Text("열린 작업 페이지가 없습니다")
            }
            ForEach(session.tabs, id: \.tabID) { (tab: LoginBrowserModel) in
                let host = pageHost(tab)
                let title = tab.pageTitle.isEmpty ? "새 탭" : tab.pageTitle
                Button {
                    session.selectTab(id: tab.tabID)
                } label: {
                    if tab.tabID == session.selectedTabID {
                        Label(host.isEmpty ? title : "\(title) · \(host)", systemImage: "checkmark")
                    } else {
                        Text(host.isEmpty ? title : "\(title) · \(host)")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.stack")
                Text("작업 페이지")
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var currentPageSummary: String {
        var parts: [String] = []
        if let tab = session.tabs.first(where: { $0.tabID == session.selectedTabID }) {
            let host = pageHost(tab)
            let title = tab.pageTitle.isEmpty ? "새 탭" : tab.pageTitle
            parts.append("현재 페이지: " + (host.isEmpty ? title : "\(title) · \(host)"))
        } else {
            parts.append("현재 페이지 없음")
        }
        if let runID = session.teamRunID {
            let active = project.teamAssignments.filter {
                $0.runID == runID && $0.generation == session.teamGeneration
                    && ($0.status == .queued || $0.status == .running)
            }.count
            if active > 0 {
                parts.append("팀 진행 \(active)건")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Schedule (next run + history)

    private func scheduleZone() -> TimeZone? {
        TimeZone(identifier: project.schedule.timeZoneID)
    }

    private func formatScheduleDate(_ date: Date) -> String {
        sawFormatDate(date, timeZone: scheduleZone() ?? .autoupdatingCurrent)
    }

    private var scheduleNextText: String {
        guard project.schedule.enabled, project.schedule.frequency != "manual" else {
            return "예약 꺼짐/수동"
        }
        guard scheduleZone() != nil else {
            return "시간대 '\(project.schedule.timeZoneID)'를 인식할 수 없어 다음 예약을 계산할 수 없습니다"
        }
        guard let next = SAWScheduler.nextRun(for: project, after: scheduleNow) else {
            return "예약 설정이 올바르지 않아 다음 예약을 계산할 수 없습니다"
        }
        return "다음 예약: \(formatScheduleDate(next)) (\(project.schedule.timeZoneID))"
    }

    private var scheduleNextLine: some View {
        Text(scheduleNextText)
            .font(.system(size: 12))
            .foregroundColor(palette.textColor.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onReceive(workspace.scheduler.$lastTickAt) { _ in
                scheduleNow = Date()
            }
    }

    private var scheduledRuns: [SAWRunRecord] {
        workspace.runs(for: project.id).filter { $0.slotKey != nil }
    }

    private var scheduleHistoryPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("예약 기록")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.textColor)
            let runs = scheduledRuns
            if runs.isEmpty {
                Text("예약으로 실행되거나 건너뛴 기록이 없습니다.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.textColor.opacity(0.7))
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(runs) { r in
                            scheduleRunRow(r)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func scheduleRunRow(_ r: SAWRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                SAWStatusBadge(status: r.status)
                Text(formatScheduleDate(r.startedAt))
                    .font(.system(size: 11))
                    .foregroundColor(palette.textColor.opacity(0.6))
            }
            if !r.summary.isEmpty {
                Text(r.summary)
                    .font(.system(size: 12))
                    .foregroundColor(palette.textColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface2Color))
    }

    // MARK: - Documents (결과물)

    private struct DocumentEntry: Identifiable {
        let artifact: SAWArtifact
        let exported: SAWArtifact?
        var id: UUID { artifact.id }
    }

    /// All retained artifacts; a preview and its linked saved export (same project/run) count as one document.
    private var documentEntries: [DocumentEntry] {
        let all = project.artifacts
        let linkedIDs = Set(all.compactMap { linkedExport(for: $0)?.id })
        return all
            .filter { !linkedIDs.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
            .map { DocumentEntry(artifact: $0, exported: linkedExport(for: $0)) }
    }

    /// Nothing started yet: no goal, chat, plan or run history, and no meaningful status reason to show.
    private var isPristineProject: Bool {
        guard session.runStatus == "queued",
              project.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.conversation.isEmpty,
              project.planSteps.isEmpty,
              workspace.runs(for: project.id).isEmpty else { return false }
        return ["", "대기 중", "준비 중"].contains(session.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func registeredFileExists(_ art: SAWArtifact) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: art.fileURL, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// The latest run, only when it is the current, completed run of this selected project.
    private var currentCompletedRun: (stored: SAWProject, run: SAWRunRecord)? {
        guard workspace.selectedProjectID == project.id,
              session.projectID == project.id,
              session.runStatus == "completed",
              let stored = workspace.store.projects.first(where: { $0.id == project.id && !$0.archived }),
              let run = workspace.runs(for: project.id).first,
              run.projectID == project.id,
              run.status == "completed",
              run.endedAt != nil,
              session.openRunRecordID == nil || session.openRunRecordID == run.id else { return nil }
        return (stored, run)
    }

    /// Documents of the latest run only when it is the current, completed run of this selected project and the files really exist.
    private var completedRunDocumentEntries: [DocumentEntry] {
        guard let (stored, run) = currentCompletedRun else { return [] }
        return documentEntries.filter { entry in
            let art = entry.artifact
            return art.runID == run.id
                && stored.artifacts.contains(where: { $0.id == art.id && $0.runID == run.id })
                && registeredFileExists(art)
                && (entry.exported.map { $0.runID == run.id && registeredFileExists($0) } ?? true)
        }
    }

    private func formatDocumentDate(_ date: Date) -> String {
        sawFormatDate(date)
    }

    private var artifactListPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("결과물 \(documentEntries.count)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.textColor)
            let entries = documentEntries
            if entries.isEmpty {
                Text("저장된 결과물이 없습니다.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.textColor.opacity(0.7))
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            documentRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func documentRow(_ entry: DocumentEntry) -> some View {
        let art = entry.artifact
        let shownTitle = art.title.isEmpty ? (entry.exported?.filename ?? art.filename) : art.title
        return VStack(alignment: .leading, spacing: 4) {
            Text(shownTitle)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.textColor)
                .fixedSize(horizontal: false, vertical: true)
            Text(formatDocumentDate(art.createdAt))
                .font(.system(size: 11))
                .foregroundColor(palette.textColor.opacity(0.6))
            SAWArtifactCardView(artifact: art, exportedArtifact: entry.exported, onOpenReport: {
                session.openReport(art)
            })
            Button {
                continueFromDocument(entry, title: shownTitle)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.turn.down.right")
                    Text("이 결과로 이어가기")
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(safePreviewURL(for: entry) == nil)
            .help(safePreviewURL(for: entry) == nil
                ? "앱에서 안전하게 열 수 있는 미리보기가 없는 외부 파일이라 이어가기를 쓸 수 없습니다. 열기/Finder는 그대로 사용할 수 있습니다."
                : "입력창에 이어갈 지시문 초안만 추가합니다. 전송은 직접 해야 합니다.")
        }
    }

    /// Opens the validated preview (if any) and appends a short scaffold to the draft. Never sends or starts a run.
    private func currentStoredArtifact(for entry: DocumentEntry) -> SAWArtifact? {
        guard let selectedID = workspace.selectedProjectID,
              selectedID == project.id,
              let storedProject = workspace.store.projects.first(where: { $0.id == project.id && !$0.archived }),
              let current = storedProject.artifacts.first(where: { $0.id == entry.artifact.id }) else { return nil }
        return current
    }

    private func safePreviewURL(for entry: DocumentEntry) -> URL? {
        guard let current = currentStoredArtifact(for: entry) else { return nil }
        return SAWReport.validatedURL(current, projectID: project.id)
    }

    private func continueFromDocument(_ entry: DocumentEntry, title: String) {
        guard let current = currentStoredArtifact(for: entry),
              let validated = SAWReport.validatedURL(current, projectID: project.id) else { return }
        session.openReport(current)
        guard session.activeBrowser?.currentURL == validated,
              session.prepareReportFollowUp(current) else { return }
        let scaffold = SAWProjectSession.ReportFollowUpScaffold
        let existing = session.composerDraft
        if !existing.contains(scaffold) {
            if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.composerDraft = scaffold
            } else {
                session.composerDraft = existing + (existing.hasSuffix("\n") ? "" : "\n") + scaffold
            }
        }
        showArtifactList = false
    }

    // MARK: - Tools (사용 도구)

    private struct ToolActivity: Identifiable {
        let id: String
        let icon: String
        let name: String
        let detail: String
    }

    private func formatToolDate(_ date: Date?) -> String {
        guard let date = date else { return "" }
        return " · 최근 " + sawFormatDate(date)
    }

    private var toolActivities: [ToolActivity] {
        let runID = session.teamRunID
        let receipts: [SAWChatMessage] = runID == nil ? [] : project.conversation.filter {
            $0.sender == "assistant" && $0.status == "success" && $0.runID == runID
        }
        let searches = receipts.filter { $0.text.hasPrefix("웹 검색(Exa) 완료:") }
        let clicks = receipts.filter { $0.text.hasPrefix("실행 확인: 클릭 전달 완료 ") }
        let observed = session.reportObservedSources
        let inputs = session.recentActionOutcomes.filter {
            $0.range(of: "^\\[단계 [0-9]+\\] (텍스트 입력 성공|옵션 선택 성공)$", options: .regularExpression) != nil
        }
        let saved = project.artifacts.filter {
            !SAWReport.isReportArtifact($0) && runID != nil && $0.runID == runID
                && FileManager.default.fileExists(atPath: $0.fileURL)
        }

        return [
            ToolActivity(
                id: "search", icon: "magnifyingglass", name: "웹 검색",
                detail: searches.isEmpty ? "현재 실행의 검색 기록 없음"
                    : "현재 실행 검색 성공 \(searches.count)건" + formatToolDate(searches.map(\.timestamp).max())
            ),
            ToolActivity(
                id: "observe", icon: "eye", name: "페이지 관찰",
                detail: observed.isEmpty ? "관찰된 페이지 기록 없음"
                    : "관찰한 페이지 \(observed.count)곳 (전체를 읽었다는 뜻은 아님)" + formatToolDate(observed.values.max())
            ),
            ToolActivity(
                id: "input", icon: "cursorarrow.click", name: "클릭 전달·입력",
                detail: {
                    var parts: [String] = []
                    parts.append(clicks.isEmpty ? "클릭 전달 기록 없음" : "클릭 전달 \(clicks.count)건 (사이트 반영 확인은 아님)")
                    parts.append(inputs.isEmpty ? "최근 입력 성공 기록 없음" : "최근 입력 성공 기록 \(inputs.count)건 (최근 기록만 보관)")
                    return parts.joined(separator: "\n")
                }()
            ),
            ToolActivity(
                id: "save", icon: "square.and.arrow.down", name: "문서 저장",
                detail: saved.isEmpty ? "확인된 저장 문서 없음"
                    : "저장된 문서 \(saved.count)건" + formatToolDate(saved.map(\.createdAt).max())
            ),
            ToolActivity(
                id: "local", icon: "terminal", name: "등록한 로컬 도구",
                detail: localToolDetail
            )
        ]
    }

    private var localToolDetail: String {
        let config = project.toolConfiguration ?? SAWToolConfiguration()
        let allowed = config.mcpServers.reduce(0) { $0 + $1.allowedToolNames.count }
        let configured = "설정됨: 스킬 \(config.skillFiles.count)개 · 터미널 도구 \(config.commands.count)개 · 허용 MCP 도구 \(allowed)개"
        guard let runID = session.teamRunID else { return configured + "\n현재 실행 기록 없음" }
        let local = project.conversation.filter { $0.sender == "assistant" && $0.runID == runID }
        let done = local.filter { $0.text.hasPrefix("도구 실행 완료:") }.count
        let failed = local.filter { $0.text.hasPrefix("도구 실행 실패:") }.count
        return configured + "\n현재 실행에서 실제 실행: 완료 \(done)건 · 실패 \(failed)건"
    }

    private var toolListPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("사용 도구")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.textColor)
            ForEach(toolActivities) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.system(size: 13))
                        .foregroundColor(palette.accentColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(palette.textColor)
                        Text(item.detail)
                            .font(.system(size: 12))
                            .foregroundColor(palette.textColor.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Text("연결 안내")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(palette.textColor.opacity(0.7))
            Text("CLI는 계획만 세우며, 클릭·입력·저장은 앱의 브라우저가 실행합니다. 웹 검색은 Exa 검색 도구를 사용하고, 기본 팀 업무 흐름은 앱에 내장되어 있습니다. CLI 자체의 도구는 꺼져 있고, 사용자가 등록한 터미널 도구와 허용한 MCP 도구만 앱이 고정된 인자로 실행합니다. MCP는 stdio 방식만 지원하며 네트워크는 차단됩니다. 설정됨은 실행됨과 다릅니다.")
                .font(.system(size: 12))
                .foregroundColor(palette.textColor.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Button("도구 연결 설정") {
                showToolList = false
                showToolSettings = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 340)
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("진행 계획")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.textColor.opacity(0.85))

            if project.planSteps.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 13))
                        .foregroundColor(palette.textColor.opacity(0.6))
                    Text(session.runStatus == "running" ? "업무 계획 수립 준비 중..." : (session.runStatus == "completed" ? "업무가 완료되었습니다" : "등록된 진행 계획이 없습니다"))
                        .font(.system(size: 14))
                        .foregroundColor(palette.textColor.opacity(0.7))
                }
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(project.planSteps) { step in
                        let isCurrent = step.status == "current" && session.runStatus == "running"
                        HStack(alignment: .top, spacing: 8) {
                            if step.status == "completed" {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(palette.accentColor)
                                    .padding(.top, 2)
                            } else if isCurrent {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 14))
                                    .foregroundColor(palette.accentColor)
                                    .padding(.top, 2)
                            } else {
                                Image(systemName: "circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(palette.textColor.opacity(0.4))
                                    .padding(.top, 2)
                            }
                            Text(step.title)
                                .font(.system(size: 14, weight: isCurrent ? .bold : .regular))
                                .foregroundColor(step.status == "waiting" ? palette.textColor.opacity(0.6) : palette.textColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface2Color))
    }

    /// Native export linked to a report preview, resolved only within the current project's latest artifacts.
    private func linkedExport(for art: SAWArtifact) -> SAWArtifact? {
        guard SAWReport.isReportArtifact(art),
              let id = art.exportedArtifactID,
              let runID = art.runID,
              let stored = workspace.store.projects.first(where: { $0.id == project.id })?.artifacts
                .first(where: { $0.id == id }),
              stored.runID == runID,
              !SAWReport.isReportArtifact(stored) else { return nil }
        return stored
    }

    /// Artifact and linked export IDs already shown by the inline current-result documents (exact IDs only).
    private var resultDocumentIDs: Set<UUID> {
        Set(completedRunDocumentEntries.flatMap { [$0.artifact.id] + ($0.exported.map { [$0.id] } ?? []) })
    }

    private func chatMessageRow(_ msg: SAWChatMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if msg.sender == "user" {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(msg.text)
                        .font(.system(size: 13))
                        .foregroundColor(palette.textColor)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.accentSoftColor))

                    Text(sawFormatDate(msg.timestamp))
                        .font(.system(size: 11))
                        .foregroundColor(palette.textColor.opacity(0.5))
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                            .foregroundColor(palette.accentColor)
                        Text("플래너")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(palette.textColor.opacity(0.7))
                        Spacer()
                        Text(sawFormatDate(msg.timestamp))
                            .font(.system(size: 11))
                            .foregroundColor(palette.textColor.opacity(0.5))
                    }

                    Text((msg.artifact.map(SAWReport.isReportArtifact) == true && (msg.artifact.flatMap(linkedExport(for:)) == nil || msg.text.hasPrefix("업무 완료:"))) ? "보고서를 작업창에 열었습니다." : msg.text)
                        .font(.system(size: 13))
                        .foregroundColor(palette.textColor)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface2Color))

                    if let art = msg.artifact, !resultDocumentIDs.contains(art.id) {
                        SAWArtifactCardView(artifact: art, exportedArtifact: linkedExport(for: art), onOpenReport: {
                            session.openReport(art)
                        })
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 40)
            }
        }
    }
}

// MARK: - Dedicated Bottom Composer View

struct SAWComposerView: View {
    let project: SAWProject
    @ObservedObject var session: SAWProjectSession
    @ObservedObject var workspace: SAWWorkspace
    var onSendMessage: (() -> Void)? = nil
    @Environment(\.bkPalette) private var palette

    @State private var isPromptFocused: Bool = false
    @State private var editorHeight: CGFloat = 42

    private var canSubmit: Bool {
        let trimmed = session.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.runStatus == "running" || session.runStatus == "userControl" || session.runStatus == "paused" {
            return !trimmed.isEmpty
        } else {
            return !trimmed.isEmpty || !project.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submitAction() {
        guard workspace.appModel.selectedTab == .saw && workspace.selectedProjectID == project.id else { return }
        let trimmed = session.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.runStatus == "running" || session.runStatus == "userControl" || session.runStatus == "paused" {
            guard !trimmed.isEmpty else { return }
            if session.sendUserMessage(trimmed) {
                session.composerDraft = ""
                onSendMessage?()
            }
        } else {
            let goalToStart = trimmed.isEmpty ? project.goal : trimmed
            guard !goalToStart.isEmpty else { return }
            guard goalToStart.utf16.count <= 10000 else {
                session.statusMessage = "목표 입력은 10,000자 이하여야 합니다."
                return
            }
            session.startRun(goal: goalToStart)
            if !trimmed.isEmpty {
                session.composerDraft = ""
                onSendMessage?()
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                // Compact upper controls row when running / paused
                if session.runStatus == "running" {
                    HStack(spacing: 4) {
                        Button {
                            session.takeoverManual()
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "hand.raised.fill")
                                Text("직접 조작")
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("직접 브라우저를 조작합니다")

                        Button {
                            session.stopRun()
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "pause.fill")
                                Text("일시 정지")
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.warnColor)
                        .controlSize(.small)
                        .help("업무를 일시 정지합니다")
                    }
                } else if session.runStatus == "userControl" || session.runStatus == "paused" {
                    HStack(spacing: 4) {
                        Button {
                            session.resumeRun()
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "play.fill")
                                Text("계속하기")
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accentColor)
                        .controlSize(.small)
                        .help("업무를 계속 진행합니다")

                        Button {
                            session.stopRun()
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "stop.fill")
                                Text("완전 중단")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.dangerColor)
                        .controlSize(.small)
                        .help("작업을 완전히 종료합니다")
                    }
                } else if (session.runStatus == "queued" || session.runStatus == "interrupted" || session.runStatus == "failed") && !project.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 4) {
                        Button {
                            let trimmedGoal = project.goal.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard workspace.appModel.selectedTab == .saw,
                                  workspace.selectedProjectID == project.id,
                                  (session.runStatus == "queued" || session.runStatus == "interrupted" || session.runStatus == "failed"),
                                  !trimmedGoal.isEmpty else {
                                return
                            }
                            session.startRun(goal: project.goal)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.clockwise")
                                Text("다시 실행")
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accentColor)
                        .controlSize(.small)
                        .help("저장된 목표로 새로 실행합니다")
                    }
                }

                // Single unified rounded themed container
                HStack(alignment: .bottom, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        if session.composerDraft.isEmpty {
                            Text("업무를 말씀해주세요")
                                .font(.system(size: 13))
                                .foregroundColor(palette.textColor.opacity(0.35))
                                .padding(.horizontal, 2)
                                .padding(.vertical, 2)
                                .allowsHitTesting(false)
                        }

                        SAWNativeTextEditor(
                            text: $session.composerDraft,
                            isFocused: $isPromptFocused,
                            calculatedHeight: $editorHeight,
                            textColor: NSColor(palette.textColor),
                            isActive: workspace.appModel.selectedTab == .saw && workspace.selectedProjectID == project.id,
                            canSubmit: canSubmit && !session.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            onSubmit: {
                                submitAction()
                            }
                        )
                        .frame(height: max(32, min(editorHeight, 160)))
                        .accessibilityLabel("업무 지시 입력")
                    }
                    .frame(maxWidth: .infinity)

                    // Send Button INSIDE lower right
                    Button {
                        submitAction()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(canSubmit ? palette.accentColor : palette.textColor.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .help("전송 (Enter), 줄바꿈 (Shift+Enter)")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(palette.cardColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(palette.accentColor, lineWidth: 1)
                )
            }
            .padding(8)
            .background(palette.surface2Color)
        }
        .onAppear {
            if project.goal.isEmpty && workspace.appModel.selectedTab == .saw && workspace.selectedProjectID == project.id {
                isPromptFocused = true
            }
        }
        .onReceive(workspace.appModel.$selectedTab) { newMode in
            if newMode != .saw {
                isPromptFocused = false
            }
        }
    }
}

// MARK: - Native Text Editor Helper

@MainActor
private struct SAWNativeTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var calculatedHeight: CGFloat
    var textColor: NSColor
    var isActive: Bool
    var canSubmit: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SAWAutoHeightScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 2

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)
        context.coordinator.ownedTextStorage = textStorage

        let textView = SAWNativeTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: 32), textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 32)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = textColor
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.onSubmit = onSubmit
        textView.canSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.canSubmit ?? true
        }

        scrollView.documentView = textView
        scrollView.onWidthChange = { [weak coordinator = context.coordinator] in
            coordinator?.recomputeHeight()
        }
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        context.coordinator.recomputeHeight()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        textView.onSubmit = onSubmit
        textView.textColor = textColor

        if textView.string != text && !textView.hasMarkedText() {
            let oldSelectedRanges = textView.selectedRanges
            textView.string = text
            let newLength = (text as NSString).length
            let clampedRanges = oldSelectedRanges.map { value -> NSValue in
                let range = value.rangeValue
                let loc = min(range.location, newLength)
                let len = min(range.length, newLength - loc)
                return NSValue(range: NSRange(location: loc, length: len))
            }
            textView.selectedRanges = clampedRanges
            coordinator.recomputeHeight()
        }

        let shouldFocus = isFocused && isActive
        if coordinator.lastRequestedFocus != shouldFocus {
            coordinator.lastRequestedFocus = shouldFocus
            if shouldFocus {
                if let window = textView.window, window.firstResponder != textView {
                    window.makeFirstResponder(textView)
                }
            } else {
                if let window = textView.window, window.firstResponder == textView {
                    window.makeFirstResponder(nil)
                }
            }
        } else if shouldFocus && coordinator.needsInitialFocusAttachment {
            if let window = textView.window, window.firstResponder != textView {
                window.makeFirstResponder(textView)
                coordinator.needsInitialFocusAttachment = false
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SAWNativeTextEditor
        var ownedTextStorage: NSTextStorage?
        weak var textView: SAWNativeTextView?
        weak var scrollView: NSScrollView?
        var lastRequestedFocus: Bool? = nil
        var needsInitialFocusAttachment: Bool = true

        init(_ parent: SAWNativeTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else {
                return
            }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            recomputeHeight()
        }

        func handleFocusChange(_ focused: Bool) {
            lastRequestedFocus = focused
            needsInitialFocusAttachment = false
            if parent.isFocused != focused {
                parent.isFocused = focused
            }
        }

        func recomputeHeight() {
            guard let textView = textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
                return
            }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let newHeight = ceil(usedRect.height + textView.textContainerInset.height * 2)
            let clamped = max(32, min(newHeight, 160))
            if abs(parent.calculatedHeight - clamped) >= 1.0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if abs(self.parent.calculatedHeight - clamped) >= 1.0 {
                        self.parent.calculatedHeight = clamped
                    }
                }
            }
        }
    }
}

@MainActor
private final class SAWAutoHeightScrollView: NSScrollView {
    var onWidthChange: (() -> Void)?
    private var lastObservedWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let currentWidth = bounds.width
        if abs(currentWidth - lastObservedWidth) >= 0.5 {
            lastObservedWidth = currentWidth
            onWidthChange?()
        }
    }
}

@MainActor
private final class SAWNativeTextView: NSTextView {
    weak var coordinator: SAWNativeTextEditor.Coordinator?
    var onSubmit: (() -> Void)?
    var canSubmit: (() -> Bool)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            coordinator?.handleFocusChange(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            coordinator?.handleFocusChange(false)
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let isReturn = (keyCode == 36 || keyCode == 76)

        if isReturn {
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }

            let relevantMask: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
            let relevantFlags = event.modifierFlags.intersection(relevantMask)

            if relevantFlags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }

            if relevantFlags.isEmpty {
                if event.isARepeat { return }
                if canSubmit?() ?? true {
                    onSubmit?()
                }
                return
            }
        }

        super.keyDown(with: event)
    }
}

// MARK: - Artifact Card View

struct SAWArtifactCardView: View {
    let artifact: SAWArtifact
    var exportedArtifact: SAWArtifact? = nil
    var onOpenReport: (() -> Void)? = nil
    @Environment(\.bkPalette) private var palette

    // Display/Finder target: the actual saved file when linked, else the artifact itself.
    private var shown: SAWArtifact {
        guard let e = exportedArtifact, e.id == artifact.exportedArtifactID,
              !SAWReport.isReportArtifact(e) else { return artifact }
        return e
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: shown.format == "html" ? "doc.richtext.fill" : "doc.text.fill")
                    .font(.system(size: 18))
                    .foregroundColor(palette.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(shown.filename)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(palette.textColor)
                        .lineLimit(1)
                        .help(shown.filename)
                        .accessibilityLabel(shown.filename)

                    Text("\(shown.format.uppercased()) 문서 • \(shown.byteCount) 바이트")
                        .font(.system(size: 11))
                        .foregroundColor(palette.textColor.opacity(0.6))
                }

                Spacer()
            }

            HStack(spacing: 6) {
                if SAWReport.isReportArtifact(artifact) {
                    Button("보고서 보기") {
                        onOpenReport?()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accentColor)
                    .controlSize(.small)
                    .font(.system(size: 12, weight: .medium))
                } else {
                    Button("문서 열기") {
                        let url = URL(fileURLWithPath: artifact.fileURL)
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accentColor)
                    .controlSize(.small)
                    .font(.system(size: 12, weight: .medium))
                }

                Button("Finder에서 보기") {
                    let url = URL(fileURLWithPath: shown.fileURL)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 12))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface2Color))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.borderColor, lineWidth: 1))
    }
}

// MARK: - Individual Observed Tab Item

struct SAWTabItemView: View {
    @ObservedObject var tab: LoginBrowserModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @Environment(\.bkPalette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    Image(systemName: tab.isShowingHome ? "house" : "globe")
                        .font(.system(size: 12))
                    Text(tab.tabTitle)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .frame(maxWidth: 130, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundColor(palette.textColor)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? palette.accentSoftColor : palette.surface2Color))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? palette.accentColor : palette.borderColor, lineWidth: 1))
    }
}

// MARK: - Dedicated Observed Active Browser View

struct SAWActiveBrowserView: View {
    @ObservedObject var tab: LoginBrowserModel
    @ObservedObject var session: SAWProjectSession
    @ObservedObject var workspace: SAWWorkspace
    @Environment(\.bkPalette) private var palette

    var body: some View {
        BrowserPane(appModel: workspace.appModel, model: tab, plannerSession: session)
    }
}

// MARK: - Browser Panel View (Right Column)

struct SAWBrowserPanelView: View {
    @ObservedObject var session: SAWProjectSession
    @ObservedObject var workspace: SAWWorkspace
    @ObservedObject var sourceBrowser: LoginBrowserModel
    @Environment(\.bkPalette) private var palette

    private var canImportBrowserPage: Bool {
        guard !sourceBrowser.isShowingHome else { return false }
        guard let url = sourceBrowser.currentURL ?? sourceBrowser.webView?.url else { return false }
        guard let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https") else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab Strip
            HStack(spacing: 6) {
                Text("작업창")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(palette.textColor)

                Button {
                    workspace.handleEntryFromBrowser(activeTab: workspace.appModel.browser)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 14))
                        Text("브라우저 페이지 불러오기")
                            .font(.system(size: 14))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canImportBrowserPage)
                .help("현재 브라우저의 페이지를 작업창에 엽니다. 진행 중인 업무에는 영향을 주지 않습니다.")

                Button {
                    session.newTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("프로젝트 새 탭 열기")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(session.tabs, id: \.tabID) { tab in
                            SAWTabItemView(
                                tab: tab,
                                isSelected: tab.tabID == session.selectedTabID,
                                onSelect: { session.selectTab(id: tab.tabID) },
                                onClose: { session.closeTab(id: tab.tabID) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }

                Spacer()

                // AI Planner Surface / Login Toggle Button
                Button {
                    session.showingPlannerSurface.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain.head.profile")
                        Text("AI 대화")
                    }
                    .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundColor((session.needsPlannerLogin || session.showingPlannerSurface) ? palette.warnColor : palette.textColor)
                .help("AI 서비스 대화창 화면 확인 및 로그인")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .background(palette.cardColor)

            Divider()

            // Active Browser Content View
            if let activeTab = session.activeBrowser {
                SAWActiveBrowserView(tab: activeTab, session: session, workspace: workspace)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("새 탭을 준비하는 중입니다...")
                        .font(.system(size: 14))
                        .foregroundColor(palette.textColor.opacity(0.6))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bgColor)
                .onAppear {
                    if session.tabs.isEmpty {
                        session.newTab()
                    }
                }
            }
        }
    }
}
