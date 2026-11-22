# 완료 조건 대조

2026년 11월 22일 Linear 프로젝트 P-AET-5의 원래 작업·완료 기준을 다시 읽고 구현과 실행 증거를 대조했다. Linear 상태는 22/23 완료이며, 전체 프로젝트 완료는 아직 증명되지 않았다.

전체 네이티브 기준 실행은 [44983717524](https://github.com/aether0xff-afk/Reedle-s-Canvas/actions/runs/44983717524)이다. Xcode 26.6, iPad mini(A17 Pro), iPadOS 26.5에서 단위 75개와 UI 5개가 실패·건너뜀 없이 통과했다. 같은 실행의 서버 66개·평가 19개·실행 도구 4개·암호화 전달 8개 검사도 통과했다. [현재 실측 기록](../evaluation/results/native-2026-11-22.json)은 실행 커밋과 검증 범위를 담는다. 실제 네이티브 팬·핀치 UI 경로와 복원도 이 실행에서 확인했으며, 아래 기기 지표는 시뮬레이터 결과로 대체하지 않는다. [결과 화면과 검증 범위](native-results.md)

| 항목 | 확인한 구현·대표 증거 | 범위와 남은 조건 |
| --- | --- | --- |
| AET-31 빌드 경로 | [기기 기술 기록](ipad-device-spike.md), 현재 Mac 네이티브 빌드 | WSL 실패 뒤 Mac 대안을 선택한다는 조건 충족 |
| AET-32 PencilKit 스파이크 | 이전 사용자 실기기 1,000획 복원·120Hz 관찰 기록, `DrawingDocumentTests`의 1,000획 기하·시간·스타일 복원 | 스파이크의 기기 피드백이며 최신 버전의 물리 지연 계측은 AET-49 |
| AET-33 BAZE 검증 | [키·호출·비용 기록](baze-verification.md), 실제 PNG 3개·실제 필기 60개, 실제 네이티브 HTTPS/SSE | 공급자 키는 서버 전용. ZIP 전체 키 부재 검사와 런너 임시 키 정리 확인 |
| AET-34 데이터 계약 | [ADR](ADR-0001-canvas-boundary.md), `contracts/`, `examples/`, `tools/validate_contracts.py` | 클라이언트 좌표·UUID·소유권·레이어·revision 경계와 대체 빌드 문서화 |
| AET-35 카메라 | `CanvasCameraTests`의 먼 좌표 왕복·앵커 줌·반복 제한·슬라이딩 표면·줌 중단, 네이티브 핀치와 양축 빠른 팬 | 위치 복귀·저장·재실행 뒤 잉크 범위와 픽셀 수 일치 |
| AET-36 획·편집 | `DrawingDocumentTests`, `StrokeIdentityLedgerTests`, `PencilCanvasView`의 Pencil 전용 필기·손가락 탐색 | 획 순서·기하·필압·시간·ID와 페이지 이동 후 undo/redo 검증 |
| AET-37 공간 인덱스 | `NoteStoreTests`, `PagedCanvasStressTests`의 100개 클러스터·1만 획과 빈 영역 탐색 | 페이지 쿼리·상주 획 수·메모리 측정. 물리 프레임 지표는 AET-49 |
| AET-38 저장·복구 | `NoteStoreTests`의 강제 종료·transaction rollback·독립 백업, `DrawingDocumentTests`의 저장 실패/잠금 후 자동 복구 | 필기·카메라·AI 표시 상태 보존 |
| AET-39 AI 레이어 | `TutorLayerTests`, `TutorAnimationTests`, 실제 자동 판서 전후 학생 저장 기록 대조 | AI batch만 undo/hide, 중복 ID·오래된 revision/epoch 차단 |
| AET-40 앵커·배치 | `TutorPlacement` 및 배치 검사, 화면/PDF 렌더링과 실제 잘못된 5의 획 ID | 빈 공간 탐색·겹침 방지·배치 실패 처리 |
| AET-41 판서 렌더러 | `TutorMathTests`, `TutorAnimationTests`, `NotePDFTests`, 실제 타원 주석과 전체 앵커 여백 검사, [표현·필기형 비교](tutor-rendering.md) | 분수·근호·첨자·허용 도형과 동일 출력. 필기형 비교는 앱에 적용된 스타일로 표시하지 않음 |
| AET-42 애니메이션 | 실제 UIHostingController/Canvas의 중간 경로·글리프 픽셀, 입력 재개·동작 줄이기·숨김·복원 | 제어한 검사 시간과 시스템 실행 시간을 분리하여 검증 |
| AET-43 관찰 트리거 | `TutorCaptureTests`, 실제 `TutorAssistant.inkChanged` 연속 검사 | pen-up 대기·dirty crop·중복 hash·호출 간격·조용히 모드 |
| AET-44 인식 | [실제 60개 평가](evaluation.md), 실제 native 5→4 인식, 낮은 신뢰도 정책 검사 | 품질 수치를 기록한 것이며 모든 필기의 정확성을 보장하지 않음 |
| AET-45 행동 스키마 | 서버 회귀 66개, 계약 검사, 클라이언트 원시 응답/액션 검증 | 임의 좌표·학생 삭제·잘못된 대상·불완전한 스트림 거부, observe_only 정상 처리 |
| AET-46 맥락 | 실제 수정 전후 두 관찰과 후속 피드백, `TutorCaptureTests`의 동일 풀이·다른 과목/영역·신뢰도 조건 | 인접 관찰만 제한 수로 전송, 학습 통계 별도 보관 |
| AET-47 장애·비용·개인정보 | 서버 timeout/retry/circuit/daily budget 검사, 클라이언트 중단과 HTTP 연동 검사 | 실패 응답이 학생 저장 경로를 수정하지 않음. 실제 키는 로그·앱에서 제외 |
| AET-48 연속 데모 | `TutorLiveGatewayTests`의 실제 PencilKit·BAZE·자동 판서·학생 수정·후속·재실행 | 별도 승인 없는 실제 assistant 경로 확인. 사용자 지시에 따라 시뮬레이터 사용 |
| AET-49 UX·실기기 | 회전·백그라운드·재실행, 320/512pt 도구, 1만 획 시간·CPU·메모리, 네이티브 고속 팬·핀치와 복원 | **미완료:** 실제 Pencil 물리 지연, 기기 프레임・메모리・배터리와 iPadOS 기기 창 관리. RDP 호스트에서 연결된 iPad가 발견되지 않음 |
| AET-50 평가셋 | 수학/화학/물리 각 20개 실제 필기와 익명 라벨·false positive·latency 리포트 | 물리 표본은 회로에 한정되고 오류 양성 예가 없어 누락률 미정. 자동 개입의 운영 임계값은 확정하지 않음 |
| AET-51 연습문제 | `PracticeEngineTests`, `PracticeUITests`, `NoteResourceStoreTests` | 이전 풀이의 과목·연산에 연결한 새 문제, 단계별 힌트·정답 제어·채점·약점 통계·복원 |
| AET-52 PDF·자료 | `NotePDFTests`, `NoteResourceStoreTests`, 20페이지 원문·학생 획·AI 출력의 보존/내보내기 | 문제 PDF를 튜터 이미지에 포함하고 검색·자료 링크·PDF/이미지 내보내기 지원 |
| AET-53 운영·개인정보 | 튜터 설정·조용히/중지·크기·색·민감도·기록 조회/삭제와 [개인 설치 서명 안내](ipad-device-spike.md) | 사용자 전송 동의·보관 안내·삭제 epoch·백업·갱신 문서화 |

현재 RDP 호스트의 연결된 Apple USB 기기는 0개다. 사용자는 별도 Windows 노트북 옆에 iPad와 Pencil을 보유하고 있고, 그 노트북에서 실행할 ZIP을 이 채팅으로 받기로 했다. [노트북 시험 도구](laptop-device-tests.md)는 iPad의 Swift Playgrounds에서 동일 소스를 실행하고 측정 JSON을 내보내는 경로와 선택적인 USB 진단·수집 경로를 제공한다. 실제 노트북·iPad 결과를 받고 원래 완료 조건에 대조하기 전에는 전체 완료로 표시하지 않는다.
