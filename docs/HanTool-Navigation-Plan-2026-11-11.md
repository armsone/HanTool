# HanTool 메뉴 및 맥락 동작 개편 구현 결과 및 내부 계획서 (최종 9개 메뉴)

- **작성일**: 2026-11-11 (KST)
- **문서 상태**: 기획 검토(Claude 2회·Gemini2 2회·TM 2회) 및 코드 구현 완료 · 최종 검토 전원 완료(Gemini 1·2·3계정·Claude 각 2회, 루트 TM 소스+설치 UI 2회, 검토 범위 내 필수 잔여 결함 0건, 2026-11-11 02:51 KST 기준)
- **대상 저장소**: `/Users/armsone/git/HanTool` (한툴 1.28.0 빌드 202611110110 반영 완료)
- **검증 상태**: 한툴 1.28.0 설치본 UI/AX 검증 완료 (PID 24358, 아티팩트 해시 일치, 셸 명령·실제 다운로드/AI 전송은 본 작업에서 미수행)

## 1. 핵심 문제 진단 (소스 확인 사실)
1. **열린 페이지와 영상 목록의 단절 (`Views.swift:408-414`, `469-475`)**: `이 페이지의 영상`(`selectedTab = .pageVideos`)을 열면 `BrowserView`가 숨겨지고 단독 화면으로 대체되었던 문제.
2. **브라우저 이탈 시 진행 문맥 해제 (`BrowserView.swift:725-736`)**: `selectedTab`이 `.browser`를 벗어나면 `addressFlow.cancel()`과 `webPageAgent.teardown()`이 즉시 호출되었던 문제.
3. **툴바 즉시 분석과 후보 패널의 역할 충돌 (`BrowserView.swift:1250-1263`, `LoginWindow.swift:1630-1633`)**: 기존 툴바 버튼이 `model.analyzePage()`를 바로 호출해 즉시 추출·대기열 등록을 시작하던 문제.
4. **‘도구’ 잡동사니 서랍과 재클릭 초기화 (`UnifiedNavigation.swift:90-199`, `336-340`)**: 번역·입력·Mac 관리·웹 도구가 한 서랍에 섞여 있고, `도구`를 다시 누르면 작업 화면이 닫히던 문제.

## 2. 확정 전체 메뉴 트리 (상단 7개 + 하단 2개 = 총 9개)
모호한 `도구` 허브를 없애고 목적 공간 7개와 하단 시스템 메뉴 2개로 일관화했습니다. 비서는 브라우저 툴바의 전용 ‘비서’ 대화창 토글과 `설정 > AI 연결`(`AIServiceSettingsView`) 단일 마운트로 통합하여 중복 화면을 배제했습니다. 사이드바 스크롤 가능 구조와 기존 축소 레일(`CompactSidebarRail`, `Views.swift:629`)을 일관된 9개 메뉴로 보존합니다.

```text
[왼쪽 사이드바: 상단 목적 공간 7개]
1. 브라우저 (globe)               — 웹 탐색 · 툴바 `페이지 영상` 버튼(수동 영상 후보 패널 팝오버 토글, 즉시 다운로드는 `영상 찾아받기`) · 툴바 `비서` 대화창 스위치 · 속도 표시기
2. 다운로드 (arrow.down.circle)   — 링크 직접 입력/저장/완료 기록 (`진행 중` | `완료기록`, URL 다운로드 액션 라벨 `다운로드`)
3. 플래너 (checklist)             — 예약·다단계 자동화 작업 (`SAWView`, 백그라운드 호스트 유지)
4. 번역 (character.book.closed)   — 상단 세그먼트 [`메일·이미지 번역` | `화면 번역`] + 웹 설정 연동 버튼
5. 입력 도우미 (keyboard)         — 상단 세그먼트 [`앱별 언어 전환` | `한글 오타 교정` | `개인 사전` | `트랙패드 잠금`] + 입력 설정 버튼
6. Mac 관리 (desktopcomputer)     — 상단 세그먼트 [`Mac 관리` | `USB 드라이브 정리`] + Mac 관리 설정 버튼 (USB 정리 시 창 제목 HanTool 유지)
7. 서버 현황 (chart.bar.xaxis)    — 서버 상태 확인 (`serverStatus` 독립 유지)

[왼쪽 사이드바: 하단 시스템 및 안내 2개]
8. 설정 (gearshape)               — [`일반 설정` | `웹 설정`(`주소창·검색`, `번역 확장 연동`) | `AI 연결`(`AIServiceSettingsView`) | `입력 설정` | `Mac 관리 설정`] 5탭
9. 사용 안내 (questionmark.circle) — 시작 안내(`home`) 및 사용 도움말(`help`)
```

