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
SSH 호스트 관리자는 이 고정 호환 목록이나 Ghostty의 표준 설정 경로를 바꾸지
않는다.

**업데이터.** 패키징한 정식 릴리스는 Sparkle을 켜고 이 저장소 최신 릴리스의
appcast와 업데이트 압축 파일을 Ed25519 공개키로 검증한다. 소스 빌드는 자동으로
확인하지 않는다. 패키징 빌드는 `auto-update`로 따로 정하지 않으면 자동으로 확인하며
0.2.12까지의 릴리스가 저장해 둔 `SUEnableAutomaticChecks = 0` 설정보다 이 동작이
앞선다. appcast는 릴리스 첨부 파일이라 이 저장소가 공개일 때만 Sparkle이 받아 올 수
있다. 개인키는 저장소 밖에 두며 패키징 전에 번들의 공개키와 짝이 맞아야 한다.
0.2.12까지의 릴리스는 한 번 직접 업그레이드해야 한다. 개인키를 잃어버려도 마찬가지로
새 공개키를 넣은 릴리스를 한 번 직접 설치해야 한다. upstream Ghostty의 appcast는
절대 쓰지 않는다. 쓰면 Chostty가 순정 Ghostty로 바뀐다.

**크래시 리포터 없음.** GhosttyKit은 `-Dsentry=false`로 빌드한다. 그래서 앱에는
Sentry와 Breakpad 코드가 들어가지 않고 앱 자체의 크래시 리포트도 남지 않는다.
`+crash-report`가 보여 주는 것은 같은 디렉터리를 쓰는 upstream Ghostty나 이전
Chostty 빌드가 남긴 리포트뿐이다. upstream은 macOS에서 이 기능을 기본으로 켜
두므로, 여기서 `zig build`할 때는 늘 이 플래그를 붙여야 한다. 빼고 만든
Debug 빌드는 SSH pane마다 앱 실행 파일을 `+ssh`로 실행하므로 `[sentry]` 줄도 찍힌다.

**Files 패널 Reader.** 오른쪽 Files 패널에서 파일을 열면 선택한 Virtual Tab에 읽기
전용 문서 탭이 붙고 터미널 surface는 내려가지 않는다. Virtual Tab마다 열린 문서를
20개까지 따로 유지한다. 이미 열린 경로를 다시 열면 그 문서를 선택하고 `Esc`는
Reader를 숨기며 Reader가 활성일 때 `⌘W`는 선택한 문서만 닫는다. Markdown, 소스
텍스트, JSON/YAML/TOML/XML/property list, 이미지, 정적 HTML은 전용 뷰로 보여 주고
나머지 형식은 내장 Quick Look 미리보기로 연다. 정적 HTML은 JavaScript와 네트워크
리소스를 끈 채로 보여 준다. 열린 문서 탭은 앱을 다시 시작하면 일부러 복원하지 않는다.

**설정 편집기.** `⌘,`(환경설정…)와 `open_config` 동작이 설정 파일을 외부 편집기로
바로 넘기지 않고 GUI 편집기를 연다. 흔한 키 — 글꼴, 색, 커서, 창 동작, `keybind`나
`font-feature` 같은 반복 키 — 를 항목별 설명과 함께 다루고, 값이 바뀐 줄만 다시
쓰므로 주석과 순서, 알 수 없는 키, 반복 키는 저장 후에도 한 바이트도 바뀌지 않는다.
**Save & Apply**는 파일을 원자적으로 쓰고 앱 설정을 다시 읽는다. **Edit in External
Editor**가 원래의 텍스트 편집 작업을 한 번의 클릭에 남겨 두었고, 줄 옆의 **Reset**은
키를 지워 기본값이 다시 적용되게 한다. 컨트롤 값을 정하면 기본값과 같아도 값을
명시적으로 쓰며, 키를 지우려면 Reset을 누르거나 텍스트 칸을 비운다. 고칠 때마다
libghostty 파서로 검사해 문제가 있으면 저장하기 전에 해당 줄에 표시한다. 설정 파일이
심볼릭 링크면 링크가 가리키는 원본에 쓰고, 편집기가 연 뒤 다른 곳에서 파일을 고쳤으면
말없이 덮어쓰지 않고 어느 쪽을 남길지 묻는다. Save & Apply 단축키는 Return이 아니라
`⌘S`다. `open_config` 키 바인딩은 그대로 동작하고 이제 편집기를 연다.

