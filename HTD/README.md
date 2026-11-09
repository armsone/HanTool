# HTD (HttpsDownroad) macOS 0.5.1 (로컬 개발용 앱)

> **"주소를 넣고, 편하게 저장"**
> 실패한 다운로드를 성공으로 속이지 않고, 고른 영상을 안전하게 저장하는 macOS 14+ 네이티브(SwiftUI) 앱입니다.

이 빌드는 **로컬 개발용**입니다. 이 Mac에 이미 설치된 Homebrew `yt-dlp 2026.10.21` / FFmpeg / ffprobe / Deno 스택을 그대로 사용하며,
이동 가능한(portable) 배포본·서명·공증·샌드박스 배포가 아닙니다. 엔진을 자동 설치하거나 자동 업데이트하지 않습니다.

## 구현 범위

| 기능 | 상태 |
| --- | --- |
| 주소 분석 → 화질/자막 선택 → 다운로드 → 검증 → 배타적 저장 | 0.1.0 구현·검증 |
| 대기열(동시 1개)·일시정지(처음부터 재시작)·취소·재시작 복구·기록·자막만 다시 받기 | 0.1.0 구현·검증 |
| DASH VOD 다운로드 (고정 조각 목록 완전성 근거) | 0.2.0 구현 — 사용자 수동 확인 전 |
| 실시간 방송 녹화 ("녹화 시작" / "녹화 마치고 저장" / 시간 제한) | 0.2.0 구현 — 사용자 수동 확인 전 |
| 전용 로그인 창 (앱 전용 비영구 WebKit 세션, 사이트 범위 쿠키 전달) | 0.2.0 구현 — 사용자 수동 확인 전 |
| 연결 도움 (앱 전용 인증 루프백 CONNECT 프록시, 실험적 TLS 첫 레코드 나눔) | 0.2.0 구현 — 사용자 수동 확인 전 |
| 영상 결과를 실제 MP4로 저장 (일반 다운로드·녹화 구간) | 0.2.1 구현 — 빌드·사용자 수동 확인 전 |
| 브라우저 주소창·링크 드래그 앤 드롭 즉시 등록 | 0.5.1 구현 |

0.2.0 기능은 빌드(컴파일·패키징)까지만 확인했고, 실행 동작은 아직 확인하지 않았습니다.

- **MP4 저장 (0.2.1, `Engine/mp4.py`)**: 영상이 포함된 결과는 원본 선택·완전성·전체 디코딩 검증을 마친 뒤 앱 소유 FFmpeg(로컬 파일만)로
  새 `.mp4`를 만듭니다. MP4에 담을 수 있는 코덱(H.264·HEVC·AV1 / AAC·MP3·AC-3·E-AC-3·FLAC·ALAC)은 스트림 복사, 담을 수 없는 트랙(VP9·VP8·Opus·Vorbis 등)만
  H.264(CRF 18)/AAC 192kbps로 재인코딩하며 진행 문구에 이유·경과·남은 시간을 표시합니다. 결과는 트랙 구성·코덱·해상도·길이 대조와 전체 디코딩을 다시 통과해야 게시됩니다.
  원본 파일은 작업 폴더에 그대로 남고, 음원 전용 다운로드·자막만 다시 받기는 바뀌지 않으며 기존 기록 파일은 변환하지 않습니다.

## 0.5.1 (빌드 7) 추가 기능 요약

- **브라우저 주소창 및 링크 드래그 앤 드롭 즉시 등록** (`URLDrop.swift`, `AppModel.addJobs`, `Views.swift`):
  외부 브라우저(Safari, Chrome, Whale 등)의 주소창 아이콘이나 웹페이지 안의 하이퍼링크를 앱 창(상단 헤더 주소창, 좌측 사이드바, 대기열/완료/설정 화면)으로
  끌어다 놓으면 즉시 작업으로 등록되어 영상 정보 분석을 시작합니다.
  - **검증 및 거부**: `http://`, `https://` 주소만 허용하며 호스트가 필수입니다. `file://`, `javascript:`, `data:`, 일반 파일·이미지, 자격 증명(`user:pass@`)이 포함된 링크, 일반 문장/문단 텍스트는 안전하게 거부합니다. 링크 메타데이터(title)를 주소로 신뢰하지 않습니다.
  - **다중/중복 처리**: 단일 링크는 물론 최대 10개까지의 복수 링크 드래그를 지원하며, 동일 드래그 페이로드 내 URL 및 텍스트 중복 표현은 1회만 등록합니다.
  - **비간섭 네이티브 UI**: 브라우저 탭의 WKWebView에는 투명 오버레이를 씌우지 않아 웹페이지 자체 조작 및 드래그가 정상 작동하며, 드래그 호버 시 절제된 테마 윤곽선 및 접근성 레이블을 제공하고 거부된 항목은 모달 팝업 대신 상단 슬림 비모달 안내로 처리합니다.