- **재클릭 보존**: 이미 선택된 사이드바 항목을 다시 눌러도 하위 탭·작업을 초기화하지 않습니다.
- **좁은 창 및 패널 규칙**: 브라우저 내 영상 후보는 기존 SwiftUI 팝오버(폭 340~360pt 제한, 바깥 클릭·`Esc` 닫기)를 사용해 좁은 창에서도 웹뷰와 `selectedTab == .browser`를 그대로 유지합니다.
- **AI 비서 및 연결 일원화**: 브라우저 상단 비서 대화창을 지원하며, AI 서비스 제공자 선택 및 온오프 설정은 `설정 > AI 연결` 단일 뷰에서 수행합니다 (기존 legacy `.ai` 진입 시에도 `설정 > AI 연결`로 매핑).

## 3. 기존 기능 및 호스트 경로 전수 매핑표
| 기능명 | 기존 식별자 (`hostedToolID` / `selectedTab`) | 개편 후 주 진입 경로 | `syncFromExternal` / `navigateTo` 동기화 규칙 |
| :--- | :--- | :--- | :--- |
| 웹 탐색 | `.browser` | `사이드바 > 브라우저` | `destination = .browser`, `clearTool()` |
| 이 페이지의 영상 | `.pageVideos` | **브라우저 툴바 `페이지 영상` 버튼 → 수동 후보 패널 토글** | `.pageVideos` 진입 시 `destination = .browser` 유지 + 브라우저 후보 팝오버 표시 |
| 외부 링크 다운로드 | `.queue`, `.history` | `사이드바 > 다운로드` (`진행 중` / `완료기록`) | `destination = .downloads`, 툴바·사이드바 `.urlDropTarget` 유지 (다운로드 액션 `다운로드`) |
| 플래너 | `.saw` | `사이드바 > 플래너` | `destination = .planner`, `SAWTeamBackgroundHosts` 상시 유지 |
| AI 비서 / AI 설정 | `.ai` | **브라우저 툴바 ‘비서’ 대화창 토글** 및 **`사이드바 > 설정 > AI 연결`** | `.ai` 진입 시 `destination = .settings`, `settingsTab = .aiConnections`로 단일 매핑 |
| 메일·이미지 / 화면 번역 | `"mail"`, `"screen"` | `사이드바 > 번역` (`메일·이미지 번역` / `화면 번역`) | `destination = .translation`, `activeTranslationChild` 보존 및 `selectTool` 호출 |
| 입력 도우미 4종 | `"input.appLanguage"`, `"input.koreanTypo"`, `"input.personalDictionary"`, `"input.trackpad"` | `사이드바 > 입력 도우미` (4개 세그먼트) | `destination = .inputHelper`, 마지막 선택 탭(기본 `input.appLanguage`) 유지 |
| Mac 관리 / USB 정리 | `"macManagement"`, `"cleanUSB"` | `사이드바 > Mac 관리` (2개 세그먼트) | `destination = .macManagement`, 마지막 선택 탭(기본 `macManagement`) 유지 |
| 서버 현황 | `"serverStatus"` | `사이드바 > 서버 현황` | `destination = .server`, `selectTool("serverStatus")` |
| 속도측정 | `.speed` | **브라우저 상단 속도 표시기(`NetworkRateIndicator`) → 속도측정 시트(`isSpeedTestPresented`)** | `.speed` 진입 시 `isSpeedTestPresented = true`, 브라우저 화면 위에 시트로 띄워 웹 탐색 문맥 유지 |
| 주소창·검색 설정 | `.addressSearch` | `사이드바 > 설정 > 웹 설정` 내 **`주소창·검색`** 섹션 | `.addressSearch` 호출 시 `destination = .settings`, `settingsTab = .webSettings` |
| 번역 확장 연동 | `"browser"` | `사이드바 > 설정 > 웹 설정` 내 **`번역 확장 연동`** 섹션 | `"browser"` 호스트 문자열 ID 유지, `번역` 상단 보조 버튼 및 `웹 설정`에서 연결 |
| 설정 5종 / 안내 | `"general"`, `.settings`, `"input.general"`, `"macManagementSettings"`, `"help"`, `"home"` | `사이드바 > 설정` / `사이드바 > 사용 안내` | 기존 호스트 문자열 ID 전수 유지, `"home"`·`"help"`는 `.help`로 매핑 |