`theme` 줄에서는 앱에 들어 있는 테마와 `~/.config/ghostty/themes`의 테마를 갤러리로
고른다. 이름이 같으면 사용자 테마가 이긴다. 테마마다 미리보기가 있고, 검색과
어두운/밝은 필터를 쓸 수 있으며, 라이트·다크 모드에 테마를 따로 고르면
`light:…,dark:…`로 쓴다. 테마나 `config-file` include가 정한 값은 Ghostty의
우선순위(include > 이 파일 > 테마 > 기본값)대로 실제 적용되는 값과 출처를 그
줄에 보여 준다. 이 파일에 썼지만 include가 덮어쓰는 키에는 경고가 붙는다.
**All Settings**는 실행 중인 바이너리가 `+show-config --default --docs`로 알려 주는
키를 모두 보여 주고 upstream 설명 전문은 **More…**에 담는다. 그래서 추려 둔
페이지 밖의 키도 편집기에서 고칠 수 있다. 다른 플랫폼용 설정은 파일에 없으면
여기서 숨긴다.

**창 복원이 아니라 구조 저장.** Chostty는 여전히 `NSWindowRestoration` 클래스를
등록하지 않고 `NSQuitAlwaysKeepsWindows`도 false로 고정한다. AppKit 창 아카이브는
관여하지 않는다. 대신 앱이 자체 JSON 파일 하나를 관리한다.
`~/Library/Application Support/<bundle id>/session.json`과 바로 전에 검증된 스냅샷을
담은 `session-previous.json`이다. 여기에 워크스페이스, Virtual Tab, Pane의 이름, 색,
순서, 접힘 상태, 탭 제목, 탭별 분할 배치, Pane별 작업 디렉터리를 적어 두고 다음
실행 때 그 구조를 되살린다.

다시 시작하면 로컬 pane마다 기록된 작업 디렉터리에서 **새 셸**이 뜬다. 예전 프로세스,
화면, 스크롤백은 남지 않으며 터미널 내용은 디스크에 전혀 쓰지 않는다. 기록된
디렉터리가 사라졌으면 홈 디렉터리로 몰래 바꾸지 않고 그 항목을 버린다. 이 포크에서
탭을 만드는 다른 경로와 같은 방식이다.

탭, 워크스페이스, 이름, 색, 창, split 같은 구조 변경은 약 1초 뒤에 저장한다. 셸이
알려 주는 제목과 디렉터리는 최대 8초 간격으로 저장한다. 바뀐 것이 있을 때만 저장하고,
쓸 내용이 디스크의 파일과 같으면 건너뛰므로 가만히 있는 창은 아무것도 쓰지 않는다. 정상 종료할 때는 창을 닫기 전에 한 번 더
저장한다. 크래시나 강제 종료 때는 그 간격만큼 잃을 수 있다. 파일은 원자적으로 쓰고
권한은 소유자만(`0600`)이다.

저장 세션에는 물리 창을 최대 32개까지 담을 수 있다. 저장을 거부했거나 계속 실패하면
워크스페이스 동작 버튼에 주황색 경고 배지가 붙고, 그 메뉴에 나타나는 **Check Sidebar
Sync…**에서 원인과 해결 방법을 알려 준다. 저장이 정상일 때는 이 항목이 보이지 않는다.

백업은 실행에 성공한 뒤 처음 만든다. 그 뒤로는 변경을 저장하기 전마다 기존 주 파일이 불러오기와
같은 검사를 통과할 때에만 그 파일로 갱신한다. 그래서 주 파일이 망가졌을 때 돌아가는
지점은 아주 오래된 부팅 상태가 아니라 성공한 저장 한 번 전이다. 잘못된 주 파일 바이트가
백업을 덮어쓰는 일은 없다. 백업 쓰기에 실패하면 주 파일은 그대로 두고 저장을 실패로
처리해 다시 시도한다. 두 파일 모두 원자적으로 쓰고 소유자 전용 권한을 쓴다. 같은
내용을 저장하면 둘 다 건드리지 않는다.

