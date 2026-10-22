# Groovie

MacBook 노치 안에 LP판이 들어 있다는 설정으로 만든 음악 스크럽 인터페이스입니다.
노치에서 레코드를 아래로 당겨 꺼내고, 잡은 채 좌우로 돌려 재생 위치를 탐색한 뒤,
놓으면 레코드가 노치로 돌아갑니다. 별도의 슬라이더나 버튼 없이 레코드 하나만 조작합니다.

```
Idle → Armed (hover) → Pulling (8 px) → Grabbed (80 px) ⇄ Scrubbing → Releasing → Idle
```

## 현재 구현

- **Pull to Grab (magnet)** — 노치에서 시작한 수직 드래그만 Pull로 인식합니다. 8px에서 당김이 시작되고,
  40px(중간)을 넘는 순간 자석처럼 **레코드가 완전히 튀어나오며 Grab**됩니다. 그 전에 놓으면
  스프링으로 쏙 들어갑니다. 레코드는 **풀 원으로 렌더링**되고 노치가 상단을 덮습니다.
  노치 캡은 무광 검정으로 두고, 레코드에는 살짝 밝은 차콜 바탕·홈·고정 반사광·림라이트를 넣어
  두 재질이 하나의 검은 덩어리로 뭉개지지 않게 했습니다. 캡 하단에는 은은한 0.6px 엣지 라인과
  짧은 접촉 그림자가 있습니다. 레코드의 중심은 노치 끝(경계선)에 정확히 놓입니다.
- **레코드 스킨** — 클래식 블랙(기본), 러스트, 딥 틸, 스모크, 모노 5종.
  상태 메뉴의 **레코드 스킨**에서 고르면 즉시 반영되고 다음 실행에도 유지됩니다.
  스킨은 바이닐 바탕·홈·반사광만 바꾸며, 레이블은 항상 트랙을 따릅니다:
  앨범 아트가 있으면 아트, 없으면 트랙 정보에서 뽑은 액센트 색과 인쇄 디테일.
  모노 스킨만 트랙 색을 25% 채도로 낮춰 무채색에 가깝게 유지합니다.
- **로고와 상태 메뉴 헤더** — 메뉴 바 아이콘은 노치+반쯤 나온 레코드 마크를
  코드로 그린 단색 템플릿입니다. 상태 메뉴 상단은 **252pt 고정 폭** 헤더로,
  왼쪽 로고·곡 제목·아티스트·얇은 진행 바를 보여줍니다. 제목이 폭을 넘으면
  0.7초 뒤부터 20pt/s로 흐르는 마퀴가 되고, 짧으면 정지합니다. 재생/일시정지
  문구는 넣지 않으며, Music 미실행·트랙 없음·권한 필요 같은 **행동이 필요한
  상태만** 헤더에 표시합니다. 앱 아이콘은 `Resources/AppIcon.icns`로 패키징됩니다.
- **Drag to Rotate / Velocity to Seek** — 잡은 뒤 좌우 이동으로 탐색합니다.
  오른쪽 = 되감기, 왼쪽 = 앞으로 감기. 이동 속도가 빠를수록 같은 거리에서 더 크게 탐색합니다.
- **Confirm to latch / magnet put-back** — Grab된 레코드는 아직 고정이 아닙니다. 다음 중 하나의
  **confirm 제스처**가 있어야 고정됩니다.
  - 스냅된 상태에서 **아래로 240px 더 당기기**(빠르게 당기면 가속도가 붙어 더 짧게 완료)
  - 놓은 뒤 **1초 안에 다시 끌기**(마우스) / 잠시(0.8초) 멈춘 뒤 다시 **아래로** 스크롤하기

  레코드 아래에는 **반투명 confirm 게이지**가 표시됩니다. 게이지는 스냅되는 순간 **0에서 시작**하고,
  추가로 아래로 당기면 채워지며 가득 차면 자동으로 confirm됩니다(햅틱). 빠르게 당길수록 속도 계수
  (최대 3.2×)가 붙어 240px보다 짧은 이동으로도 찰 수 있습니다. **Confirm 중에는 가로 데드존이
  3배(30→90px)로 넓어져, 세로로 당기는 동안 좌우 흔들림으로 탐색되지 않습니다. 가로 이동은
  confirm 사유가 되지 않습니다.** Confirm 후에는 손을 놓아도 나온 채로 고정되고,
  **클릭 / 위로 끌기 / 위로 스크롤**로 닫습니다.
  Confirm 없이 그냥 놓으면 약 1초 동안 대기한 뒤 스프링으로 들어갑니다.
  원래 일시정지 상태였다면 닫은 뒤에도 일시정지합니다.