## 0.5.0 (빌드 6) 추가 기능 요약

- **추가 다운로드 서버 자동 허용** (`AppModel.startAutoRecovery/autoRecoveryVerdict`): 연결 도움을 켠 다운로드 작업이 그 작업 실행 태그로
  `not_allowed` 차단된 정확한 호스트 이름 때문에 보통의 엔진 오류로 끝나면, 그 호스트만 허용 → `policyApplied` 확인 → 같은 작업을 새 세대로
  다시 시도합니다(카드 문구 '추가 서버 연결을 허용하고 자동으로 다시 시도하는 중...', 실패로 표시하지 않음). 사용자 시도 하나당 최대 3회·
  추가 서버 8개(자동 재시도로 초기화되지 않음, 사용자의 다시 시도·재개·선택에서만 초기화). 새 호스트 없음·사설망/포트/DNS/연결 실패 섞임·
  로그인/권한·서버 오류·비정상 종료·가려진 주소·도우미 변경/꺼짐·한도 초과면 멈추고 기존 '허용 후 다시 시도'와 이유를 보여 줍니다.
  취소·일시 정지·삭제·종료가 늦은 확인보다 우선합니다. 브라우저·하위 자원 차단은 자동 허용하지 않습니다.
- **속도 측정** (`SpeedTestView.swift`, `Engine/speed.py`): 첫 화면 주소창 옆 '속도 측정' 버튼이 작은 창을 열고 바로 측정합니다. Cloudflare
  공개 측정 주소(`speed.cloudflare.com/__down`, `/__up`)로 HTTP 응답 시간(중앙값, ICMP ping 아님)·다운로드·업로드 Mbps를 간이·실효 측정하며,
  약 25초·요청 합계 최대 24MiB로 제한합니다. 현재 연결 방식 그대로(꺼짐 → 직접, 켜짐 → 도우미 경유 + `speed.cloudflare.com`만 허용, 직접 연결로
  바꾸지 않음). 측정 중에는 대기열이 기다리고 연결 방식은 바꿀 수 없으며, 창을 닫거나 취소하면 측정 프로세스만 멈춥니다. 실패·미측정 값은
  0이 아니라 '알 수 없음'으로 표시합니다.

## 0.4.0 추가 기능 요약

- **HTTPS 연결 도움 스위치 하나** (`Views.swift: ConnectionHelpSwitch`, `ConnectionManager.swift`): 모든 탭 맨 위에 있는 스위치 하나가
  앱 전용 프록시와 첫 TLS 메시지(ClientHello) 나눠 보내기를 함께 켜고 끕니다(따로 켜는 옵션 없음). 옆에 꺼짐/준비 중/사용 중/오류를 표시하며,
  연결 도움이 나눠 보내기를 확인하기 전에는 '사용 중'이 되지 않고 프록시만 단독으로 쓰지 않습니다. 선택은 다음 실행에도 기억되며(처음엔 꺼짐,
  이전 '나눠 보내기' 선택은 한 번 이 스위치로 옮김), 격리 실행(`HTTPSDOWN_APP_SUPPORT_DIR`)은 환경설정을 읽거나 쓰지 않습니다.
- **'허용 후 다시 시도'** (`AppModel.allowBlockedAndRetry`, `LoginBrowserModel.allowBlockedAndReload`): 작업·브라우저 연결마다 프록시 사용자
  태그를 달아 차단 기록을 그 작업 실행(또는 현재 페이지)에만 묶습니다. 실패 카드와 브라우저에 막힌 주소와 이유를 보여 주고, 버튼은 적힌
  주소(아직 허용하지 않은 정확한 호스트 이름, 최대 8개)만 허용 → 적용 확인(`policyApplied`) → 같은 작업 재시도/페이지 새로 고침을 합니다.
  사설 주소·포트·DNS·연결 실패·IP 주소에는 허용 버튼이 없습니다. 사이트 전체·와일드카드 허용 없음.