지금 사용 중인 활성 Chostty 인스턴스가 파일을 저장한다. 실행 중인 다른 인스턴스를
활성화하면 저장도 그쪽으로 넘어간다. 다른 인스턴스에 저장을 넘긴 인스턴스는 자기가
닫은 창만 파일에서 지우고, 상대 인스턴스가 끝나더라도 다시 활성화되기 전까지는 그
상태를 유지한다. 기록된 pid를 지금은 상관없는 프로세스가 쓰고 있다면 실행 중인
Chostty로 치지 않는다.

물리 창을 모두 닫아도 마지막 유효 스냅샷을 빈 스냅샷으로 바꾸지 않는다. 다른 창을
열지 않고 앱을 끝내면 다음 실행 때 비어 있지 않던 마지막 배치를 되살린다.

실행할 때 셸을 띄우는 탭은 선택된 워크스페이스의 선택된 탭 하나뿐이다. 같은
워크스페이스의 나머지 탭은 pane 수에 맞춰 한 탭씩 연다. 다른 워크스페이스 탭은
그 워크스페이스를 열 때까지 셸을 띄우지 않는다. 그래서 탭 스무 개를 복원해도 터미널
스무 개가 한꺼번에 뜨지 않는다. 탭을 여는 중에 Chostty가 종료됐으면 그 탭은
보류(held back) 표시를 달고 남으며, 선택해야 열린다. 열지 못한 탭에는 경고 표시가
붙고, 선택하면 다시 연다.

복원 시도를 기록하지 못하면 경고 배지와 **Check Sidebar Sync…**에서 복원 보호를
쓸 수 없다고 알린다. 이때 저장된 창과 탭은 선택할 때만 열린다.

파일이나 URL을 먼저 여는 실행, 명시적인 열기 의도가 있는 실행(`ghostty -e …`,
`open --args`), `initial-window = false` 설정은 저장 창을 열지 않고 세션 파일에 그대로
남긴다. 저장 창은 사이드바 워크스페이스 동작의 **Reopen Saved Windows**로 열거나, 창이
하나도 없을 때 Dock을 클릭해서 연다. 명시적 열기 실행도 자기 창은 저장하고, 열지 않은
저장 창은 그대로 둔다. `-e` 명령 자체는 저장하지 않는다. 창을 닫으면 열지 않은 저장 창만
남더라도 그 창은 파일에서 빠진다. 복원하다가 앱이 종료된 창과 탭은 보류되며, 직접 열기
전에는 자동으로 열리지 않는다. 다른 인스턴스가 실행 중이면 새 인스턴스는 저장 창을
복원하지 않는다.

이 기능을 모두 끄려면 `macos-session-persistence = false`로 설정한다. 한 번만 끄려면
`GHOSTTY_MAC_DISABLE_SESSION_RESTORE=1`을 export한다. 테스트 호스트에서도 저장 기능은
스스로 꺼진다.

`window-save-state`는 upstream에서 물려받아 여전히 파싱되지만 macOS 앱은 무시하고
늘 `never`처럼 동작한다. 위 동작을 정하는 키는 `macos-session-persistence`다.

## SSH 연결

`~/.ssh/config`에 적은 호스트는 `⌘⇧P`에서 새 탭이나 오른쪽 split으로 연다. SSH 탭은
사이드바에 목적지와 연결 상태를 표시한다. `ssh-env`는 기본으로 켜며 `no-ssh-env`로
끈다. Chostty가 설정 파일의 출처를 확인하지 못하면 `ssh-env`를 강제로 켜지 않고 해당
설정을 따른다. Quick Terminal에는 SSH 진입점이 없다.

SSH pane은 스냅샷의 선택 필드 `ssh`에 호스트 연결 정보만 저장한다. 앱을 다시 시작하거나
Reopen Closed Tab으로 열면 서버에 접속하지 않고 **Connect**를 기다린다. Duplicate Tab은
새로 접속한다. 연결이 끊겨도 pane은 남으며 재접속하거나 닫을 수 있다. 호스트를 삭제하면
재접속만 막고 이미 연결된 세션은 유지한다.

SSH 진단 기록은 통합 로그의 `ssh`, `ssh-askpass`, `ssh-tunnel` 카테고리에 남는다.

```sh
log stream --level debug --predicate 'subsystem BEGINSWITH "kr.co.devch.chostty" AND category BEGINSWITH "ssh"'
```