- **Two-finger scroll** — 커서가 노치 위에 있을 때 두 손가락 스크롤로도 조작할 수 있습니다.
  아래로 스크롤하면 중간 지점에서 자석처럼 완전히 나오고(햅틱), 좌우 스크롤로 탐색하며,
  위로 스크롤하면 닫힙니다. 추가로 더 내려 게이지를 채우거나, 잠시 멈춘 뒤 다시 아래로
  스크롤하면 confirm되어 고정됩니다. 가로 스크롤은 confirm 사유가 아닙니다.
  Confirm 없이 멈추면 약 1.4초 뒤 들어갑니다.
- **Wiggle to cancel** — 잡은 상태에서 좌우로 빠르게 흔들면(1초 안에 4회 방향 전환)
  이번 탐색을 취소하고 잡기 직전의 재생 위치로 되돌립니다. 레코드가 고정된 상태라면
  취소 후에도 나온 채로 유지됩니다.
- **Return to Playback** — 스크럽이 끝나면 수동 회전에서 33⅓ RPM 자동 회전으로 이어집니다.
- **노치 없는 디스플레이** — 카메라 하우징이 없으면 화면 상단 중앙을 동일한 경계선으로 사용합니다.
  레코드 중심이 화면 상단 끝에 오고, 아래쪽 반원이 보입니다(내부적으로는 풀 원 렌더링).
- **Apple Music 연동** — `Music.app`의 현재 트랙, 재생 상태, 재생 위치, 앨범 아트를 읽고
  0.1초 수준으로 seek합니다. 앨범 아트가 없으면 트랙 정보로 종이 레이블을 그립니다.
- **데모** — Music이 없어도 상태 메뉴의 “데모 재생”으로 전체 인터랙션을 볼 수 있습니다.

## 요구 사항

- macOS 14 이상 (macOS 26에서 개발/검증)
- Swift 6.3 Command Line Tools (Xcode 프로젝트 없이 SwiftPM으로 빌드)
- Music.app (실제 음악 연동 시)

## 빌드와 실행

```sh
make app      # build/Groovie.app 생성 (release)
make run      # 빌드 후 실행
make test     # 헤드리스 상호작용 모델 검사
make demo     # 데모를 실행하고 화면을 캡처 (build/demo.png)
make icon     # 앱 아이콘 시안에서 Resources/AppIcon.icns 재생성
```

`make test`는 `--self-test` 모드로 스크럽 감도 곡선, 방향, 경계 클램프, 레이아웃,
Music 읽기 파서, 시간 표시 포맷을 검사합니다.

## 사용법

1. Music에서 곡을 재생하거나 일시정지합니다. (트랙이 로드되어 있어야 합니다.)
2. 노치 위로 커서를 올리면 노치 아래에 1px 정도의 미세한 표시가 나타납니다.
   이 표시는 Music 실행 여부나 트랙 유무와 관계없이 항상 나옵니다.
3. 노치 안에서 **아래로** 끌어당깁니다. 중간(40px)을 넘으면 레코드가 자석처럼 완전히 나오고,
   중심이 노치 끝에 옵니다. 그 전에 놓으면 다시 쏙 들어갑니다.
4. 잡은 채로 **오른쪽으로 밀면 되감기**, **왼쪽으로 밀면 앞으로 감기**입니다.
   천천히 움직이면 정밀하게, 빠르게 움직이면 크게 탐색합니다.