- **연결 안정성** (`Engine/connection.py`): 이미 검사한 주소만 IPv6/IPv4를 번갈아 250ms 간격으로 최대 6개 동시 시도하고 먼저 연결된 것을
  쓰며(전체 15초 제한, 나머지 소켓 모두 닫음), 첫 TLS 레코드 읽기는 실제 5초 마감으로 묶고 시간 초과·형식 불일치 때는 받은 바이트를 그대로
  전달합니다(설정 및 진단에 이유 표시). 모든 사이트의 접속을 보장하지는 않습니다.

## 0.3.0 추가 기능 요약

- **브라우저 탭** (`BrowserView.swift`, `LoginWindow.swift`, `MediaDiscovery.swift`, `Resources/MediaDiscovery.js`): 기존 전용 로그인
  세션·연결 도움 경로를 그대로 쓰는 앱 안 브라우저. 영상을 재생하면 오른쪽 '이 페이지의 영상' 목록에 후보가 나타나고 'MP4로 저장'을 누르면
  기존 분석→선택→검증→MP4 흐름으로 받습니다(페이지 Referer와 영상 사이트 쿠키만 메모리로 전달). 목록이 비면 '현재 페이지 분석'.
  연결 도움을 바꾸면 브라우저가 새 세션으로 다시 열리고 로그인이 지워집니다. 대상 점검: `/usr/bin/python3 validation/browser-smoke.py`.

## 0.2.0 추가 기능 요약

- **DASH VOD**: yt-dlp 네이티브 `http_dash_segments`만 인정합니다. 고정(비실시간·비생성형) 조각 목록 N개(초기화 조각이 있으면 첫 항목),
  조각 1..N이 순서대로 정확히 한 번씩 이어붙음, 다운로더 집계 N, 이어붙인 바이트 = 구성 파일 크기가 모두 맞아야 완전성 근거가 됩니다.
  영상/음성은 각각 받은 뒤 FFmpeg로 병합하고, 기존 선택 대조·after_move·검증·배타 게시를 그대로 거칩니다. DRM 형식은 목록에서 제외하고
  전부 DRM이면 그 사실을 알립니다. 실패한 조각은 건너뛰지 않고 실패로 끝납니다(`Engine/engine.py: _install_dash_probe, assess_completeness`).
- **실시간 녹화** (`Engine/live.py`): 분석 결과의 `isLive/liveStatus`를 VOD와 따로 저장합니다. yt-dlp로 승인된 형식을 다시 확인한 뒤
  앱 소유 FFmpeg가 HLS/DASH를 그대로 복사합니다. "녹화 마치고 저장"은 엔진 리더에만 SIGUSR1을 보내 FFmpeg에 `q`를 전달하는 협조적 종료이며
  취소와 별개입니다(취소는 그룹 종료, 저장 안 함). 시간 제한(기본 30분, 10분~12시간)은 FFmpeg `-t`로 끝냅니다. FFmpeg 오류·비정상 종료·
  조각 수신 오류·방송 측 종료 표시 없는 끊김은 완료로 처리하지 않습니다. 저장 결과는 "녹화 구간 저장"과 녹화 길이로 표시하며 원본 방송 전체가 아닙니다.
- **전용 로그인** (`LoginWindow.swift`, `SessionManager.swift`, `Engine/session.py`): http/https만 여는 앱 전용 창, 비영구 데이터 저장소
  (앱 종료 시 사라짐), 사용자가 직접 로그인. 작업에는 그 작업 주소의 사이트 쿠키만 stdin으로 전달되어 yt-dlp 메모리 CookieJar에 들어가며
  host-only·Domain·Path·Secure·만료를 `DefaultCookiePolicy(DomainStrictNonDomain)`로 지킵니다. partitioned 쿠키는 제외합니다. 전역 Cookie/Authorization 헤더 없음.