이벤트는 `connect.requested`, `state.changed`, `resolver.ran`, `askpass.request`,
`tunnel.phase`처럼 분류, 개수, 소요 시간만 기록한다. 별칭과 경로는 private로 가리고,
비밀번호, 프롬프트, 답, 토큰, argv는 기록하지 않는다.

### SSH 호스트 관리자

Chostty가 소유한 호스트는
`<XDG config home>/chostty/ssh/hosts.conf`에 두고, 선택 사항인 표시 이름과 즐겨찾기는
옆의 `hosts.meta.json`에 둔다. `XDG_CONFIG_HOME`이 비어 있거나 없으면 `~/.config`를
쓴다. Finder로 연 앱은 셸 프로필이 아니라 launchd 환경을 물려받는다. 호스트 파일의
권한은 소유자 전용(`0600`)이며 새로 만드는 `chostty`, `ssh` 디렉터리의 권한은
`0700`이다.

관리자는 일반 터미널 창에만 적용한다. **Window > Manage SSH Hosts…**, 명령 팔레트의
**SSH: Manage Hosts…**, SSH 팝오버 아래쪽에서 연다. 관리 호스트만
`ssh -F hosts.conf`로 실행한다. `~/.ssh/config`, 그 Include, 시스템 설정은 읽기
전용으로 둔다. Chostty 소유 표식이 있는 블록만 고칠 수 있고 표식 없는 블록은 읽기
전용이다.

열거나 검색할 때는 `ssh -G`를 실행하지 않는다. `Match exec`가 있으면 **Resolve**와
**Duplicate to Edit**는 명시적으로 동의한 뒤에만 실행한다. Duplicate to Edit은 새롭고
고유한 별칭이 필요하다. OpenSSH 기본값과 다른 지원 General/Advanced 옵션만 복사하고,
지원하지 않는 설정은 **Not copied**로 보여 주며 자격 증명은 복사하지 않는다. 디스크
해시가 바뀌면 **Reload** 또는 **Overwrite**를 고른다.

**IdentityFile** 행에는 경로를 직접 입력하거나 **Choose…**로 파일을 고른다. 홈 폴더
아래 파일은 `~/…`로 저장하고 `%`는 이스케이프한다. 관리 파일은 값을 따옴표로 감싸지
않으므로 공백이 든 경로와 `.pub` 파일은 거부한다. **ProxyJump**에서는 **None**,
카탈로그의 다른 호스트, **Custom** 가운데 하나를 고른다. Custom은 Jump User, HostName,
Port 칸으로 입력하고, 여러 홉이면 텍스트로 고친다. 점프 호스트에 따로 키나 옵션이
필요하면 그 호스트를 추가한 뒤 목록에서 고른다. Keychain은 목적지 호스트의 프롬프트에만
답하므로 점프 호스트 비밀번호는 터미널에서 입력한다. **Check Jump Host**는 홉 하나만
확인한다. `ssh -G`를 실행한 뒤 `ssh -T … true`를 `BatchMode=yes`,
`StrictHostKeyChecking=yes`, `ControlPath=none`으로 실행하고, agent·X11·포트 포워딩은
끈다. 관리 파일이 있으면 그 파일을 쓴다. 패널과 터널처럼 로그인 셸의 `PATH`와
`SSH_AUTH_SOCK`을 쓴다. 확인 중에는 묻지 않고, 호스트 키를 기록하지 않으며,
다중화 세션을 재사용하지 않고, 비밀번호를 보내지 않는다. 결과는 로그인 성공, 키 인증
거부, 모르는 호스트 키나 바뀐 호스트 키, 연결 불가, 실패, 해석 불가 가운데 하나로
알려 준다. `Match exec`가 있으면 **Resolve**와 같은 동의를 받는다.

### 비밀번호 관리와 자동 전달

관리 호스트는 **Password in Keychain**을 고를 수 있다. User, HostName, Port를 모두
명시해야 하며, 일치하는 `Host`, 앞선 `Match`, 전역 endpoint 설정, 이른 `Include`가
호스트에 영향을 줄 수 있으면 고를 수 없다. 일치하지 않는 `Host` 블록은 막지 않는다.
저장한 실제 바이트로 자격을 판단한다. 외부 설정은 계속 읽기 전용이다. 메타데이터에는
인증 선택만 기록한다. 비밀번호는 호스트 UUID를 키로 삼아 파일 기반 로그인 Keychain 서비스
`<bundle id>.ssh.password`에만 저장하며 `hosts.conf`,
`hosts.meta.json`, 스냅샷, 인자, 환경, 로그에는 넣지 않는다.
터널은 아래에서 설명한다.

