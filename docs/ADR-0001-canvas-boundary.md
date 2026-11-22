# ADR-0001: 캔버스와 튜터의 경계

v1 설계 채택 · 2026-11-20 · [AET-34](https://linear.app/aethers-lab/issue/AET-34)

## 맥락과 결정

학생 원본 필기를 AI가 자동으로 고치거나 지우지 않으며, 팬/줌/재실행 후에도 주석은 같은 대상 옆에 있어야 한다. 캔버스의 권한과 배치는 앱이 소유한다. 모델은 이미지를 보고 대상 엔티티와 `placementIntent`를 제안할 뿐, 월드 좌표나 저장 명령을 만들지 않는다.

- 노트는 UUID `noteId`, 증가하는 정수 `revision`, 카메라, 두 배열 `userInk`와 `aiOverlay`로 표현한다. 양쪽의 bounds는 픽셀이 아닌 월드 단위다.
- `userInk`의 획은 ID, revision, 생성 시각, bounds, 색/두께/필압/상대 시각을 가진다. 객체가 바뀌면 학생의 명시적 편집 트랜잭션으로 새 revision을 만든다. AI에는 이 트랜잭션 권한을 주지 않는다.
- AI 객체는 별도 배열에 ID, 대상 ID, 출처(요청/액션/모델), 숨김 상태를 둔다. 사용자에게 AI 객체만 숨기거나 취소하는 명령을 제공한다.
- 관찰 요청은 현재 `noteId`, `canvasRevision`, `focusBounds`, 주변의 `entityIds`와 별도로 전송할 이미지 crop으로 구성한다. 원본 노트 전체를 매번 전송하지 않는다. 이미지 전송 형식은 AET-33에서 결정한다.
- 응답은 `observedRevision`, `observe_only` 또는 액션 목록을 담는다. 앱은 적용 직전에 note/revision과 target ID를 검증한다. 오래된 응답은 적용하지 않고 버리거나 다시 관찰한다. action ID를 적용 이력에 기록해 재시도 중복 판서를 막는다.
- `world → screen`은 `(world - camera.origin) × camera.scale`이다. 모든 저장 좌표는 world 기준이고 zoom 중심의 이동은 카메라만 바꾼다. 레이아웃은 대상 bounds, 기존 엔티티 occupancy, 현재 뷰포트를 사용한다.

## 계약

| 경계 | 입력 | 출력 | 권한 |
| --- | --- | --- | --- |
| 로컬 저장 | `canvas-v1.schema.json` | 원자적 노트 스냅샷 | 학생 편집으로만 userInk 변경 |
| 앱 → 서버 | `observation-v1.schema.json` + 이미지 crop | 관찰 | 읽기 전용 맥락 |
| 서버 → 앱 | `tutor-response-v1.schema.json` | 대상/의도/내용 | AI overlay 제안만 |

JSON Schema는 문서와 기본 형태 검증에 사용한다. 동일 ID 중복, bounds가 실제 획을 포함하는지, 응답 target이 현재 노트에 있는지, revision의 최신성, 악성/부적절 콘텐츠, 충돌 없는 배치 및 요청 빈도는 앱/서버의 별도 로직에서 확인한다. 서버는 API 자격증명을 보관하고 앱에 노출하지 않는다. 필기 전송, 로컬 기록과 게이트웨이 캐시의 보관 범위는 운영 문서에 정리한다. [필기 튜터 서버](tutor-gateway.md)

## 예제로 따라가는 관찰 한 번

1. 앱은 같은 노트 안에서 엔티티 UUID를 유지한다. 소유자와 레이어는 엔티티가 속한 배열로 표현한다. 예제에는 학생의 획과 그 획을 대상으로 이전에 배치한 AI 문구가 있다. AI 문구는 자신의 UUID와 버전, 출처를 가진다. [노트 예제](../examples/canvas-snapshot.json)
2. 앱은 관찰 시점의 노트 revision, 관찰할 월드 영역과 대상 UUID를 고정하고 요청 UUID를 발급한다. 서버는 이를 이미지와 함께 해석하고, 모델의 제안을 v1 응답 스키마에 대조한다. 실제 BAZE의 `gpt-6.1-terra`에서 PNG·JSON Schema·SSE 입력을 검증했다. [관찰 예제](../examples/observation.json) · [BAZE 연결 검증](baze-verification.md)
3. 앱은 응답의 노트·요청·revision과 대상을 확인하고 적용한 액션 UUID를 추적한다. 예제의 주석과 질문은 같은 획을 가리킨다. 각 액션은 앱이 위치를 정한 후 새 AI 객체가 된다. `observe_only`와 빈 액션 배열을 받으면 현재 화면을 유지한다. [튜터 응답 예제](../examples/tutor-response.json)

## 검증 전략과 빌드 경로

- 계약을 변경할 때 `python tools/validate_contracts.py`를 실행한다. 세 스키마와 예제를 검사하고, 좌표 주입·학생 획 삭제 요청·관찰 전용 응답에 포함된 액션·잘못 연결된 응답이 거부되는지 확인한다. [계약 검사](../tools/validate_contracts.py)
- 앱에서는 좌표 왕복 오차와 앵커 위치를 검사하고, 필기 저장과 복원을 XCTest로 검증한다. 서버 통합 시에는 지연된 응답과 동일 요청 재시도를 발생시켜 학생 원본 보존과 AI 판서 중복 방지를 확인한다. 실제 펜 반응성과 앱 종료·재실행은 iPad에서 확인한다. [실기기 절차와 필기 복원 결과](ipad-device-spike.md)
- Windows에서는 WSL2·xtool로 기기 빌드를 검증한다. 기기 연결이 RDP 경계 밖에 있을 때는 같은 소스를 Swift Playground 패키지로 만들어 iPad에서 실행한다. WSL의 SDK나 서명 도구가 맞지 않으면 Mac에서 XcodeGen으로 프로젝트를 생성하고 개발 팀을 선택해 서명·설치한다. macOS CI에서는 시뮬레이터 회귀 검사를 실행한다. [기기 빌드 절차](ipad-device-spike.md) · [CI 구성](../.github/workflows/ios-build.yml)

## 검증 대기

2026년 11월 22일 기준 Linear의 23개 항목 중 22개가 완료됐다. GitHub의 Mac에서 iPad 단위 테스트 75개와 UI 테스트 5개가 실패·건너뜀 없이 통과했다. 실제 SwiftUI 판서 애니메이션, 20페이지 PDF 내보내기, 1만 획 페이지 로딩, 좁은 도구 배치, 빠른 팬·핀치, 실제 BAZE 응답의 자동 판서·수정·복원을 확인했다. 같은 실행의 서버 66개·평가 19개·실행 도구 4개·암호화 전달 8개 검사도 통과했다. [iPad 자동 검사 결과](https://github.com/aether0xff-afk/Reedle-s-Canvas/actions/runs/44983717524) · [검증 기록](../evaluation/results/native-2026-11-22.json) · [실제 필기 60개 모델 평가](evaluation.md)

| 항목 | 확인한 범위 | 남은 검증 |
| --- | --- | --- |
| AET-42 완료 | 실제 경로·글자 순차 등장, 입력 재개·동작 줄이기·숨김·복원·undo | 물리 Pencil 지연은 AET-49에 포함 |
| AET-48 완료 | 실제 PencilKit PNG·BAZE HTTPS/SSE·pen-up 자동 판서·수정 피드백·복원 | 물리 측정은 AET-49에 포함 |
| AET-49 진행 중 | 시뮬레이터 1만 획 시간·CPU·메모리, 회전·백그라운드·재실행, 320/512pt 배치, 빠른 팬·핀치와 복원 | 물리 Pencil 지연·기기 프레임·메모리·배터리, 실제 iPadOS 창 관리 |

GitHub 연결을 갱신한 뒤 저장소 소유자 권한으로 `codex/canvas-camera` 브랜치를 올려 macOS 자동 검사를 실행했다. 검증한 앱 소스 패키지는 `.build/ReedlesCanvas-Verified.zip`에 있다. BAZE 키는 Windows 계정 암호화로 저장했고 Codex와 Canvas 서버에서 실제 요청을 확인했다. AET-33·44·50의 연결·인식 품질 기록·평가 작업을 완료했다. 실제 모델은 오탐 2건과 오류 누락 5건이 있어 수동 질문 모드를 권고하며, 운영용 자동 개입 임계값은 확정하지 않았다. 물리 공개 필기 자료는 회로 기호에 한정되며, 오류 사례가 없어 개입 누락률을 평가하려면 추가 자료가 필요하다. [기기 검증 경로](ipad-device-spike.md#aet-31-검증-결과와-빌드-경로) · [평가 자료와 실측](evaluation.md) · [키와 비용 검증](baze-verification.md)

AET-31은 WSL 기기 빌드 실패를 기록하고 원격 macOS 빌드 경로를 선택했다. AET-32의 PencilKit 직렬화와 1,000획 복원, AET-35의 카메라 동작은 이전 버전에서 실기기로 확인했다. AET-38 저장 복구와 AET-45 정책 검증은 자동 검사 결과로 완료했다. [기기 검증 결과](ipad-device-spike.md) · [게이트웨이 검증](tutor-gateway.md)