## 4. 핵심 동작 및 경계 상태 명세 (검토 결함 반영 완료)
1. **패널 열기는 100% 수동·읽기 전용 (자동 분석·전송 금지)**:
   - 툴바 `페이지 영상` 버튼(`BrowserView.swift:1250`) 하나로 후보 패널을 여닫는 토글을 수행합니다(중복 `영상` 버튼 없음, `.urlDropTarget` 유지).
   - 패널을 여는 동작은 `model.analyzePage()`나 AI 전송을 **절대 자동 호출하지 않습니다**.
   - 즉시 추출 동작은 패널 내부의 명시적 **`영상 찾아받기`** 버튼으로 실행하고, 개별 항목은 **`MP4로 저장`**으로 실행합니다.
2. **활성 탭·URL 헤더 표시 및 이동 세대 가드 검증**:
   - 후보 패널 상단 헤더에 현재 활성 탭(`appModel.browser`)의 실제 제목과 URL(또는 호스트)을 표시합니다.
   - 탭별 `LoginBrowserModel` 바인딩과 `newDocument()`(`LoginWindow.swift:1405`, `generation += 1`, `candidates = []`) 및 `saveCandidate(_:)`의 세대 검증이 탭 전환·페이지 이동 시에도 정상 동작하여 이전 페이지 후보가 잘못 저장되지 않습니다.
3. **범위 외 신규 기능 추가 금지**:
   - 새로운 후보 캐시, 고정 기능, 스크롤 위치 영구 복원, 새 보호 영상 판별기, 새 분석 취소 함수, 새 브라우저 AI 패널은 추가하지 않고 기존 엔진 신호만 사용했습니다.
4. **주요 상태 표시**:
   - 열린 웹페이지가 없거나 시작 화면(`isShowingHome`)일 때는 안내를 표시하고 분석 버튼을 비활성화합니다.
   - 탐색 중, 후보 0개, 후보 발견(`MP4로 저장`), 기존 오류를 구분해 표시합니다.

## 5. 점진적 구현 결과 및 관찰 가능한 완료 기준
### 5.1 구현 및 설치 현황
- **슬라이스 1 (브라우저 내 수동 영상 후보 패널 연결)**: 반영 완료. 툴바 `페이지 영상` 버튼을 후보 패널 팝오버 토글로 변경하고(자동 `analyzePage` 호출 없음), `영상 찾아받기`와 `MP4로 저장`으로 분리했습니다.
- **슬라이스 2 (사이드바 7+2 개편 및 외부/호스트 라우팅 동기화)**: 반영 완료. `MainNavDestination` 9개 개편, `SidebarView`와 `CompactSidebarRail` 동기화, `설정 > AI 연결` 단일 뷰 통합 완료.
- **슬라이스 3 (웹 설정 섹션 통합 및 속도측정 시트 연결)**: 반영 완료. `설정 > 웹 설정` 구역 배치 및 `SpeedTestView` 시트 연결 완료.
- **최종 빌드·설치**: 한툴 1.28.0 (빌드 202611110110) 교체 설치 및 실행 완료 (PID 24358, 아티팩트 해시 일치).

### 5.2 검토 현황 및 완료 판정 기준 (2026-11-11 02:51 KST 기준)
1. **기획 검토**: Claude 2회, Gemini2 2회, 루트 TM 2회 및 AI 델타 검토 완료.
2. **최종 검토**: Gemini 1·2·3계정·Claude 각 2회 완료, 루트 TM 소스+설치본 UI/AX 2회 완료. 발견된 필수 문제를 수정한 뒤 최종 대조에서 필수 잔여 결함 0건. Claude 2차는 정적 소스 검토이며 설치본 UI 실증은 TM이 별도로 수행함.
3. **관찰 검증 기준**:
   - `페이지 영상` 버튼 클릭 시 자동 작업 등록 없이 후보 패널만 열리고 웹페이지 문맥 유지 (TM 2차 점검 통과).
   - 패널 안의 `영상 찾아받기` 또는 `MP4로 저장` 클릭 시에만 작업 생성. 다운로드 화면 액션 라벨 `다운로드` 제공.
   - 사이드바 및 축소 레일 9개 일관 노출 및 VoiceOver 선택 특성(selected traits) 정상 제공.
   - 900x700 4개 입력 탭, USB 정리 창 제목 'HanTool', passive 후보 목록/URL 헤더 보존 확인.
   - (제한 사항: 실제 파일 다운로드, AI 제출, 비호스트 독립 빌드는 검증하지 않음)
