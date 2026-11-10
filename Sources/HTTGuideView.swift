import AppKit
import SwiftUI

/// HTT 1.0.0 인앱 사용 방법 안내 뷰 (HTTGuideView).
/// 사용자 작업 중심의 짧은 단계별 설명과 예시, 상세 토글(DisclosureGroup),
/// 그리고 관련 워크벤치 섹션으로 바로 이동하는 버튼을 제공한다.
public struct HTTGuideView: View {
    @ObservedObject var settingsStore: SettingsSectionStore
    @ObservedObject private var appearance = HTTAppearanceStore.shared
    @Environment(\.colorScheme) private var colorScheme

    public init(settingsStore: SettingsSectionStore) {
        self.settingsStore = settingsStore
    }

    private var palette: HTTThemePalette {
        appearance.palette(for: colorScheme)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                guideHeader
                overviewSection
                permissionSection
                screenTranslationSection
                mailTranslationSection
                browserTranslationSection
                inputHelperSection
                macManagementSection
                standaloneCoexistenceSection
                updateAndSupportSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 헤더

    private var guideHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HTTIconView(id: "help", size: 28)
                Text("사용 방법")
                    .font(.title2.bold())
                Spacer()
            }
            Text("모든 기능은 이 창 하나에서 사이드바로 이동합니다. 작업별 핵심 단계와 단축키, 안전 수칙을 확인하고 해당 섹션으로 바로 이동하세요.")
                .font(.callout)
                .foregroundStyle(palette.text2)
        }
        .padding(.bottom, 6)
    }

    // 1. HTT 통합 개요
    private var overviewSection: some View {
        guideCard(
            iconId: "home",
            title: "HTT 통합 개요 — 올인원 생산성 도구",
            badge: "기본 안내"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("HTT는 화면 번역, 메일·이미지 번역, 브라우저 번역, 입력 도우미(InputMate), Mac 관리(BTN)를 하나의 앱으로 결합한 통합 작업 공간입니다.")
                    .font(.body)

                Text("• 하나의 창: 사이드바는 브라우저·비서·플래너·다운로드·서버 현황·도구 및 하단 설정·사용 안내로 구성됩니다. 도구 메뉴에서 홈 요약, 번역, 입력 도우미, Mac 관리 등으로 이동할 수 있으며, 메뉴나 단축키로 열어도 새 창이 겹쳐 뜨지 않고 같은 창에서 해당 섹션으로 이동합니다. 다른 섹션으로 이동해도 진행 중인 메일 번역은 유지됩니다.")
                Text("• 예외: 화면 번역 캡처 영역, 시스템 파일 선택·권한·확인 대화상자, 업데이트 확인 창은 시스템 표준 방식으로 잠시 따로 나타납니다.")

                Text("• 원하는 기능만 선택: 각 모듈은 완전히 독립된 스위치를 가지므로 불필요한 기능은 끈 채 필요한 기능만 켜서 가볍게 사용할 수 있습니다.")
                Text("• 기존 데이터 보존: 통합 시 기존 앱의 설정·개인 사전·Mac 관리 기록 원본을 보존하며, HTT에 이미 저장된 설정값이 있으면 그 값을 우선합니다.")

                HStack(spacing: 12) {
                    Button("홈 화면 보기") {
                        settingsStore.section = .home
                    }
                    Button("앱 설정 열기") {
                        settingsStore.section = .general
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    // 2. 권한 안내 (조용한 초기 실행)
    private var permissionSection: some View {
        guideCard(
            iconId: "shield",
            title: "시스템 권한 — 필요할 때만 요청 (조용한 초기 실행)",
            badge: "보안·권한"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("HTT는 앱을 처음 설치하거나 실행했을 때 미리 권한 팝업을 띄우지 않습니다. 해당 기능을 실제로 사용할 때 시스템 권한 허용 대화상자가 나타납니다.")

                DisclosureGroup("권한별 요청 시점 및 목적 자세히 보기") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• 화면 기록 권한: 화면 번역 창에서 '선택 영역 번역'을 실행할 때 요청되며, 지정한 사각형 영역의 글자를 읽는 데만 쓰입니다.")
                        Text("• 손쉬운 사용 권한: 입력 도우미(한글 오타 교정, 첫 단어 복구, 트랙패드 보호)를 켤 때 필요합니다. 화면 번역이나 메일 번역에는 요구되지 않습니다.")
                        Text("• Apple Events 권한: 'Mail에서 선택한 메일 번역'을 실행할 때 선택된 메시지의 내용을 읽기 위해 요청됩니다.")
                    }
                    .font(.callout)
                    .foregroundStyle(palette.text2)
                    .padding(.top, 4)
                }
            }
        }
    }

    // 3. 화면 번역
    private var screenTranslationSection: some View {
        guideCard(
            iconId: "browser",
            title: "화면 번역 — 캡처 모드로 선택 영역 번역",
            badge: "전역 단축키 ⌃⌥⇧⌘T"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("• 캡처 모드: 화면 번역은 다른 앱 위에 투명한 캡처 영역을 띄우는 방식이라 이 창과 함께 보일 수 없습니다. 시작하면 이 창이 잠시 숨겨지고, 영역의 닫기 버튼이나 Esc로 끝내면 같은 창으로 돌아옵니다. 다른 앱에서 단축키로 시작했다면 끝낸 뒤 이 창을 자동으로 열지 않습니다.")
                Text("• 캡처 중 로그인·수동 진행·웹 번역 화면이 필요하면 캡처 영역만 잠시 내려가고(진행 중인 번역은 유지) 이 창에 해당 화면이 나타납니다. 모두 닫히면 다른 섹션으로 이동하지 않은 경우 캡처 모드로 돌아옵니다. 다른 섹션으로 이동하거나 취소·창 닫기를 하면 진행 중인 화면 번역은 취소됩니다.")
                Text("1. 캡처 모드 시작: 전역 단축키 ⌃⌥⇧⌘T는 어느 앱에서든 캡처 영역을 표시하며, HTT 앱 활성 시에는 ⌘0으로도 시작할 수 있습니다 (메뉴 막대에서는 시작/끝내기 토글 가능). 번역하려는 글자 위에 테두리를 맞춥니다.")
                Text("2. 선택 영역 번역 (Return / Enter 또는 주 버튼): 영역 안의 글자를 인식하고, 원문 줄 위치에 정확히 겹쳐 번역문을 표시합니다.")
                Text("3. 원문보기 (Space 키): 번역 완료 후 Space를 누르면 번역 패치가 숨겨져 아래 실제 화면과 즉시 비교할 수 있습니다.")

                HStack(spacing: 12) {
                    Button("화면 번역 캡처 시작") {
                        MailWindowCoordinator.shared.startCaptureModeFromWorkbench()
                    }
                    Button("브라우저 번역 보기") {
                        settingsStore.section = .browser
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    // 4. 메일 번역
    private var mailTranslationSection: some View {
        guideCard(
            iconId: "browser",
            title: "메일·이미지 번역 — Mail에서 선택한 메일 번역 vs 파일 열기",
            badge: "단축키 ⌃⌥⇧⌘M"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("• Mail에서 선택한 메일 번역: 전역 단축키 ⌃⌥⇧⌘M은 어느 앱에서든 Mail의 선택 메시지를 즉시 번역하며, HTT 앱 활성 시에는 ⇧⌘T로도 실행할 수 있습니다. 서식·표·이미지를 그대로 보존하며 이 창의 '메일·이미지 번역' 섹션에 결과를 보여줍니다.")
                Text("• 메일·이미지 번역 보기: 같은 섹션에서 이메일 파일(.eml)이나 이미지 파일을 직접 열거나 끌어다 놓아 번역할 수 있습니다. 다른 섹션으로 이동해도 번역은 이어지며, 도구 막대는 이 섹션에서만 나타납니다.")
                Text("• 내용 지우기: HTT 창을 닫거나 '현재 내용 지우기'(⌘⌫)를 하면 메일 내용이 앱 메모리에서 사라집니다.")
                Text("• Mail 상단 번역 버튼: Mail 창 상단 도구 막대에 번역 버튼을 연동하여 편리하게 이용할 수 있습니다 (앱 설정에서 켜기/끄기).")

                HStack(spacing: 12) {
                    Button("Mail에서 선택한 메일 번역") {
                        AppModel.shared.translateSelectedMail()
                    }
                    Button("메일·이미지 번역 보기") {
                        settingsStore.section = .mail
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    // 5. 브라우저 번역
    private var browserTranslationSection: some View {
        guideCard(
            iconId: "browser",
            title: "브라우저 번역 — Chrome, Whale, Safari 연동",
            badge: "확장 프로그램"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("• Chrome 및 Whale: 네이티브 브라우저 도우미와 압축 해제된 확장 프로그램을 등록하여 웹페이지 글자 및 이미지 속 글자 번역을 지원합니다 (macOS 15 이상 지원).")
                Text("• Safari: 번들된 Safari 웹 확장을 시스템 확장 설정에서 켜서 사용합니다. Safari 자체 번역 기능은 macOS 26 이상 및 사전 준비된 번역 언어 팩이 필요합니다 (macOS 26 미만 환경에서는 Chrome·Whale을 사용하세요).")
                Text("• 실시간 번역 안내: 무조건적인 연속 실시간 번역이 아니며, 사용자가 요청하거나 페이지 변경 시 필요한 영역을 번역합니다.")
                Text("• 웹 번역 전송 동의: 외부 웹 번역 서비스를 이용할 경우 사전에 명시적 전송 동의를 거치며, 동의 없이 외부로 텍스트를 전송하지 않습니다.")

                HStack(spacing: 12) {
                    Button("브라우저 번역 설정") {
                        settingsStore.section = .browser
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    // 6. 입력 도우미
    private var inputHelperSection: some View {
        guideCard(
            iconId: "edit",
            title: "입력 도우미 — 오타 교정, 단어 변환, 문장 번역, 트랙패드 보호",
            badge: "트랙패드 잠금 해제 ⌃⌥⌘⎋"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("• 옵션별 선택 활성화: 도구 › 입력 도우미(일반 설정은 설정 › 입력 설정) 메뉴에서 '앱별 입력 언어', '한글 교정 및 번역', '개인 사전', '트랙패드', '일반·정보'를 선택하여 자동 교정, 단어 변환, 문장 번역, 첫 단어 복구, 트랙패드 보호 등 원하는 기능을 각각 켜고 끌 수 있습니다.")
                Text("• 오타 교정 및 첫 단어 복구: 영문 자판 상태에서 입력한 한글(예: dkssud → 안녕)이나 한글 자판 상태의 영문을 자동으로 교정하며, 앱별 입력 언어 자동 전환을 지원합니다.")
                Text("• 단어 변환(접미사 ''): 단어 뒤에 따옴표 두 번을 붙여 입력하면 수동 변환 또는 한영 번역됩니다 (예: 사과'' → apple 또는 tjqltm'' → 서비스, 5월'' → May).")
                Text(verbatim: "• 문장 번역(문장 뒤 \\\\): 문장 뒤에 역슬래시 두 번(\\\\)을 입력하면 앞 줄 전체 문장을 번역합니다. 번역 기능은 macOS 26 이상과 사전 준비된 한국어-영어 모델이 필요하며, 모델이 미준비 상태이거나 실패할 경우 원문을 유지합니다.")
                Text("• 개인 사전 및 직후 삭제(Delete) 원복: 원치 않는 교정이 일어났을 때 즉시 삭제(Delete/⌫) 키를 누르면 원래 타이핑으로 즉시 원복됩니다. 개인 변환 사전은 단어 단위로만 적용되며 기기 내에만 로컬로 저장됩니다. 도구 › 입력 도우미 › 개인 사전에서 단어를 직접 추가·수정·삭제할 수 있습니다.")
                Text("• 트랙패드 잠금 비상 해제: ⌃⌥⌘⎋ (Control-Option-Command-Escape, Shift 불필요)를 누르면 잠긴 트랙패드가 즉시 강제 해제됩니다 (입력 도우미 기능은 일시정지되거나 꺼지지 않고 정상 유지됩니다).")

                HStack(spacing: 12) {
                    Button("입력 도우미 설정") {
                        settingsStore.section = .input
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    // 7. Mac 관리 (BTN)
    private var macManagementSection: some View {
        guideCard(
            iconId: "device_files",
            title: "Mac 관리 — 점검·선택·확인 단계와 시뮬레이터 조작 주의",
            badge: "단계별 안전 점검"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("• 수동 정리: 정리 후보 목록은 자동으로 선택되지 않으며, 사용자가 항목을 직접 선택하고 확인한 뒤에만 실행합니다.")
                Text("• 자동 정리: 저위험이며 휴지통에서 복원 가능한 파일만 즉시 정리합니다. 시뮬레이터와 프로세스는 자동으로 선택하거나 실행하지 않습니다.")
                Text("• 지원되는 파일(DerivedData, XCTest 기기 캐시)은 시스템 휴지통으로 이동하며 필요 시 다시 복원할 수 있습니다.")
                Text("• 시뮬레이터 삭제·데이터 초기화는 휴지통으로 이동하지 않으며 되돌릴 수 없으므로 신중히 점검 후 진행하십시오.")
                Text("• 왼쪽 메뉴의 'Mac 상태·정리'에서 시스템 저장 공간 상태와 정리 대상 항목을 조회하고, 'Mac 관리 설정'에서 사용 여부·자동 새로고침·정리 기능을 바꿉니다. 별도 창은 열리지 않습니다.")

                HStack(spacing: 12) {
                    Button("Mac 상태·정리 항목 보기") {
                        settingsStore.section = .macManagement
                    }
                    Button("Mac 관리 설정") {
                        settingsStore.section = .macManagementSettings
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    // 8. 독립 앱 공존 및 1회 이전
    private var standaloneCoexistenceSection: some View {
        guideCard(
            iconId: "shield",
            title: "독립 앱과의 안전한 공존 — 자동 일시정지와 1회 설정 이전",
            badge: "충돌 방지"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("• 독립 앱 실행 시 일시정지: 기존 독립 InputMate(TrackpadGuard) 또는 독립 BTN(BackToNormal)이 실행 중이면, 중복 관측과 이벤트 충돌을 방지하기 위해 HTT 내 해당 모듈이 자동으로 일시정지됩니다. 독립 앱이 종료되면 즉시 원래 설정대로 복구됩니다.")
                Text("• 1회 안전 데이터 이전: 기존 독립 앱의 설정, 개인 사전, 보호 목록을 1회 안전하게 가져옵니다. 원본 파일은 읽기만 하며 변경하지 않고, 기존 HTT 설정값이 이미 존재할 경우 HTT 설정값이 항상 우선합니다.")
            }
        }
    }

    // 9. 업데이트 및 지원
    private var updateAndSupportSection: some View {
        guideCard(
            iconId: "settings",
            title: "업데이트 및 지원",
            badge: "자동 업데이트"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("• 메뉴 막대에서 '업데이트 확인…'을 눌러 최신 안정화 버전을 간편하게 업데이트할 수 있습니다 (업데이트 창은 시스템 표준 방식으로 표시됩니다). 'HTT 정보'는 앱 설정 맨 위의 버전 정보로 이동합니다.")
                Text("• 백그라운드 자동 업데이트 확인을 원하시면 메뉴 막대의 '권한·연결 상태' 메뉴 또는 설정에서 켤 수 있습니다.")

                HStack(spacing: 12) {
                    Button("업데이트 확인…") {
                        (NSApp.delegate as? AppDelegate)?.checkForUpdates()
                    }
                    Button("앱 설정 열기") {
                        settingsStore.section = .general
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - 카드 컨테이너 도우미

    private func guideCard<Content: View>(
        iconId: String,
        title: String,
        badge: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HTTIconView(id: iconId, size: 22)
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(badge)
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(palette.accentSoft, in: Capsule())
                        .foregroundStyle(palette.accentStrong)
                }
                Divider()
                content()
            }
            .padding(8)
        }
    }
}
