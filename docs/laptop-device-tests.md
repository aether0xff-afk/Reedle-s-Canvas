# 노트북에서 실기기 시험하기

이 묶음은 **iPad 옆 Windows 노트북에서** 실행합니다. 기존 개발 PC에 USB를 전달할 필요는 없습니다. BAZE API 키와 Apple 계정 암호는 필요하지 않습니다. 앱은 iPad의 Swift Playgrounds에서 현재 소스를 빌드합니다. ZIP은 서명된 IPA가 아닙니다.

## 처음 한 번

1. `Reedle-Laptop-DeviceLab.zip`을 노트북의 일반 폴더에 전부 압축 해제합니다.
2. [Apple Devices](https://support.apple.com/108643)에서 iPad가 보이게 데이터 USB 케이블로 연결하고 잠금 해제·“이 컴퓨터 신뢰”를 승인합니다. iPad에는 [Swift Playgrounds](https://support.apple.com/guide/playgrounds-ipad/itc650868b1f/ipados)를 설치합니다.
3. 노트북에서 `Run-Tests.cmd`를 두 번 클릭합니다. 첫 실행은 인터넷으로 해시를 검증한 uv 0.13.9, Python 3.12와 잠근 의존성을 이 폴더에 받습니다. USB 기기 확인 후 Playgrounds Documents에 `ReedleDeviceLab-Source.zip` 복사를 시도합니다.
4. iPad 파일 앱 → 나의 iPad → Playgrounds에서 ZIP을 풀고 `ReedlesCanvas-DeviceLab.swiftpm`을 열어 실행합니다. USB 파일 공유가 지원되지 않으면 묶음의 `ReedlesCanvas-DeviceLab.swiftpm.zip`을 iCloud Drive 등으로 iPad 파일 앱에 옮겨 열면 됩니다.

여러 기기가 있으면 자동 선택하지 않습니다. PowerShell에서 `./Start-Reedle-Tests.ps1 -Udid '<기기 ID>'`로 지정합니다. 신뢰·개발자 모드·개발자 이미지 연결이 막히면 원인과 로그를 결과 ZIP에 남깁니다. 디스크 삭제나 임의 앱 종료는 하지 않습니다.

## 한 번에 실행할 시험

| 시험 | 실행 방법 | 필요한 이유·저장하는 증거 |
| --- | --- | --- |
| 1만 획 자동 부하 | iPad에서 **90초 자동 시험** | 같은 캔버스·저장 코드로 멀리 떨어진 구역을 반복 이동·확대. 실제 콜백 간격 p50/p95/최대, 앱 physical footprint, 상주 획 수와 저장 후 레코드 일치를 기록 |
| 실제 Pencil | 자동 시험 뒤 30초 동안 빠른 곡선·작은 글씨를 써 보고 **필기·복원 기준 저장** | 합성 획은 실제 Pencil 반응성을 증명하지 못함. 펜 끝과 잉크 사이 눈에 띄는 지연·끊김 여부를 한 번 기록 |
| 회전·창 크기·복귀 | 가로/세로 전환, 지원하는 분할 창 크기 변경, 홈으로 나갔다 복귀. 기준 저장 후 앱을 종료하고 **같은 프로젝트**를 재실행, 다시 기준 저장 | 실제 iPadOS 창 관리·수명 주기를 확인. 콘텐츠 크기/상태 이벤트와 다른 프로세스에서의 필기·카메라 복원 비교 기록 |
| 배터리 | 충전 케이블을 뺀 뒤 **10분 배터리 시험**. 밝기·저전력·프레임 제한 설정도 메모 | USB 충전 중 수치는 배터리 소모로 해석할 수 없음. 10분 이상 모든 표본이 unplugged이고 유효한 경우에만 전체 기기의 거친 배터리 감소량 기록 |

자동 부하 중에는 필기하지 않습니다. 새 필기를 추가하면 원본 레코드 대조가 달라집니다. 배터리 시험도 같은 부하를 실행하므로 필기 시험 전이나 후에 별도로 시작합니다. 개인 노트는 열지 않으며 `ReedleDeviceLab/Note`의 독립된 시험 노트만 사용합니다. 10,000획 생성 자체는 측정 구간 밖입니다.

콜백 간격은 측정 도구의 오버헤드를 포함하는 앱 실행 지표입니다. 실제 화면 FPS는 선택적인 DVT 수집에서 따로 기록하며 기기 전체 Core Animation 수치입니다. 앱 콜백이나 화면 녹화를 물리 Pencil 접촉부터 발광까지의 지연으로 표시하지 않습니다. 배터리 값도 전체 기기의 거친 잔량이며 앱 단독 전력이나 정밀 에너지 수치가 아닙니다. 백그라운드로 나간 자동 시험은 부분 결과로 남습니다.

## 노트북에서 자동 로그 수집

iPad 시험 화면을 앞에 띄우고 노트북 PowerShell에서:

```powershell
./Start-Reedle-Tests.ps1 -Mode Collect -Seconds 90
```

개발자 서비스가 허용되면 지정한 시험 앱의 PID로 메모리·CPU와 기기 전체 FPS를 수집하고 그 앱의 `ReedleDeviceLab/Results`만 가져옵니다. Playgrounds 미리보기의 실제 번들 ID/컨테이너가 다르거나 개발자 서비스가 불가능하면 실패 원인을 기록합니다. 이때 iPad의 내부 측정 결과를 **결과 내보내기**로 파일 앱에 저장하고 노트북으로 복사한 뒤:

```powershell
./Start-Reedle-Tests.ps1 -Mode Import -Report "$HOME/Downloads/Reedle-DeviceLab-report.json"
```

모든 실행은 `results/run-날짜/`와 같은 이름의 ZIP을 만듭니다. `summary.json`은 수행·미수행·불완전 수치를 구분하며 `manifest.json`은 파일별 해시를 담습니다. 결과는 외부 서버에 자동 전송하지 않습니다. 기기 이름·일련번호 대신 모델/OS와 식별자 해시 일부를 요약하며 기기 원시 오류 로그는 이 폴더 안에만 둡니다.

정량 Pencil 지연이 필요하면 펜 끝과 화면을 함께 찍은 **외부 고속 촬영 원본**을 보관합니다. 원본 촬영 FPS와 처음 접촉/잉크 등장 프레임 번호를 기록하면 `runner.py latency --contact-frame 100 --ink-frame 103 --fps 240`로 12.5ms, 프레임 해상도 4.17ms를 계산합니다. 재생용 슬로모션 FPS를 입력하면 잘못된 값이 됩니다.

## 돌려줄 결과

마지막 `results/run-…zip`과 다음 네 줄을 이 채팅으로 전달하면 분석을 이어갈 수 있습니다. 상세 기기 로그가 포함될 수 있으므로 공개 저장소에는 올리지 않습니다.

```text
Pencil: 눈에 띄는 지연/끊김 없음 또는 관찰한 증상
회전·창 크기 변경: 성공 또는 증상
종료·재실행: 필기와 카메라 복원 여부
밝기 / 저전력 / 프레임 제한: 설정값
```

실제 측정과 검토가 끝날 때까지 AET-49와 전체 프로젝트를 완료로 표시하지 않습니다. 스크립트 자체가 동작했다는 사실은 실기기 합격 결과가 아닙니다.

도구 기준: [pymobiledevice3 Windows/iOS 연결](https://doronz88.github.io/pymobiledevice3/latest/guides/ios17-tunnels/) · [CLI 출력 규칙](https://doronz88.github.io/pymobiledevice3/latest/guides/machine-readable-output/) · [Apple CADisplayLink](https://developer.apple.com/documentation/quartzcore/cadisplaylink) · [uv 설치](https://docs.astral.sh/uv/getting-started/installation/)
