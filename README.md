# Reedle’s Canvas

iPadOS에서 학생과 AI가 같은 캔버스에 필기하는 학습 도구입니다. 현재는 [AET-34](https://linear.app/aethers-lab/issue/AET-34)의 데이터 계약과 [AET-32](https://linear.app/aethers-lab/issue/AET-32)의 PencilKit 입력·저장 기술 스파이크가 있습니다. AI 서버와 무한 캔버스는 아직 구현 전입니다.

## iPad 앱 스파이크

`ReedlesCanvas/`는 SwiftUI + PencilKit 앱입니다. Apple Pencil로 필기하고 손가락으로 스크롤하며 시스템 도구 선택기로 펜·지우개를 고릅니다. `PKDrawing` 전체를 앱 Documents의 `drawing.pkdrawing`에 원자적으로 저장하고 재실행 때 복원합니다. 저장 오류는 표시하며, 기존 파일을 읽지 못하면 빈 캔버스로 덮어쓰지 않습니다.

현재 캔버스는 4096×4096 포인트의 **유한한 시험 공간**입니다. 획별 ID·월드 좌표·AI 레이어와 노트 형식으로의 마이그레이션은 다음 단계입니다. 실제 기기에서 1000획과 펜 지연을 측정하기 전까지 AET-32 완료로 간주하지 않습니다.

Mac에서 `brew install xcodegen`, `xcodegen generate` 후 생성된 `ReedlesCanvas.xcodeproj`를 Xcode로 여세요. `ReedlesCanvas` 스킴과 iPad 시뮬레이터를 선택하고 ⌘U로 테스트합니다. GitHub Actions의 `iPad app build`도 같은 스킴을 실행합니다.

복원 테스트는 펜과 마커를 섞은 합성 1,000획을 파일에 저장하고 새 문서에서 엽니다. 획 순서와 위치, 색, 굵기, 필압, 기울기, 시각을 대조합니다. 별도의 테스트로 손상 파일의 원본 보존과 저장 실패 후 캔버스를 다시 열어 재저장하는 경로를 확인합니다.

실기기에서는 Xcode에서 개발 팀을 선택해 서명·설치한 뒤 다음 순서로 확인합니다.

1. Apple Pencil로 색과 굵기를 바꿔 가며 1,000획을 입력합니다. 화면의 획 수와 시작·중간·마지막 영역의 필기를 기록합니다.
2. 앱을 홈 화면으로 보낸 후 종료하고 다시 엽니다. 획 수, 세 영역의 위치와 스타일을 기록과 대조합니다.
3. 120Hz 지원 iPad에서 긴 연속 획을 그을 때 펜 끝과 잉크 사이의 지연이나 끊김을 관찰합니다. 기기 모델, iPadOS 버전, 저전력 모드 상태를 결과와 함께 기록합니다.

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
