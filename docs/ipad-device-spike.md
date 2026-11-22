# Windows에서 iPad 필기 앱 검증

[AET-31](https://linear.app/aethers-lab/issue/AET-31)은 iPad에 앱을 서명·설치하고 다시 실행하는 단계다. [AET-32](https://linear.app/aethers-lab/issue/AET-32)는 같은 기기에서 Apple Pencil로 입력한 필기가 앱을 종료한 뒤에도 복원되는지 확인한다. 두 단계 모두 저장소의 `ReedlesCanvas/` 소스를 사용한다.

## XCTest 자동 실행

Xcode와 XcodeGen이 설치된 Mac에서 `python3 tools/test_ipad.py`는 iPad Simulator를 고르고 앱·UI 테스트를 실행한다. 신뢰 설정과 개발자 모드를 마친 iPad와 해당 팀의 서명 설정이 있다면 `python3 tools/test_ipad.py --physical-device <UDID> --team-id <TEAM_ID>`로 같은 테스트를 실제 기기에 실행할 수 있다. 이 모드는 디버그 앱의 테스트 노트를 별도 위치에 만든다. [Apple의 Xcode 자동화 안내](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/testing_with_xcode/chapters/08-automation.html)

각 실행은 `.build/ipad-tests/run-*/` 아래에 실행 대상과 종료 상태를 기록한 `run.json`, `xcodebuild.log`, `.xcresult`를 보관한다. 지원되는 Xcode에서는 테스트 요약과 성능 지표도 JSON으로 추출한다. [Xcode 결과 도구](https://developer.apple.com/documentation/Xcode-Release-Notes/xcode-16_3-release-notes)

[AET-49](https://linear.app/aethers-lab/issue/AET-49) 자동 검사는 1만 획 노트의 원거리 이동, 페이지 교체, 카메라와 획 ID 복원, 앱 회전·백그라운드·재실행을 다룬다. 페이지 이동 시간, 물리 메모리와 CPU는 결과 번들에 기록한다. Pencil 입력 지연, 분할 보기와 배터리 계측은 지원 iPad에서 남기는 별도의 기기 지표다.

## RDP 접속 노트북에 iPad가 있는 경우

원격 Windows에서 `python tools/package_playground.py`를 실행하면 `.build/ReedlesCanvas.swiftpm.zip`이 생성된다. ZIP을 노트북으로 복사한 뒤 iCloud Drive 등으로 iPad의 파일 앱에 옮긴다. iPad에서 ZIP을 탭해 압축을 풀고 `ReedlesCanvas.swiftpm`을 Swift Playground로 열어 실행 버튼을 누른다. 앱 화면에서 Apple Pencil로 선을 하나 긋고 저장한다. 실행을 중지한 뒤 **같은 프로젝트**를 다시 실행해서 첫 획을 확인한다. 이후 아래 1,000획 시험을 진행한다. 이 경로는 iPad 자체에서 앱 소스를 빌드한다. WSL의 서명·재설치는 별도 시험이다. [Apple의 iPad용 Swift Playground 안내](https://support.apple.com/guide/playgrounds-ipad/welcome/ipados)

## iPad를 개발 PC에 직접 연결하는 경우

Windows에서 Ubuntu 24.04를 실행해 둔 뒤, 잠금 해제한 iPad를 데이터 케이블로 연결한다. PowerShell에서 `usbipd list`로 iPad의 BUSID를 찾는다. 처음 연결할 때는 관리자 PowerShell에서 아래 첫 명령으로 해당 iPad를 공유한다. 일반 PowerShell에서 두 번째 명령으로 WSL에 연결한다. `<BUSID>`에는 목록에서 확인한 값을 넣는다. [Microsoft USB 연결 안내](https://learn.microsoft.com/en-us/windows/wsl/connect-usb)

```powershell
usbipd bind --busid <BUSID>
usbipd attach --wsl --busid <BUSID>
```

Ubuntu에서 `idevicepair pair`를 실행하고 iPad의 신뢰 알림을 승인한 뒤 `idevicepair validate`로 페어링을 확인한다. iPadOS에서 개발자 모드를 요구하면 기기의 설정에서 활성화하고 재시동 후 확인한다. [Apple 개발자 모드 안내](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

## 앱 빌드와 재설치

xtool 1.24.0의 Linux 설치 문서는 Swift 6.4 및 Xcode 27.1을 지정한다. Apple Developer에서 받은 Xcode 압축 파일로 최초 1회 Darwin SDK를 설치한다. 아래 경로는 Windows 다운로드 폴더의 예시다. Apple 인증은 사용자 본인의 WSL 터미널에서 진행한다. [xtool 설치 문서](https://github.com/xtool-org/xtool/blob/1.24.0/Documentation/xtool.docc/Installation-Linux.md)

```bash
xtool sdk install "/mnt/c/Users/remote/Downloads/Xcode_27.1.xip"
swift sdk list
cd /mnt/e/dev/Reedle-s-Canvas
xtool dev build
xtool auth login
xtool devices --no-wait
xtool dev run
```

iPad 홈 화면에서 앱을 열고 제목과 획 수 표시가 있는지 확인한다. 한 획을 쓰고 저장한 뒤 앱을 닫는다. 같은 개발 팀과 번들 ID로 `xtool dev run`을 다시 실행해 기존 앱 위에 설치하고, 다시 열어 첫 획이 남았는지 확인한다. 무료 Personal Team의 프로비저닝 프로필은 발급일부터 7일간 유효하며 만료 후에는 다시 빌드·설치해야 한다. WSL의 SDK 또는 서명 도구가 기기와 호환되지 않으면 같은 소스를 Mac에서 `xcodegen generate`로 열어 Xcode의 개발 팀과 연결된 iPad를 선택하고 실행한다. [Apple 계정 안내](https://developer.apple.com/help/account/basics/about-your-developer-account)

## 확인할 결과

AET-32 스파이크에서는 `PKCanvasView.contentSize`를 4,096 × 4,096포인트로 설정하고 0.5~4배 확대를 허용했다. 당시 필기 위치를 비교할 때는 두 화면의 확대율과 스크롤 위치를 먼저 맞췄다. M1에서는 유한한 PencilKit 표면을 월드 좌표 안에서 이동하고 새 화면 영역에 필요한 획을 읽는다. 노트에 마지막 카메라를 저장해 앱을 다시 열면 같은 영역과 배율로 돌아간다. [Apple의 PKCanvasView 문서](https://developer.apple.com/documentation/pencilkit/pkcanvasview)

| 단계 | 관찰하고 기록할 내용 |
| --- | --- |
| 최초 설치·재설치 | 커밋, Swift·xtool 또는 Xcode 버전, iPad 모델·iPadOS 버전, 앱 실행 여부와 재설치 후 획 수 |
| 1,000획 복원 | 펜·마커의 색과 굵기를 바꿔 가며 총 1,000획에 도달한 뒤 화면 기록. 홈으로 이동하고 앱 전환기에서 종료한 다음 다시 열어 획 수·위치·스타일 대조 |
| 입력 지연 | 120Hz 지원 기기의 저전력 모드와 프레임률 제한 설정 기록. 빠른 곡선을 연속해서 그리며 펜 끝과 잉크 사이 간격 및 끊김 관찰 |

## AET-31 검증 결과와 빌드 경로

2026년 11월 21일 원격 Windows의 WSL2에서 Ubuntu 24.04.4 LTS, Swift 6.4.1과 xtool 1.24.0을 확인했습니다. `swift sdk list`에는 Darwin SDK가 없었습니다. 저장소에서 실행한 `xtool dev build`가 SDK 생성 단계에서 `I/O on closed channel`로 종료됐고, `usbipd list`에 iPad가 나타나지 않았습니다. 이 세션에서는 WSL로 서명해 iPad에 설치하고 다시 실행하는 단계까지 진행하지 못했습니다.

앱 빌드와 iPad 시뮬레이터 자동 검사는 GitHub Actions의 macOS에서 실행합니다. 2026년 11월 21일 `codex/canvas-camera`의 소유자 권한으로 올린 커밋 `7905640`이 Xcode 26.6(17F113), iPad mini(A17 Pro) 시뮬레이터에서 단위 테스트 71개와 UI 테스트 3개를 모두 통과했습니다. 이 소스는 로컬 커밋 `9dd3ebf`와 같은 트리입니다. [최신 실행 결과](https://github.com/aether0xff-afk/Reedle-s-Canvas/actions/runs/44908173895)

이번 실행에서는 페이지를 이동한 뒤의 실행 취소·다시 실행, 원문과 필기를 합친 PDF 캡처, 20페이지 PDF/PNG 내보내기, 회전·백그라운드·재실행을 확인했습니다. 1만 획을 담은 노트에서 7개 영역과 빈 영역을 조회·디코딩·할당하는 측정 구간은 세 번 평균 0.060초였고, 측정한 프로세스 최대 물리 메모리는 평균 약 67.6MB였습니다. 이 수치는 시뮬레이터의 계측 결과입니다. Pencil 지연과 배터리 지표는 실제 기기에서 측정해야 합니다. [테스트 로그와 결과 번들](https://github.com/aether0xff-afk/Reedle-s-Canvas/actions/runs/44908173895/artifacts/14708254728)

## AET-32 검증 결과

2026년 11월 20일 사용자가 실제 iPad에서 Apple Pencil로 1,000획을 쓴 뒤 앱을 다시 열어 획 수와 위치, 펜 스타일이 유지되는 것을 확인했다. 120Hz 지원 iPad에서 빠르게 필기했을 때 눈에 띄는 지연이나 끊김이 없었다고 보고했다.

커밋 `2347b3d`는 Xcode 26.6, iOS 26.4의 iPad Pro 13인치(M5) 시뮬레이터에서 테스트 3개를 통과했다. 합성 1,000획을 파일에서 새 문서로 복원했고, 손상 파일 보호와 쓰기 실패 후 재저장도 확인했다. [XCTest 실행 로그](https://github.com/aether0xff-afk/Reedle-s-Canvas/actions/runs/44725421112/job/136251479977)

## AET-35 검증 결과

2026년 11월 20일 사용자가 `740cc6b`의 iPad 테스트 패키지에서 세 가지 동작을 확인했다. 두 번 탭하면 교차점을 기준으로 확대됐고, 화면을 이동하고 배율을 바꾼 뒤 기억한 위치로 돌아오면 교차점의 위치와 크기가 복원됐다. Pencil로 획을 그리는 동안 손가락 이동이 차단됐고 펜을 뗀 뒤 다시 이동할 수 있었다.

사용자는 두 번 탭할 때 확대가 딱딱하게 느껴진다고 보고했다. 후속 빌드에서는 탭한 지점을 유지하며 0.26초 동안 배율을 전환한다. 새 Pencil 획이나 팬·핀치가 시작되면 그 지점에서 전환을 끝내며, 동작 줄이기 설정에서는 즉시 확대한다. 전환 감각은 다음 기기 시험에서 확인한다.

## M1 통합 확인

`--m1-checkpoint` 패키지는 테스트 전용 노트를 열어 파란 A 구역과 주황 B 구역에 5,000획씩 배치한다. 화면 상단에는 현재 메모리에 올린 획 수와 노트의 전체 획 수가 표시된다. A·B 버튼 옆의 구역 로드 시간은 조회·디코딩·캔버스 할당을 포함한 동기 이동 시간을 나타낸다.

1. B로 이동해 빈 곳에 별을 그리고 별을 두 번 탭한다. 확대 도중에도 탭한 지점이 유지되고 확대가 자연스럽게 이어지는지 확인한다. 올가미로 별을 옮긴 뒤 실행 취소·다시 실행하고, 지우개로 별을 지웠다가 실행 취소해 옮긴 별을 되살린다.
2. A와 B를 오가며 색과 별의 위치를 확인한다. 빠르게 팬·줌해도 이동이 끊기지 않고, 화면에 올라온 획이 노트 전체보다 훨씬 적어야 한다.
3. B에서 별을 확대하고 저장한 뒤 같은 프로젝트를 종료·재실행한다. B의 별과 배율, 획 수가 복원되는지 확인하고 **보기 → 노트 백업 내보내기**로 파일 앱에 SQLite 백업을 저장한다.

자동 검사는 카메라 좌표, 획 ID, 공간 조회와 트랜잭션 복구를 다룬다. 위 순서는 이 코드를 iPad에서 PencilKit의 실제 지우개·올가미와 연결했을 때의 동작, 전환 감각, 재실행과 파일 선택기를 함께 확인한다.

## 현재 통합 검증본

2026년 11월 22일 [실행 44983717524](https://github.com/aether0xff-afk/Reedle-s-Canvas/actions/runs/44983717524)에서 iPad 단위 75개·UI 5개가 실패·건너뜀 없이 통과했다. 로컬 소스 `1ba7e31`과 원격 소스 `4925834`의 트리는 같다. 실제 BAZE의 자동 타원 판서·정정 후 피드백, 320/512pt 배치, 네이티브 빠른 팬·핀치와 저장·재실행 복원을 포함한다. [결과 화면](native-results.md)

검증한 앱 소스 패키지는 `.build/ReedlesCanvas-Verified.zip`이며 SHA-256은 `c68a15c8286412bbad93e73a8f0723f150e76b34c2e605e7bb85bdbd7ec15b35`다. 31개 소스 파일이 현재 앱 소스와 바이트 단위로 같고 ZIP CRC와 공급자 키 부재를 확인했다. 이 파일은 소스 프로젝트이며 서명된 IPA가 아니다.

앞의 AET-32·35 사용자 실기기 피드백은 당시 빌드의 기록으로 유지한다. 현재 통합본의 물리 Pencil 지연, 기기 프레임·메모리·배터리와 실제 iPadOS 창 관리 검증은 AET-49에 남아 있다. RDP 개발 PC에는 현재 연결된 Apple USB 기기와 Apple 개발 서명이 없으며, 별도 노트북의 iPad를 자동으로 제어할 연결 경로는 아직 확보하지 못했다.