5. Confirm 제스처(아래로 더 당기기 / 놓은 뒤 1초 안에 다시 끌기)를 하면
   해당 위치부터 재생되고 레코드가 **고정**됩니다. 고정 후에는 `클릭`하거나 위로 끌어 닫습니다.
   (스크롤 모드에서는 위로 스크롤) Confirm 없이 놓으면 마우스는 1초, 스크롤은 1.4초 뒤
   다시 들어갑니다.
   원래 일시정지 상태였다면 일시정지가 유지됩니다.

시작 위치가 트랙의 0초이거나 끝에 닿으면 그 이상 탐색하지 않고 레코드도 더 돌지 않습니다.
최초 이동이 수평이거나 위쪽이면 Pull로 인식하지 않습니다.

### 두 손가락 스크롤

노치 위에 커서를 둔 채 두 손가락으로 스크롤합니다.

- **아래로 스크롤** — 레코드가 나옵니다. 중간 지점에서 자석처럼 완전히 펴지고(햅틱) 노치 끝에 섭니다.
- **좌우 스크롤** — 오른쪽은 되감기, 왼쪽은 앞으로 감기. 속도에 따라 감도가 달라집니다.
  탐색은 한 방향으로 약 30px 이상 움직여야 시작됩니다(데드존). 세로로 내리는 동안의
  미세한 수평 흔들림으로는 재생 위치가 바뀌지 않습니다.
- **위로 스크롤** — 레코드를 노치 안으로 되돌립니다. 되돌린 시점의 위치가 확정됩니다.
- **Confirm** — 스냅 후 추가로 더 내리면 아래의 반투명 게이지가 채워지고, 가득 차면 고정됩니다.
  스크롤은 480(포인터의 2배)을 채워야 하며, 빠르게 내리면 가속도가 붙어 더 짧게 완료됩니다.
  잠시(0.8초 이상) 멈췄다가 다시 **아래로** 스크롤해도 고정됩니다. 가로 스크롤은 confirm 사유가
  아니며, confirm 중에는 가로 데드존이 90px로 넓어집니다. 고정되면 입력이 멈춰도 유지됩니다.
- **Confirm 없이 멈추면** — 약 1.4초 뒤 스프링으로 들어갑니다.
- 트랙패드의 관성(momentum) 이벤트는 탐색에 사용하지 않습니다.

### 탐색 취소 (Wiggle)

레코드를 잡고 좌우로 빠르게 흔들면 — 1초 안에 8px 이상의 방향 전환이 4번 이상 —
이번 탐색 전체를 취소하고, 잡았던 순간의 재생 위치로 되돌립니다.
살짝 흔들리거나 정밀 탐색 중의 작은 방향 전환으로는 취소되지 않습니다.
취소 시 가벼운 햅틱이 울리고 레코드가 노치로 들어갑니다.

### 노치 없는 디스플레이

카메라 하우징이 없는 화면에서는 화면 상단 중앙 179pt 영역이 상호작용 영역이 됩니다.
레코드는 화면 상단 끝에서 나오며, 노치가 있을 때와 똑같이 중심이 경계선에 놓입니다.
디스플레이가 여러 개면 내장 노치 디스플레이를 우선 사용합니다.

## Music 권한

Groovie는 AppleScript로 Music을 제어합니다. 앱을 시작할 때 Music이 실행 중이
아니면 Music을 자동으로 엽니다. 실행 중이지만 재생할 트랙이 없으면 Music을 앞으로
가져와 곡을 고를 수 있게 합니다. 첫 실행 시 “Groovie wants to control Music”
자동화 권한 요청이 뜨면 **허용**해야 합니다.

- 거부한 경우: 시스템 설정 → 개인정보 보호 및 보안 → 자동화 → Groovie → Music을 켜거나,
  상태 메뉴의 “Music 연결 다시 시도”를 사용하세요.
- 상태 메뉴 상단에 곡 제목·아티스트·진행 바가 표시됩니다. 연결 문제가 있으면
  그 자리에 Music 미실행/트랙 없음/권한 필요 문구가 대신 나옵니다.