별칭만 바꾸면 기존 Keychain 항목을 쓴다. User, HostName, Port를 바꾸려면
**Use for <destination>** 또는 **Replace Password…**를 선택해야 한다. 관리자가
다른 접속 대상에 비밀번호를 몰래 재사용하지 않는다. 키 passphrase는 저장하지 않는다.
Apple OpenSSH에서 키를 다룰 때는 `UseKeychain yes`, `AddKeysToAgent yes`를 쓴다.

자동 비밀번호 전달은 `ghostty_init` 전에 시작한다. 서비스 전체 listener는 메타데이터를
읽기 전에 시작하고, pane coordinator가 첫 연결과 재접속마다 pane별 nonce를 발급하고
예약한다. 실행 인자에는 nonce를 넣지 않는다. 허용은 발급 뒤 단조 시계 기준
120초에 만료한다. kernel socket-peer와 정확히 세 단계인 부모 hop 고정은 nonce 발급이
아니라 자격 증명 요청을 막는다. Keychain을 명시적으로 고른 시스템 `/usr/bin/ssh`만
자동 secret을 받을 수 있다. `PATH`에서 찾은 다른 클라이언트는 수동 인증을 쓴다.

C helper는 libc `readpassphrase` 대신 바이트를 직접 읽는다. libc는 비어 있지 않은
EOF와 NUL을 확실히 구분하지 못한다. 이와 별개로 Darwin canonical mode에서는
1024바이트 경계의 종료 문자가 실제로 사라진다. reader는 `ISIG`를 잠시 켠 뒤
`TCSAFLUSH`로 저장해 둔 TTY 상태 전체를 복원한다. supervisor는 `-icanon`, `-isig`가
모두 잡혀야 연결된 것으로 보아 helper 인증을 connecting 상태에 둔다. 일반 실패 때는
EOF보다 먼저 확인한 SSH consumer를 멈춘다. `confirm`, `none` mode는 consumer를
종료하지 않는다. TTY가 없는 확인 요청이나 확인할 수 없는 일반 부모는 종료할 때까지
stdout을 붙든다. 빈 키 passphrase 요청은 키를 건너뛰지 않고 취소한다.

helper가 갑자기 죽거나 외부 `SIGKILL`을 받거나 supervisor를 고정하기 전에 크래시하거나
Darwin PID check-to-kill 경합이 나면 OpenSSH가 빈 시도를 할 수 있다. 빈 시도를 절대
막는다고 보장하지 않는다. 성공하면 helper가 소유 버퍼를 명시적으로 지우고 fatal handler를
유지한 채 native `_exit(0)`을 부른다. 고정한 뒤 helper가 크래시하면 fatal signal
handler가 EOF를 읽기 전에 consumer 부모를 죽인다.

broker는 일시적인 accept 오류를 재시도하고 치명적인 unavailable 상태를 알린다.
서비스는 연결마다 가용성을 다시 확인하고 kernel rewalk 전에 최종 파일과 attribute를
재검증한다.

저장소 밖에서 한 번씩 확인한 내용도 있다. helper를 단독으로, 또 번들 안에서 고아가
아닌 실제 foreground process group으로 돌렸을 때 Ctrl-Z와 지연 suspend를 거부했고 TTY를
그대로 복원했다. live broker 확인은 시스템 `ssh`, 번들 helper, 앱+SSH PTY supervisor를
부모 hop 세 단계로 거쳤다. fake store에서 한 번 가져와 제공했고, 유효한 nonce를 가진
무관한 같은 UID peer는 거부했다. store가 가짜였으므로 실제 Keychain 접근이나 비밀번호
바이트를 증명하지는 않는다. SSH가 보낸 `none` 질문과 하드웨어 FIDO 키는 아직 확인하지
않았다. 알려진 한계를 참고한다.