- **연결 도움** (`ConnectionManager.swift`, `Engine/connection.py`): 설정에서 켜면 127.0.0.1 임의 포트, 세션 무작위 자격증명(407 챌린지),
  CONNECT 전용(평문 http는 501과 이유 표시), 호스트 이름·포트 검사, 해석된 모든 주소가 공인 IP일 때만 그 주소로 연결합니다.
  사용자가 연 사이트 + 알려진 의존 도메인만 허용하고 나머지는 "차단된 연결"에 이유와 함께 보여 주며 이번 세션 동안 허용할 수 있습니다.
  엔진은 명시적 프록시 URL, 로그인 창은 `WKWebsiteDataStore.proxyConfigurations`(failover 끔)로 연결하며 직접 연결로 조용히 빠지지 않습니다.
  인증서 검증 해제·가로채기·시스템 프록시/VPN 변경은 없습니다. 진행 중인 작업이 있으면 모드를 바꿀 수 없습니다.

## 핵심 동작 계약 (코드 위치)

- **성공 판정**: 엔진의 `verified` 이벤트 하나로는 성공이 아닙니다. *프로세스가 취소되지 않았고 + 종료 코드 0 + 소유 그룹 핸드셰이크 +
  프로세스 그룹 정리 + 파이프 EOF + 작업 폴더 안의 실제 일반 파일 매니페스트*가 모두 맞아야 게시 단계로 넘어갑니다 (`AppModel.handleExit`).
- **가짜/손상 파일 거부** (`Engine/engine.py: verify_media_file`): 헤더 분류(GIF/JPEG/PNG/WebP/TIFF/PDF/ZIP/HTML/XML/JSON/텍스트) →
  제한된 로컬 ffprobe(`file:` 프로토콜만) → 컨테이너가 이미지 형식이면 거부 → 선택 의도(영상/음원) 트랙·코덱·해상도 대조 →
  **전체 디코딩**(`-xerror`, 일부 샘플 아님). 길이·크기 하한이나 음성 필수 조건은 없어서 0.2초 무음 영상도 저장됩니다.
- **전송 완전성 근거** (`assess_completeness`): HTTP는 `Content-Length`(identity 인코딩) = 수신 바이트 = 디스크 바이트일 때만,
  HLS는 네이티브 다운로더가 읽은 목록에 `#EXT-X-ENDLIST`가 있고 모든 조각이 끝났을 때만, DASH는 위의 고정 조각 목록 근거가 모두 맞을 때만 인정합니다.
  그 밖(길이 모름/chunked, ffmpeg 위임 VOD)은 `verificationIncomplete`로 **저장하지 않습니다**. 실시간 방송은 별도의 녹화 흐름을 씁니다.
- **선택 변경 차단**: yt-dlp `match_filter`가 `incomplete is False`일 때 형식 구성(membership)·해상도·가로·영상/오디오 코덱·전송 방식·추출기·미디어 ID를
  선택 시점 값과 대조하고, 달라지면 미디어 GET 전에 `selectionChanged`를 냅니다(문자열 반환은 exit 0이므로 별도 상태로 처리).
  형식이 사라지면 다른 형식으로 대체하지 않고 같은 상태로 차단합니다. 최종 경로는 `after_move` 후처리 훅에서 받으며 디렉터리 glob은 쓰지 않습니다.
- **프로세스 그룹** (`EngineBridge.swift`): `posix_spawn(POSIX_SPAWN_SETPGROUP)`으로 엔진이 스폰 순간부터 자기 그룹 리더가 되고,
  엔진의 `ready` 이벤트(pid==pgid)로 소유를 확인합니다. 리더는 한 곳에서만 `waitpid`로 회수하며, 리더 종료 후에도 그룹 전체를
  TERM→KILL로 비워(`kill(-pgid,0)==ESRCH`) 고아 자식을 남기지 않습니다. stdout/stderr는 EOF까지 동시에 비우고 줄·보관 상한을 둡니다.
  앱 종료 시 `terminateAll`, 앱이 강제 종료되면 엔진의 부모 감시 스레드가 그룹을 종료합니다. 이전 작업의 그룹이 정리되기 전에는 다음 작업을 시작하지 않습니다.