- 앱은 로컬에서 ad-hoc 서명됩니다. 다시 빌드하면 코드 서명이 바뀌어
  macOS가 자동화 권한을 다시 물을 수 있습니다. 개발 중에는 허용을 다시 눌러주세요.

> Music 앱만 지원합니다. Spotify의 AppleScript는 재생 위치 seek를 지원하지 않습니다.

## 개발용 모드

```sh
open build/Groovie.app --args --fake-music
open build/Groovie.app --args --fake-music --demo
open build/Groovie.app --args --fake-music --simulate-no-notch
open build/Groovie.app --args --fake-music --demo --skin=rust
```

- `--fake-music` — Music 없이 가상 트랙으로 실제 마우스 드래그를 테스트합니다.
- `--demo` — 당기기 → 되감기 → 앞으로 감기 → 놓기 시퀀스를 자동 재생합니다.
- `--simulate-no-notch` — 노치가 있는 Mac에서 노치 없는 레이아웃을 확인합니다.
- `--skin=<id>` — `classic`, `rust`, `teal`, `smoke`, `mono` 중 하나로 이번 실행의 스킨을
  고정합니다. 저장된 선택은 바꾸지 않습니다.
- `--long-title` — 가상 트랙 제목을 길게 만들어 상태 메뉴 헤더의 마퀴를 확인합니다.
- `--self-test` — 헤드리스 검사를 실행하고 종료합니다.

## 구조

```
Sources/GroovieKit/
  App/AppDelegate.swift              메뉴 바 앱, 상태 메뉴, 권한 안내
  Notch/NotchGeometry.swift          노치/비노치 화면 감지, 창 프레임
  Notch/OverlayPanel.swift           비활성(non-activating) 오버레이 패널과 입력 뷰
  Interaction/VinylLayout.swift      상태 정의, 당김→노출 곡선, 레코드 배치
  Interaction/ScrubEngine.swift      속도 기반 스크럽 수식과 클램프 (순수 로직)
  Interaction/OverlayController.swift 제스처 상태 머신, 창 전환, 복귀 스프링
  Interaction/VinylViewModel.swift   화면에 게시되는 상태
  Music/AppleMusicBridge.swift       AppleScript 실행, seek 병합, 아트워크 읽기
  Music/AppleMusicService.swift      폴링, 상태/가용성, 아트워크 캐시
  UI/VinylSkin.swift                 레코드 스킨 팔레트, 저장/복원, 트랙 색 처리
  UI/BrandMark.swift                 메뉴 바용 노치+레코드 템플릿 마크
  UI/MenuHeaderView.swift            고정 폭 메뉴 헤더, 마퀴·진행 바·예외 상태
  UI/                                레코드 텍스처, SwiftUI 스테이지, HUD
  Debug/                             데모 뮤직, 자기 검사
Resources/Info.plist                 LSUIElement, 자동화 사용 설명, 앱 아이콘
Resources/AppIcon.icns               빌드에 포함되는 macOS 앱 아이콘
docs/design/app-icon-cream-v3.png    앱 아이콘 마스터 시안
Scripts/build-app.sh                 SwiftPM 산출물을 .app으로 묶고 ad-hoc 서명
Scripts/make-app-icon.sh             슈퍼타원 마스크를 적용해 .icns 생성
```

## 튜닝 지점

- `ScrubEngine.ScrubTuning` — 감도 곡선(`min/maxSensitivity`, `speedAtMaxSensitivity`,
  `sensitivityExponent`), 속도 필터 attack/release, 회전량(`degreesPerPoint`).
- `VinylLayout` — `grabDistance`(80), `grabDetent`(40 = 중간 자석 지점),
  `confirmDistance`(240 = 포인터 confirm 거리, 가속도 최대 3.2×)
  `scrollConfirmDistance`(480), `confirmScrubDeadzone`(90 = confirm 중 가로 데드존), `mouseDismissDistance`(30),
  `exposurePerPoint`(1.125), `recordRadius`(90), `playbackDegreesPerSecond`(200 = 33⅓ RPM),
  복귀 스프링 상수.