개발 중에는 ad-hoc 코드 ID가 빌드나 업데이트 뒤 Keychain 승인을 다시 물을 수 있다.
**Always Allow**는 그 코드 ID의 이후 접근을 신뢰하지만 모든 업데이트에서 프롬프트가
없다는 뜻은 아니다. 배포 기준은 Developer ID 서명 릴리스다. 이 저장소에는 서명 키나
자격 증명을 넣지 않는다.

### SSH 터널

SSH 관리 창의 **TUNNELS** 섹션은 카탈로그 호스트의 `-L`, `-R`, `-D` 포워딩을
`hosts.meta.json`에 저장한다. 터널은 멈춘 상태에서만 고치거나 지울 수 있고, 시작에
실패해도 설정은 남는다. bind 주소가 `127.0.0.1`, `::1`, `localhost`가 아니면 동의
창에서 **Allow**를 눌러야 저장된다. **Cancel**을 누르면 저장도 시작도 하지 않으며,
주소나 포트, 종류를 바꾸면 다시 묻는다. `-R`의 원격 bind는 서버가 정한다. 서버의 `GatewayPorts`가
`clientspecified`나 `yes`가 아니면 sshd는 루프백에서만 연결을 받는다. 호스트 SSH 설정의 `LocalForward`,
`RemoteForward`, `DynamicForward`도 터널 ssh에 그대로 적용되며 이 동의 대상이
아니다.

터널은 관리 창, SSH 팝오버, 명령 팔레트의 **SSH: Start Tunnel <name>**과
**SSH: Stop Tunnel <name>**에서 시작하고 멈춘다. `/usr/bin/ssh -N`을 실행하며
`ExitOnForwardFailure=yes`, `ForkAfterAuthentication=no`,
`PermitLocalCommand=no`를 주고 연결 공유는 쓰지 않는다. ssh가 부르는 보조 도구는
로그인 셸 `PATH`에서 찾는다. `-F hosts.conf`는 관리 호스트에만 붙는다. 인증 질문과
호스트 키 신뢰는 아래 "터널 인증과 호스트 키 신뢰" 절에서 설명한다. `-L`과 `-D`는
ssh가 bind 포트에서 연결을 받기 시작하면 **ready**가 된다. `-R`은 준비 신호가 없어
**running, unconfirmed**로 표시한다. 실패 문구는 대화형 인증, 모르는 호스트 키,
바뀐 호스트 키, 사용 중인 로컬 포트, 서버의 포워딩 거부, 그 밖의 종료로 나뉜다.
대상이 포워딩된 연결 하나를 거부해도 터널은 ready로 남고 마지막 채널 오류를 함께
보인다. SSH 버튼 배지는 실행 중인 터널 수다.

ssh의 stderr는 64 KiB 메모리 버퍼에만 두고 로그에는 분류 결과만 남긴다. 앱을
종료하면 확인 창 없이 모든 터널을 멈추고(SIGTERM, 2초, SIGKILL) 다음 실행 때 다시
시작하지 않는다. ssh는 `chostty-ssh-tunnel-watchdog.sh` 아래에서 돌며, 앱이 쥔
stdin 생명줄이 닫히거나 앱이 더는 부모 프로세스가 아니면 ssh를 멈춘다. 부모 확인을
둔 이유는 터널 파이프를 여는 사이에 fork된 터미널 pane이 생명줄을 물려받을 수 있어서다.
Darwin은 파이프 생성과 `FD_CLOEXEC` 설정을 따로 호출하고, libghostty는 `exec` 전에
descriptor를 정리하지 않는다. 런타임 루트에 터널마다 기록을 남기므로, 앱이 비정상
종료한 뒤 살아남은 ssh는 다음 실행 때 uid, 시작 시각, 실행 파일을 확인한 다음
회수한다. 관리 호스트를 지우면 실행 중인 터널을 먼저 멈추고 터널 정의도 지운다.
터널을 멈추지 못하면 호스트를 지우지 않는다.

### 터널 인증과 호스트 키 신뢰