- **게시** (`Publisher.swift`): 작업 폴더 안의 소유한 단일 링크 일반 파일만 허용(심볼릭/하드링크/밖의 경로 거부), `renameatx_np(RENAME_EXCL)` +
  디렉터리 fd로 덮어쓰기 없이 `(1)`, `(2)` 번호 부여, 다른 볼륨(EXDEV)이면 대상 볼륨 스테이징 복사 → 크기·SHA-256 재검증 → 배타 이름 변경.
  게시 의도를 먼저 저널(`.publish-journal.json`)에 기록해 앱이 중간에 죽어도 재시작 때 실제 확정 여부를 대조합니다. 취소와 확정은 `PublishControl`로 직렬화되어
  이미 확정된 파일은 취소로 되돌리지 않습니다. 블로킹 복사는 메인 액터 밖에서 실행됩니다. 실패해도 원본·유효한 부분 파일·사용자의 기존 파일은 지우지 않습니다.
- **개인정보**: 저장되는 작업 기록에는 원본 주소의 쿼리/사용자 정보/불투명 경로 토큰이 들어가지 않고(원본은 실행 중에만 보관), 엔진 이벤트는 필요한
  메타데이터만 보내며 모든 오류 문구는 URL을 호스트만 남기도록 가립니다. 요청(주소·선택 사양)은 argv가 아니라 stdin으로 전달합니다.
  재시작 후 가려진 주소로 다시 받기를 시도하지 않고 주소를 새로 입력하도록 안내합니다. 개인 브라우저 쿠키/키체인은 사용하지 않습니다.

## 프로젝트 구조

```text
Package.swift                 SwiftPM 정의 (macOS 14)
Sources/HttpsDown/            HttpsDownApp, Models, AppModel, EngineBridge, Publisher, Views,
                              ConnectionManager, SessionManager, LoginWindow, BrowserView, MediaDiscovery, URLDrop
Resources/MediaDiscovery.js   브라우저 영상 찾기 스크립트 (격리 content world)
Engine/engine.py              yt-dlp/FFmpeg 오케스트레이션 (JSON-lines 이벤트)
Engine/connection.py          연결 도움 루프백 CONNECT 프록시 (engine.py proxy)
Engine/session.py             로그인 세션 쿠키 → yt-dlp 메모리 CookieJar
Engine/live.py                실시간 녹화 (engine.py record)
Resources/Info.plist
scripts/dev.py                빌드 + dist/HTD.app 패키징 + 빌드 해시 기록
scripts/verify.py             이번 검증 전용 재현 하니스 (일반 CI 아님)
validation/                   검증 고정물(probe/main.swift 등), 격리된 앱 상태·저장 폴더, evidence/
docs/                         implementation-status.md, verification.json / verification.md
```

## 빌드

```bash
/usr/bin/python3 scripts/dev.py build      # dist/HTD.app (ad-hoc 서명, 로컬 개발용)
```

## 검증

```bash
/usr/bin/python3 scripts/verify.py --core      # 전 그룹 1회 실행 → docs/verification.json / .md
/usr/bin/python3 scripts/verify.py --failed    # 이전 결과의 실패 그룹만 재실행 (실패 증거는 validation/evidence/에 보존)
/usr/bin/python3 scripts/verify.py serve       # 네이티브 UI 점검용 loopback 픽스처 서버 (사람이 직접 실행)
/usr/bin/python3 validation/browser-smoke.py   # 브라우저·자동 추가 서버 허용·속도 측정 대기열 잠금 (공개 CC0 + Cloudflare)
/usr/bin/python3 validation/speed-check.py     # 속도 측정 엔진: 계산·한도·잘림/리디렉션(로컬) + 도우미 경유 실측 1회(≤24MiB)
```

`serve`가 출력하는 환경 변수(`HTTPSDOWN_APP_SUPPORT_DIR`, `HTTPSDOWN_DEFAULT_DESTINATION`, `XDG_CONFIG_HOME`)로 앱을 실행하면 실제 기록·Downloads를 건드리지 않고
검증용 가짜 추출기(loopback 전용)로 UI를 점검할 수 있습니다. 환경 변수를 주지 않으면 앱의 동작은 기본 경로(`~/Library/Application Support/HttpsDown`, `~/Downloads`)를 씁니다.