- `OverlayController` — 스크롤 감도(`scrollPullScale` 0.55, `scrollScrubScale` 0.9),
  좌우 시작 데드존(`scrollScrubThreshold` 30), 닫기 임계값(`scrollCloseDistance` 40),
  confirm 대기 시간(`confirmWindow` 1.0초),
  자석 스냅 스프링(`snapOpenStiffness` 320, `snapOpenDamping` 26).
- 햅틱 — 스크롤 시작(`.levelChange`), 스냅·confirm·위글 취소·닫기(`.alignment`).
- Confirm 게이지 — 레코드 아래 반투명 캡슐 + 3.5pt 바(`VinylStageView.confirmGauge`),
  0…1 `confirmProgress`로 채워지고 confirm/닫기 시 페이드아웃.
- Confirm 가속 — `ConfirmAccumulator` (포인터 240pt / 스크롤 480pt, 속도 1800pt/s에서 최대 3.2×,
  attack 45ms / release 120ms, 위로 움직이면 게이지 감소, 스냅 순간 게이지는 0에서 시작).
- 스크롤 confirm — 재스크롤 인식 간격 0.8초, 무입력 래치/복귀 판정 1.4초.
- 노치 입력 영역 — 물리 노치 + 좌우/아래 6px 여백(`StageGeometry.idleFrame`).
  레코드가 열려 있는 동안에는 펼쳐진 스테이지 전체가 입력을 받습니다.
- `WiggleDetector` — 취소 제스처 임계값(`minimumStroke` 8, `window` 1.0초,
  `requiredReversals` 4).
- `VinylSkin` — 5종 바이닐 팔레트(`recordCenter`, `recordEdge`, `grooveLight`,
  `sheen`, `sheenStrength`, `accentSaturation`). 기본값은 `classic`,
  `UserDefaults` 키 `groovie.skinID`.
- `RecordTexture` — 홈 밀도(96링), 밴드·런아웃·레이블 인쇄. `VinylDiscView` — 회전하지 않는
  셰인·스펙큘러·림 강도. `VinylLayout.labelRadius`는 30(레코드 지름의 약 1/3).
- `VinylLayout.recordCenterY` — `emergenceInset + exposure − recordRadius`.
  Grab 시 `exposure == recordRadius`가 되어 중심이 정확히 경계선에 놓입니다.
- `MenuHeaderView` — 고정 폭 252pt, 높이 56pt, 제목 텍스트 폭 188pt.
  마퀴 속도 20pt/s, 시작 대기 0.7초, 반복 간격 28pt. 진행 바는 2pt,
  메뉴가 열려 있는 동안 1초 간격으로 로컬 보간합니다.
- `BrandMark` — 20×11pt 광학 박스. 레코드 지름 `0.85 × 11 / 0.72`,
  노치 `1.35D × 0.22D`, 스핀들 구멍은 최소 1.1pt로 광학 보정.
- 앱 아이콘 — `docs/design/app-icon-cream-v3.png` → 슈퍼타원 마스크 →
  `Resources/AppIcon.icns`. 32px 이하는 마크를 크롭·확대한 파생본을 씁니다.

## 알려진 제한

- 두 손가락 스크롤은 Hold & Drag와 다른 정책을 사용합니다. 스크롤 입력에는 명시적인
  놓기 이벤트가 없으므로, confirm이 없으면 1.4초 무입력 후 레코드가 들어가고,
  confirm이 있으면 고정됩니다. 닫는 것은 위로 스크롤 또는 클릭/위로 끌기입니다.
- 실제 Music의 seek 정밀도는 100ms 목표이며 모든 트랙/스트림에서 보장되지는 않습니다.
- 앨범 아트는 Music의 artwork raw data를 사용합니다. 읽기에 실패하면 생성 레이블로 대체됩니다.
- 노치가 없는 화면에서는 조작 중 화면 상단 중앙의 메뉴 바 영역을 덮습니다.
- 물리적 노치 위에서는 커서가 보이지 않습니다. 화면 최상단 중앙을 겨냥해 드래그하세요.