터널에는 터미널이 없어서 ssh가 대신 앱에 묻는다. 터널마다 Chostty 실행 파일을
가리키는 `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=force`, 32바이트 난수 토큰을 준다.
토큰은 환경 변수에만 있고 인자에는 넣지 않으며 터널이 끝나면 폐기한다. broker는
요청한 프로세스가 Chostty 실행 파일이고, 그 부모가 `/usr/bin/ssh`이고, 그 ssh의
부모가 앱이 이 터널을 위해 띄운 watchdog이고, watchdog의 부모가 앱일 때만 답한다.
pid, 부모, uid, 시작 시각을 비교하며 답을 보내기 직전에 한 번 더 확인한다. 확인에
실패한 요청은 터널을 **SSH asked for input Chostty couldn't verify.**로 끝낸다.
같은 이유로 질문을 하는 `ProxyJump` 홉은 지원하지 않는다. 그 ssh는 터널 ssh의
자식이 아니다. 앱이 답하지 않으면 helper는 빈 답을 쓰지 않고 자신이 띄운 ssh를
끝낸다.

broker가 떠 있으면 터널은 `BatchMode`를 빼고 `StrictHostKeyChecking=ask`를 쓴다.
질문 창이 열려 있는 동안 터널 상태는 **waiting for authentication**이다.

- 모르는 호스트 키는 **Trust the host key for <alias>?** 창을 연다. 창에는 별칭으로
  해석한 접속 대상, ssh가 보인 fingerprint, ssh가 표시한 질문 원문이 나온다. ssh가
  다른 호스트나 포트를 묻거나 fingerprint를 보이지 않으면 경고 수준을 critical로
  올리고, Return은 **Cancel**을 선택한다. **Trust and Connect**는 `yes`로 답하고,
  키는 ssh가 직접 터널의 `UserKnownHostsFile`에 덧붙인다. **Cancel**은 `no`로 답하며
  터널은 **The host key was not trusted.**로 실패한다.
- ssh가 이미 아는 키와 충돌한다고 보고하는 질문(호스트에 알려진 다른 키 유형, IP
  주소의 다른 키, DNS 불일치, 그 밖의 모든 ssh 경고)은 sheet를 띄우지 않고 `no`로
  답한다. 터널은 **SSH reported a conflict with a known host key. Check it in a terminal
  tab.**로 실패한다. 바뀐 키는 ssh가 직접 거부한다. `known_hosts`는 그대로 두며
  터널은 바뀐 키 문구로 실패한다.
- 키 passphrase나 일회용 코드 같은 다른 질문은 **SSH needs input for <name>** 창을
  연다. 답은 한 번만 전달하고 저장하지 않는다. **Cancel**을 누르면 터널은
  **Authentication was cancelled.**로 실패한다. 110초 동안 답이 없으면 창이 닫히고
  **Authentication timed out.**로 실패한다.
