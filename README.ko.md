# Chostty

[English](README.md) | 한국어

[Ghostty](https://github.com/ghostty-org/ghostty)를 바탕으로 만든 macOS용 포크다.
macOS 기본 창 탭 대신 창 안에 **Workspace → Tab → Pane** 계층을 두고 왼쪽
사이드바에서 다룬다.

Upstream Ghostty는 탭마다 `NSWindow`를 하나씩 만들어 `NSWindowTabGroup`에 넣는다.
터미널 기본값으로는 맞는 방식이다. 다만 서로 관련된 셸 묶음을 앱이 아니라 창
관리자가 쥐게 된다. 탭보다 위에서 묶는 단위가 없고 창이 맨 앞에 있지 않으면
묶음이 보이지 않는다. "방금 작업하던 세션"을 다루려는 기능은 모두 AppKit을
거쳐야 한다.

Chostty는 물리 창 하나를 두고 계층을 직접 관리한다. 워크스페이스는 탭을 묶고
탭은 Pane 분할 트리를 가지며 사이드바에 이 전체가 한 번에 보인다. AppKit 탭은
숨기거나 우회한 게 아니라 아예 걷어냈다. 다시 들어오면
`macos/scripts/native-tab-audit.sh`가 빌드를 실패시킨다.

창 모델 아래쪽은 Ghostty 그대로다. 렌더러, 설정 파일, terminfo, 셸 통합이 모두
같다.

## 설치

[Releases](../../releases)에서 DMG를 받아 Chostty를 Applications로 끌어다 놓으면
된다. 릴리스는 Developer ID로 서명하고 공증을 받았으므로 따로 손댈 것 없이
열린다. Universal 바이너리이고 macOS 13 이상에서 돈다.

업데이트는 Sparkle로 받는다. 이 저장소의 서명된 appcast만 쓰고 upstream 것은 쓰지
않는다. 자동 확인을 끄려면 `auto-update = off`, 업데이트를 백그라운드에서 내려받게
하려면 `auto-update = download`로 설정한다. 0.2.12 이하 설치본에는 업데이터가
없으므로 한 번은 직접 새 버전을 설치해야 한다.

Chostty 버전 번호는 Ghostty와 따로 매긴다. 1.0.0은 Chostty의 첫 정식
릴리스이며 Ghostty 1.0을 빌드한 것이 아니다. 어느 upstream 리비전을 담고 있는지는
`scripts/upstream-sync.sh`가 보여 주는 merge base로 확인한다.

### 0.2.15 이하에서 올리는 경우

0.2.16부터 번들 ID가 `com.chostty.app`에서 `kr.co.devch.chostty`로 바뀌었고
Ghostty에서 물려받은 아이콘도 Chostty 아이콘으로 바뀌었다. 처음 실행할 때 예전
설정과 저장된 세션을 새 위치로 복사하고 원본은 그대로 둔다. macOS는 손쉬운 사용,
자동화, 알림, 전체 디스크 접근 같은 개인정보 권한을 번들 ID 기준으로 기억한다.
그래서 물어보면 다시 허용해 주어야 한다.

## 사용법

`⌘B`로 사이드바를 열고 닫는다. 신호등 버튼 옆의 버튼으로도 된다. 사이드바 토글,
새 워크스페이스를 만드는 `+`, 워크스페이스 동작 메뉴가 있다. `⌘N`은 워크스페이스,
`⌘T`는 현재 워크스페이스 안의 탭, `⌘⇧N`은 별도 물리 창을 만든다. 나머지 기능은
워크스페이스나 탭, 사이드바 빈 곳을 오른쪽 클릭하면 나온다. 단축키 전체 목록은
[FORK.ko.md](FORK.ko.md)에 있다.

설정은 Ghostty와 같다. `~/.config/ghostty/config`를 읽고 키 바인딩과 테마 문법도
같으며 `TERM=xterm-ghostty`를 쓴다. 쓰던 Ghostty 설정이 그대로 동작하고 두 앱을
나란히 설치해도 된다.

이 포크가 가져다 쓰는 단축키는 upstream에서 비어 있거나 원래 동작하지 않던 조합뿐이다.
`⌘⌥←/→`, `⌘0`처럼 Ghostty에서 실제로 쓰는 바인딩은 건드리지 않는다.

## 빌드

Xcode 26(macOS 26 SDK)과 Zig 0.16이 필요하다. Nix는 필요 없다.

```sh
zig build -Demit-macos-app=false     # 앱이 링크하는 Zig 코어 GhosttyKit
./macos/build.nu --configuration Release --action build
```

감사 스크립트와 관련 테스트 묶음으로 확인한다.

```sh
./macos/scripts/native-tab-audit.sh
xattr -cr macos/build/Debug/Chostty.app
./macos/build.nu --configuration Debug --action test
```

전체 테스트를 한 번에 돌리면 살아 있는 터미널 surface가 쌓여 멈출 수 있다.
[AGENTS.md](AGENTS.md#testing--qa) 설명대로 `-only-testing:`으로 몇 개 suite씩
나눠 돌린다.

빌드가 `error:` 줄 없이 실패하면 대개 서명이 꼬인 것이다.
`macos/build/<Configuration>`을 지우고 다시 빌드한다. 앱을 실행하면 빌드 결과물에
quarantine 속성이 다시 붙으므로 테스트 전에 번들에 `xattr -cr`을 다시 실행한다.

앱 아이콘과 대체 아이콘은 모두 `macos/scripts/generate-icons.py`(Pillow 필요)로
만든다. PNG를 직접 고치지 말고 스크립트를 고쳐서 다시 실행한다.

Linux와 GTK 코드는 upstream에서 물려받아 손대지 않고 둔다. 여기서는 빌드하거나
테스트하지 않는다.

## upstream 따라가기

한 시점을 떠 온 복사본이 아니라 계속 따라가는 포크다. `scripts/upstream-sync.sh`는
지난 병합 이후 upstream에서 바뀐 내용을 문제가 될 가능성이 큰 순서로 보여 준다.

```sh
./scripts/upstream-sync.sh
```

변경은 네 묶음으로 나뉜다. 이 포크도 고친 파일(실제 충돌), 이 포크가 지운 파일
(delete/modify로 멈춤), 이 포크가 건드리지 않은 macOS 코드(깔끔하게 병합되지만
구조가 바뀐 앱 안으로 들어감), Zig 코어(대개 문제없음)다. 스크립트가 병합까지 하지는
않는다. 진짜 위험은 git이 충돌 없이 병합했는데 일부러 없앤 창 단위 가정이 되살아나는
경우다. 이건 목록을 읽어야만 잡힌다. 같은 보고서를 예약 워크플로가 추적 이슈에도
올린다.

동기화 기준점은 `upstream/main`과의 git merge base다. 따로 기록해 둔 리비전이 없으니
기준점이 낡을 일도 없다.

## Ghostty와의 관계

Chostty는 독립 포크다. Ghostty 프로젝트와 제휴하거나 승인이나 지원을 받지 않는다.
문제는 upstream이 아니라 이 저장소에 알려 달라. Ghostty라는 이름과 로고는 각
권리자의 것이며 Chostty는 자체 아이콘을 쓴다.

## 라이선스

Ghostty는 MIT 라이선스다. `LICENSE`에는 upstream 저작권 고지를 그대로 두고 그
아래에 이 포크의 줄을 더했다. 배포할 때는 반드시 함께 넣는다. 무엇이 바뀌었는지,
무엇을 일부러 호환되게 남겼는지, 알려진 한계는 [FORK.ko.md](FORK.ko.md)에 있다.
