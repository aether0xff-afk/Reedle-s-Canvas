# ADR-0001: 캔버스와 튜터의 경계

상태: 초안 · 2026-11-19 · [AET-34](https://linear.app/aethers-lab/issue/AET-34)

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

JSON Schema는 문서와 기본 형태 검증에 사용한다. 동일 ID 중복, bounds가 실제 획을 포함하는지, 응답 target이 현재 노트에 있는지, revision의 최신성, 악성/부적절 콘텐츠, 충돌 없는 배치 및 요청 빈도는 앱/서버의 별도 로직에서 확인한다. 서버는 API 자격증명을 보관하고 앱에 노출하지 않는다. 이미지와 대화의 보존 정책은 아직 정하지 않았다.

## 검증 대기

- [AET-31](https://linear.app/aethers-lab/issue/AET-31): Windows/WSL2에서 실제 iPad 빌드와 설치 가능 여부
- [AET-32](https://linear.app/aethers-lab/issue/AET-32): PencilKit 획 직렬화와 1000획 복원
- [AET-33](https://linear.app/aethers-lab/issue/AET-33): BAZE 이미지 입력, 응답, 비용과 지연
- [AET-35](https://linear.app/aethers-lab/issue/AET-35), [AET-38](https://linear.app/aethers-lab/issue/AET-38), [AET-45](https://linear.app/aethers-lab/issue/AET-45): 좌표 정밀도, 저장 트랜잭션, 튜터 정책 상세화
