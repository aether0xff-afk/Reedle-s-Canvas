# Reedle’s Canvas

iPadOS에서 학생과 AI가 같은 무한 캔버스에 필기하는 학습 도구입니다. 현재는 [AET-34](https://linear.app/aethers-lab/issue/AET-34)에 해당하는 데이터 계약 초안과 검증 예제를 제공합니다. 앱과 서버는 아직 구현 전입니다.

## 첫 수직 슬라이스

1. Apple Pencil 획을 월드 좌표의 `userInk`로 저장하고 다시 엽니다.
2. 변경 영역만 AI에 관찰시킵니다. AI는 대상 객체와 의도를 반환합니다.
3. 앱이 충돌 없는 위치를 결정해 별도 `aiOverlay`에 판서합니다.
4. 학생이 답을 고치면 새 revision을 관찰하고 이전 주석과 연결합니다.

`userInk`는 학생 편집 명령만 변경할 수 있습니다. AI의 응답은 좌표, 삭제, 수정 명령을 포함하지 않습니다. 응답의 대상 ID와 관찰 revision은 앱에서 다시 확인해야 합니다.

## 계약 확인

```bash
python -m pip install jsonschema
python tools/validate_contracts.py
```

계약과 미검증 기술 선택은 [ADR-0001](docs/ADR-0001-canvas-boundary.md)에 있습니다. iPad 빌드, PencilKit 저장, BAZE 이미지 API는 각각 Linear의 AET-31, AET-32, AET-33에서 실제 기기로 확인합니다.