- `SSH_ASKPASS_PROMPT=confirm`은 **Allow**/**Cancel** 창을 연다. `none`은 안내만
  띄우고 터널이 ready가 되거나 실패하면 닫는다. 키 처리가 끝나면 ssh가 안내용
  helper를 직접 끝낸다.
- **Password in Keychain** 호스트에서는 ssh가 정확히 `<user>@<host>'s password:`로
  물을 때 호스트 자격을 다시 확인한 다음 Keychain 비밀번호로 답한다. ssh 프로세스
  하나에 한 번만 답하고, 두 번째 요청은 **Saved password was rejected.**로 실패한다.
  잠긴 항목, 거부된 접근, 없는 항목은 각각 다른 문구로 실패한다. 저장된 비밀번호에
  줄바꿈이나 NUL이 있으면 **Saved password contains characters SSH can't receive.**로
  실패한다. 비밀번호는 창에 보이지 않는다.

질문 창은 key 창이나 main 창에 sheet로 붙고 SSH 팝오버에는 붙지 않는다. 열린 창이
없으면 앱 모달 알림으로 띄운다. 터널을 멈추면 그 질문 창도 닫는다. broker를 쓸 수
없으면 Keychain 호스트의 터널은 **Saved password broker is unavailable.**로 실패하고,
나머지 터널은 `BatchMode=yes`와 `StrictHostKeyChecking=yes`로 돌아간다. 이때 모르는
키는 **Connect once in a terminal tab to trust this host.**로 실패한다. watchdog은
ssh를 띄운 뒤 자기 셸에서 askpass 변수를 지워 다른 하위 프로세스로 넘기지 않는다.
변수는 ssh 환경에 남으며, ssh는 이를 `ProxyCommand`, `KnownHostsCommand`, `Match exec`
명령 같은 자기 자식에게 넘긴다. 이 명령들은 터미널에서와 같은 신뢰 경계에서 실행한다.
ssh 바로 아래에서 Chostty 실행 파일을 직접 실행하는 명령은 프로세스 확인을 통과한다.

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

편집 메뉴에는 항상 표준 단축키 `⌘Z`, `⌘⇧Z`, `⌘X`, `⌘C`, `⌘V`, `⌘A`가 걸려 있다.
그래서 터미널 밖의 텍스트 필드(SSH Hosts, 시트, 사이드바)에서도 편집할 수 있다.
터미널에 포커스가 있으면 이 단축키에 걸린 터미널 바인딩이 먼저 실행된다. 이 중
하나를 unbind하면 터미널은 그 키 입력을 그대로 받지 않고, 편집 메뉴 항목이 대신
처리한다.

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

일반 터미널 창은 세 위치 모두에서 파일 패널 버튼 다음에 **SSH Hosts**를 표시한다.
팝오버에서 등록된 호스트와 최근 접속을 검색하고 Return으로 새 탭을 열거나
Option-Return으로 오른쪽을 분할한다. Escape를 누르면 터미널로 포커스가 돌아간다.
팝오버를 열 때는 `ssh -G`를 실행하지 않는다. Quick Terminal에는 이 버튼이 없다.

판단은 전부 `WorkspaceControlsPlacement.forStandaloneWindow`에서 하고
`WorkspaceControlsPlacementTests`가 경우의 수를 모두 검사한다.

## 빌드

```sh
zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dsentry=false   # GhosttyKit 갱신
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

- 선택 목록, 색 선택기, 슬라이더 같은 전용 컨트롤은
  `macos/Sources/Features/Settings/ConfigEditor/ConfigSchema.swift`에 추려 둔 키에만
  있다. All Settings의 나머지 키는 텍스트 칸이고, `bool` 필드는 스위치, 반복 키는
  목록이다. 실제 적용값은 파일과 include, 테마만으로 계산하며 CLI 인자는 반영하지
  않는다.
- `new tab`은 `in` 매개변수가 있을 때만 처리된다. `new tab in window 1`과
  `new tab in front window`는 되지만 `new tab`만 쓰면 errAEEventNotHandled(-1708)로
  실패한다. `in` 없는 `new tab with configuration …`도 마찬가지다. 자동화가 불안정해서가
  아니다. 앱을 맨 앞에 두고 raw `«event GhstNTab»`을 보내도 똑같이 실패하고 upstream
  Ghostty도 똑같으니 새로 생긴 문제가 아니라 물려받은 문제다. `new window`는 `in`을
  받지 않고 매개변수 없이도 잘 된다. 고치려면 dictionary를 바꿔야 하는데 dictionary는
  일부러 고정해 두었으므로 그대로 둔다. `in front window`를 붙여 쓴다.
- Collapse All, Expand All, 단일 워크스페이스 정책 토글은 메뉴에서만 쓸 수 있다.
  워크스페이스와 SSH 명령은 앱 자체 명령 팔레트 소스에서 제공한다.
- 소스를 고정한 검사는 modifier가 지워지거나 옮겨진 경우는 잡지만 옆에 하나 더 붙은
  경우는 잡지 못한다.
- 실제 서버에서 사람이 직접 확인한 것은 Keychain 비밀번호 로그인, ProxyJump 호스트,
  두 앱 인스턴스에서 동시에 돌린 터널이다. 다음 수동 확인은 아직 하지 않았다. 하드웨어
  FIDO 키(키가 없었다), VoiceOver(사용자가 미뤘다), Keychain 동의·ACL 프롬프트와 잠긴
  Keychain, PAM keyboard-interactive 서버, SSH가 보낸 `none` 질문, 실제 호스트 키 신뢰
  시트, 비밀번호·보안 입력 터널, Debug와 Release의 Keychain 분리, ad-hoc 서명 업데이트
  뒤 첫 연결. 이 확인을 통과하기 전까지 SSH 기능은 릴리스 준비가 끝나지 않은 것으로 본다.
- SSH 탭과 로컬 탭이 섞인 그룹을 닫았다가 다시 열면 모든 탭을 기록된 메타데이터로 새로
  만든다. 그래서 로컬 탭은 원래 프로세스가 아니라 새 셸로 돌아온다.

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
