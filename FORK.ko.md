# Chostty

[English](FORK.md) | 한국어

[Ghostty](https://github.com/ghostty-org/ghostty)를 바탕으로 만든 macOS 포크로, macOS
기본 창 탭 대신 창 안의 Workspace → Tab → Pane 계층을 왼쪽 사이드바에서 다룬다.
처음 볼 문서는 [README.ko.md](README.ko.md)이고 이 문서에는 무엇을 왜 바꿨는지를
적는다. 영어판 [FORK.md](FORK.md)가 기준 문서이며 둘이 다르면 영어판을 따른다.

## 라이선스

Ghostty는 MIT 라이선스다. 포크, 수정, 비공개 또는 상업적 재배포를 모두 허용하며
의무는 하나뿐이다. 모든 사본에 원래 저작권 고지와 허가 고지를 남겨야 한다.
`LICENSE`는 upstream 고지를 그대로 두고 그 아래에 이 포크의 줄을 더했다.

카피레프트 의무는 없다. 릴리스는 이 저장소에서 내보내므로 `LICENSE`는 번들 안과
소스 트리에 함께 들어간다.

## upstream과 다른 점

**창 모델.** upstream은 탭마다 `NSWindow`를 만들어 `NSWindowTabGroup`에 넣는다. 이
포크는 AppKit 탭을 아예 막고(`tabbingMode = .disallowed`) 물리 창 하나가 메모리
안에서 Workspace → Virtual Tab → Pane 그래프를 가진다. AppKit 네이티브 탭 코드는
우회만 한 게 아니라 지웠다. `macos/scripts/native-tab-audit.sh`는 이 코드가 다시
들어오면 실패하는 강제 검사다.

**macOS 제품 정체성만 바꿈.** 번들은 `Chostty.app`, 실행 파일은 `chostty`, 번들 ID는
`kr.co.devch.chostty`(Debug: `kr.co.devch.chostty.debug`)다. 0.2.15까지는
`com.chostty.app`을 썼다. 이름이 바뀐 앱은 처음 실행할 때 그 도메인의 환경설정과
저장된 세션을 한 번 복사하고 원본은 남겨 둔다. 그 전까지 Dock 타일 플러그인은 예전
도메인을 읽는다. 새 ID 아래에 이미 저장된 세션이 있으면 그쪽을 쓴다. 복사에
실패하면 완료로 기록하지 않고 다음 실행 때 다시 시도한다. 자동화나 알림 같은 macOS
개인정보 권한은 번들 ID 기준이라 다시 허용해야 한다. 사용자나 스크립트가 이미 기대는
이름은 일부러 그대로 둔다. `Ghostty` Swift 모듈, `GhosttyKit`, `GHOSTTY_*` 환경
변수, `xterm-ghostty` terminfo, `share/ghostty` 리소스 경로, `~/.config/ghostty/`,
모든 AppleScript four-char code, Linux/GTK의 `ghostty` 실행 파일 이름이 그렇다.

**업데이터.** 패키징한 정식 릴리스는 Sparkle을 켜고 이 저장소 최신 릴리스의
appcast와 업데이트 압축 파일을 Ed25519 공개키로 검증한다. 소스 빌드는 자동으로
확인하지 않는다. 패키징 빌드는 `auto-update`로 따로 정하지 않으면 자동으로 확인하며
0.2.12까지의 릴리스가 저장해 둔 `SUEnableAutomaticChecks = 0` 설정보다 이 동작이
앞선다. appcast는 릴리스 첨부 파일이라 이 저장소가 공개일 때만 Sparkle이 받아 올 수
있다. 개인키는 저장소 밖에 두며 패키징 전에 번들의 공개키와 짝이 맞아야 한다.
0.2.12까지의 릴리스는 한 번 직접 업그레이드해야 한다. 개인키를 잃어버려도 마찬가지로
새 공개키를 넣은 릴리스를 한 번 직접 설치해야 한다. upstream Ghostty의 appcast는
절대 쓰지 않는다. 쓰면 Chostty가 순정 Ghostty로 바뀐다.

**Files 패널 Reader.** 오른쪽 Files 패널에서 파일을 열면 선택한 Virtual Tab에 읽기
전용 문서 탭이 붙고 터미널 surface는 내려가지 않는다. Virtual Tab마다 열린 문서를
20개까지 따로 유지한다. 이미 열린 경로를 다시 열면 그 문서를 선택하고 `Esc`는
Reader를 숨기며 Reader가 활성일 때 `⌘W`는 선택한 문서만 닫는다. Markdown, 소스
텍스트, JSON/YAML/TOML/XML/property list, 이미지, 정적 HTML은 전용 뷰로 보여 주고
나머지 형식은 내장 Quick Look 미리보기로 연다. 정적 HTML은 JavaScript와 네트워크
리소스를 끈 채로 보여 준다. 열린 문서 탭은 앱을 다시 시작하면 일부러 복원하지 않는다.

**창 복원이 아니라 구조 저장.** Chostty는 여전히 `NSWindowRestoration` 클래스를
등록하지 않고 `NSQuitAlwaysKeepsWindows`도 false로 고정한다. AppKit 창 아카이브는
관여하지 않는다. 대신 앱이 자체 JSON 파일 하나를 관리한다.
`~/Library/Application Support/<bundle id>/session.json`과 바로 전에 검증된 스냅샷을
담은 `session-previous.json`이다. 여기에 워크스페이스, Virtual Tab, Pane의 이름, 색,
순서, 접힘 상태, 탭 제목, 탭별 분할 배치, Pane별 작업 디렉터리를 적어 두고 다음
실행 때 그 구조를 되살린다.

다시 시작하면 Pane마다 기록된 작업 디렉터리에서 **새 셸**이 뜬다. 예전 프로세스,
화면, 스크롤백은 남지 않으며 터미널 내용은 디스크에 전혀 쓰지 않는다. 기록된
디렉터리가 사라졌으면 홈 디렉터리로 몰래 바꾸지 않고 그 항목을 버린다. 이 포크에서
탭을 만드는 다른 경로와 같은 방식이다.

저장은 터미널 출력이 아니라 8초 타이머로 돈다. 세대 카운터를 보고 실제로 바뀐 게
있을 때만 저장한다. 인코딩한 바이트가 디스크의 파일과 같으면 아예 건너뛰므로 가만히
있는 창은 아무것도 쓰지 않는다. 정상 종료할 때는 한 번 더 동기적으로 쓰므로 잃는 게
없다. 크래시나 강제 종료 때는 최대 8초 분량의 구조 변경을 잃을 수 있다. 파일은
원자적으로 쓰고 권한은 소유자만(`0600`)이다.

백업은 실행에 성공한 뒤 처음 만든다. 그 뒤로는 변경을 저장하기 전마다 기존 주 파일이 불러오기와
같은 검사를 통과할 때에만 그 파일로 갱신한다. 그래서 주 파일이 망가졌을 때 돌아가는
지점은 아주 오래된 부팅 상태가 아니라 성공한 저장 한 번 전이다. 잘못된 주 파일 바이트가
백업을 덮어쓰는 일은 없다. 백업 쓰기에 실패하면 주 파일은 그대로 두고 저장을 실패로
처리해 다시 시도한다. 두 파일 모두 원자적으로 쓰고 소유자 전용 권한을 쓴다. 같은
내용을 저장하면 둘 다 건드리지 않는다.

파일은 실행 중인 Chostty 하나만 쓴다. 다른 실행 중인 Chostty(같은 번들 ID이고 살아
있음)가 파일을 쥐고 있으면 새로 뜬 쪽은 쓰지 않고 기다리다가 그 인스턴스가 끝나면
바로 저장을 이어 간다. 기록된 pid를 지금은 상관없는 프로세스가 쓰고 있다면 소유자로
치지 않는다. 사이드바의 **Check Sidebar Sync…** 시트는 소유 인스턴스를 보여 주고
**Take Over and Save**를 제공한다. 이걸 누르면 현재 창의 상태를 쓰고 이전 소유자는
다음 쓰기 전에 새 소유자를 확인한 뒤 쓰기를 멈춘다.

물리 창을 모두 닫아도 마지막 유효 스냅샷을 빈 스냅샷으로 바꾸지 않는다. 다른 창을
열지 않고 앱을 끝내면 다음 실행 때 비어 있지 않던 마지막 배치를 되살린다.

실행할 때 셸을 띄우는 탭은 선택된 워크스페이스의 선택된 탭 하나뿐이다. 나머지는
값으로만 다시 만들어 두었다가 처음 선택할 때 실제로 만든다. 탭 스무 개를 복원해도
터미널 스무 개가 한꺼번에 뜨지 않는 이유다.

이 기능을 모두 끄려면 `macos-session-persistence = false`로 설정한다. 한 번만 끄려면
`GHOSTTY_MAC_DISABLE_SESSION_RESTORE=1`을 export한다. 테스트 호스트와 명시적인 열기
의도가 있는 실행(`ghostty -e …`, `open --args`)에서도 저장 기능은 스스로 꺼진다.

`window-save-state`는 upstream에서 물려받아 여전히 파싱되지만 macOS 앱은 무시하고
늘 `never`처럼 동작한다. 위 동작을 정하는 키는 `macos-session-persistence`다.

## 예약 단축키

| 키                        | 동작                                     |
| ------------------------- | ---------------------------------------- |
| `⌘N`                      | 새 워크스페이스(같은 창)                 |
| `⌘T`                      | 새 Virtual Tab                           |
| `⌘⇧N`                     | 새 물리 창                               |
| `⌘1`–`⌘8`                 | 순서로 워크스페이스 이동                 |
| `⌘9`                      | 마지막 워크스페이스로 이동               |
| `⌘⇧[` / `⌘⇧]`             | 이전 / 다음 탭                           |
| `Ctrl+Tab` / `Ctrl+⇧+Tab` | 다음 / 이전 워크스페이스                 |
| `⌘⇧T`                     | 닫은 탭 다시 열기(실행 취소는 계속 `⌘Z`) |
| `⌘B`                      | 사이드바 열고 닫기                       |

문자가 아니라 하드웨어 키 코드로 맞추므로 라틴 문자가 아닌 입력 소스에서도 똑같이
동작한다. `⌘⌥` 화살표와 그냥 `⌘[` / `⌘]`는 일부러 가져가지 않았다. upstream에서
실제로 쓰는 `goto_split` 바인딩이기 때문이다.

## 워크스페이스 컨트롤

사이드바 토글과 워크스페이스 동작 메뉴는 제목 표시줄의 신호등 버튼 바로 오른쪽에
있다. 워크스페이스 만들기와 지금 사이드바 그래프가 저장된 세션과 맞는지 확인하기가
이 메뉴에 들어 있다. 예전에는 사이드바 헤더에 있었는데 사이드바를 닫으면 다시 여는
버튼까지 사라져 `⌘B` 말고는 돌아올 길이 없었다.

컨트롤을 둘 제목 표시줄이 없는 창에서는 같은 컨트롤을 창 내용 위쪽, 창 제목 옆에
띠 형태로 그린다. 전체 화면(네이티브는 제목 표시줄을 자동으로 숨는 오버레이로 옮기고
비네이티브는 없앰)과 `window-decorations = false`가 여기에 해당한다. 두 종류의 창은
대신 사이드바 헤더에 컨트롤을 둔다. 제목 표시줄도 띠를 둘 자리도 없는 테두리 없는
패널인 quick terminal, 그리고 띠를 그리면 이 설정이 없애려던 창 장식을 되돌려 놓게 되는
`macos-titlebar-style = hidden`이다.

판단은 전부 `WorkspaceControlsPlacement.forStandaloneWindow`에서 하고
`WorkspaceControlsPlacementTests`가 경우의 수를 모두 검사한다.

## 빌드

```sh
zig build -Doptimize=ReleaseFast -Demit-macos-app=false   # GhosttyKit 갱신
./macos/build.nu --configuration Release --action build
```

테스트와 네이티브 탭 검사:

```sh
./macos/build.nu --configuration Debug --action build
xattr -cr macos/build/Debug/Chostty.app
./macos/build.nu --configuration Debug --action test
./macos/scripts/native-tab-audit.sh
```

테스트 전에 `xattr -cr`을 꼭 실행해야 한다. 앱을 실행하면 확장 속성이 다시 붙어
테스트 호스트의 codesign 단계가 실패한다. 로컬에서는 한 번에 다 돌리지 말고
`-only-testing:`으로 나눠 돌린다. 컨트롤러를 만드는 테스트마다 살아 있는 터미널
surface가 남고 이게 쌓이면 테스트 호스트가 멈춘다. 정확한 명령은 `AGENTS.md`에 있다.

## 릴리스

릴리스는 로컬에서 만든다. 서명 인증서, 공증 프로필, Sparkle 개인키가 로컬에 있고
PR CI를 이미 통과한 코드를 hosted macOS 시간을 들여 다시 빌드할 이유가 없다.

```sh
./scripts/release-local.sh --version <semver>
```

이 명령은 ReleaseFast universal GhosttyKit을 빌드하고 Release 구성으로 Chostty를
빌드한 뒤 `macos/scripts/package-release.sh`로 앱에 버전을 찍고 서명해서
`dist-local/`에 패키징한다. 이어서 번들 서명과 DMG를 검증하고 SHA-256 체크섬을
남긴다. `CHOSTTY_SIGNING_IDENTITY`와 `CHOSTTY_NOTARY_PROFILE`을 둘 다 export하지
않으면 ad-hoc 서명이다. 둘 다 있으면 앱과 DMG를 Developer ID로 서명하고 공증받아
staple한다.

같은 명령으로 현재 `origin/main` 커밋에 태그를 달고 DMG와 zip을 GitHub Releases에
올리려면 다음과 같이 한다.

```sh
./scripts/release-local.sh --version <semver> --publish
```

병합 후 보통 쓰는 방법은 더 짧다.

```sh
./scripts/release-local.sh --publish-next
```

추적 중인 파일에 변경이 없어야 한다. `main`으로 전환해 `origin/main`까지
fast-forward한 뒤 GitHub 최신 정식 릴리스의 patch 번호를 하나 올려 같은 빌드·배포
절차를 밟는다. 최신 릴리스 이후 `origin/main`에 커밋이 없거나 앱·패키징 입력이
바뀌지 않았으면 배포를 거부한다. 문서나 릴리스 도구만 바뀐 병합으로 빈 앱 버전이
나가지 않게 하려는 것이다.

배포는 추적 파일에 변경이 있거나, 커밋이 `origin/main`이 아니거나, 버전이 커지지
않았거나, ad-hoc 서명이거나, 태그나 릴리스가 이미 있으면 거부한다. 패키징 스크립트는
피드 URL, Sparkle 공개키·개인키 짝, 서명된 appcast, universal 바이너리도 확인한다.

Chostty 버전은 Ghostty와 따로 간다. 1.0.0이 Chostty의 첫 정식 릴리스이고
`--publish-next`는 거기서 patch를 올린다. minor나 major를 올릴 때는 `--version`을
직접 준다. upstream의 `vX.Y.Z` 태그와 이름 공간이 같으므로
`scripts/upstream-sync.sh`는 `--no-tags`로 fetch한다. 이미 upstream 태그를 받아 둔
체크아웃에서는 겹치는 버전을 배포할 때 "already points at another commit"으로
거부한다. 그 로컬 upstream 태그를 지우고(`git tag -d vX.Y.Z`) 다시 배포하면 된다.

`.github/workflows/release.yml`은 수동 실행용 예비 경로로 남아 있으며 배포는 하지
않는다. 내려받을 수 있는 워크플로 결과물은 만들지만 태그나 GitHub 릴리스는 만들지
않고 CI 뒤에 자동으로 돌지도 않는다.

자격 증명 없는 빌드(CI, 로컬 테스트 패키징)를 재현할 수 있도록 기본 서명은 ad-hoc이다.
배포용 릴리스에서는 `release-local.sh`를 돌리기 전에 `CHOSTTY_SIGNING_IDENTITY`
("Developer ID Application: …" 인증서)와 `CHOSTTY_NOTARY_PROFILE`
(`xcrun notarytool store-credentials`로 저장한 프로필)을 export한다. 아니면 저장소
루트의 gitignore된 `.release-env`에 한 번 적어 두면 `release-local.sh`가 읽어 들인다.
그러면 앱을 hardened runtime과 보안 타임스탬프로 서명하고 공증받아 staple한다.
staple한 앱으로 zip을 다시 만들고 DMG도 서명·공증·staple한다. `package-release.sh`는
공증 프로필 없이 Developer ID 인증서만 주면 거부한다. 이 조합은 Gatekeeper가 ad-hoc
빌드보다 더 강하게 막기 때문이다. 공증된 빌드라면 GitHub 릴리스 노트에서 `xattr -cr`
안내가 자동으로 빠진다. ad-hoc 결과물은 내려받으면 quarantine이 걸린다. 파일이
깨진 것처럼 보이지 않도록 릴리스 노트에 그 사실을 적는다.

`.github/workflows/ci.yml`은 모든 PR에서 shellcheck와 감사 스크립트를 돌린다. PR이
macOS 빌드 입력을 바꿨을 때만 Zig 코어 빌드와 macOS 테스트를 돌린다. UI 테스트는
`macos/build.nu`와 같은 이유로 건너뛴다. 어떤 CI 러너도 손쉬운 사용 권한을 주지 않는다.

CI에만 있는 양보가 두 가지 더 있다. 둘 다 코드가 아니라 hosted 러너 사정이다.
테스트는 순서대로 돈다. 많은 suite가 창과 Metal surface를 가진 실제
`TerminalController`를 세운다. 동시에 돌리면 테스트 호스트가 중간에 끝나고
xcodebuild는 끝나지 않은 테스트를 모두 실패로 보고한다. 그리고
`reopenAfterForcedFinalizeCreatesFreshTabWithRecordedMetadata`는 이름으로 지정해
건너뛴다. lease를 마무리한 뒤 새 live surface를 만드는 유일한 경우로, 러너에서는 호스트
프로세스가 죽는다. 로컬에서는 통과하며 로컬 전체 테스트가 여전히 기준이다. CI 통과는
필요조건일 뿐 충분조건이 아니다.

## 검증

모든 변경에서 테스트와 `macos/scripts/native-tab-audit.sh`를 돌린다. 이 테스트
타깃에서 SwiftUI를 호스팅하면 XCTest 러너가 멈추므로 몇 가지 경로는 손으로 확인한다.
아래 항목은 모두 macOS 26 / Apple silicon에서 직접 해 보고 통과했다.

- 네이티브와 비네이티브 전체 화면 진입·종료, 탭 하나일 때와 넷일 때.
- 탭 스무 개가 그려지고 스크롤되며 `Cmd+Shift+]`로 마지막 탭이 화면에 들어온다.
- 사이드바 빈 곳을 오른쪽 클릭하면 워크스페이스 메뉴가 열린다.
- 세 가지 호스트 모두에서 워크스페이스 컨트롤이 동작하며 네이티브 전체 화면 전환도
  포함한다. `GhosttyWorkspaceControlsUITests`가 실제 앱을 움직여 누를 수 있는지
  확인하고 전체 화면에서는 띠의 워크스페이스 메뉴 항목이 워크스페이스를 만드는지
  확인한다. 처음 만든 accessory는 배치는 됐지만 폭이 0으로 잘렸는데 존재만 확인하는
  검사는 그걸 통과시켰다.

호스팅이 불가능한 곳에서는 관찰한 레이아웃 대신 배포되는 소스 텍스트를 고정해 확인하는
검사도 있다. 이런 검사는 먼저 주석과 공백을 걸러 낸다. 각 검사는 실제 결함에서는 실패하고
겉모양만 바꾼 재정렬에서는 통과하는지 확인했다. 예전 버전은 실제 프레임이 하드코딩된
상태에서도 문서 주석 때문에 통과했다.

## 앱 아이콘

Ghostty 아이콘은 쓰지 않는다. 앱 아이콘(`images/Chostty.icon`), 대체 아이콘 여덟 개,
`macos-icon = custom-style`이 합성하는 사용자 지정 아이콘 레이어, Linux와 Windows
아이콘 파일을 모두 `macos/scripts/generate-icons.py`가 그린다. 워크스페이스
사이드바, 분할된 Pane, `>_` 프롬프트가 있는 창 모양이다. PNG를 직접 고치지 말고
스크립트를 고쳐 다시 실행한다.

    python3 macos/scripts/generate-icons.py

Pillow가 필요하다. `macos-icon` 값과 Swift asset 이름(`CustomIconGhost` 등)은 기존
설정이 그대로 동작하도록 upstream 철자를 유지하고 그림만 바꿨다.

## 알려진 한계

- `new tab`은 `in` 매개변수가 있을 때만 처리된다. `new tab in window 1`과
  `new tab in front window`는 되지만 `new tab`만 쓰면 errAEEventNotHandled(-1708)로
  실패한다. `in` 없는 `new tab with configuration …`도 마찬가지다. 자동화가 불안정해서가
  아니다. 앱을 맨 앞에 두고 raw `«event GhstNTab»`을 보내도 똑같이 실패하고 upstream
  Ghostty도 똑같으니 새로 생긴 문제가 아니라 물려받은 문제다. `new window`는 `in`을
  받지 않고 매개변수 없이도 잘 된다. 고치려면 dictionary를 바꿔야 하는데 dictionary는
  일부러 고정해 두었으므로 그대로 둔다. `in front window`를 붙여 쓴다.
- Collapse All, Expand All, 단일 워크스페이스 정책 토글은 메뉴에서만 쓸 수 있고 명령
  팔레트에는 없다. 팔레트는 Ghostty 설정에서 만들어지며 앱 자체 명령을 넣을 곳이 없다.
- 소스를 고정한 검사는 modifier가 지워지거나 옮겨진 경우는 잡지만 옆에 하나 더 붙은
  경우는 잡지 못한다.

## 개발할 때

빌드 디렉터리에는 설치된 앱과 번들 ID가 같은 `Chostty.app` 사본이 있다. Xcode는 빌드
마지막 단계(`RegisterWithLaunchServices` → `lsregister -f -R -trusted`)에서 매번 이
사본을 LaunchServices에 등록한다. 그 뒤로는 `tell application "Chostty"`와
`tell application id "kr.co.devch.chostty"`가 실행 중이지 않은 사본을 가리켜
`AESendMessage`에서 끝없이 멈출 수 있다. 앱이 멈춘 것처럼 보이지만 실제로는 메인
스레드가 놀고 있다.

등록을 해제하면 다음 빌드가 다시 등록하기 전까지는 풀린다. 그러니 한 번 해 두지 말고
스크립트 작업 바로 전에 매번 한다.

    lsregister -u "$PWD/macos/build/Release/Chostty.app"

`lsregister`는
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support`에
있다. `tell application "/Applications/Chostty.app"`처럼 경로로 지정하면 이 혼동을
피할 수 있고 두 가지 실패를 빨리 구분하는 데도 쓸 수 있다.
