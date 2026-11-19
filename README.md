# Reedle’s Canvas

iPadOS에서 학생과 AI가 같은 캔버스에 필기하는 학습 도구입니다. 현재는 [AET-34](https://linear.app/aethers-lab/issue/AET-34)의 데이터 계약과 [AET-32](https://linear.app/aethers-lab/issue/AET-32)의 PencilKit 입력·저장 기술 스파이크가 있습니다. AI 서버와 무한 캔버스는 아직 구현 전입니다.

## iPad 앱 스파이크

`ReedlesCanvas/`는 SwiftUI + PencilKit 앱입니다. Apple Pencil로 필기하고 손가락으로 스크롤하며 시스템 도구 선택기로 펜·지우개를 고릅니다. `PKDrawing` 전체를 앱 Documents의 `drawing.pkdrawing`에 원자적으로 저장하고 재실행 때 복원합니다. 저장 오류는 표시하며, 기존 파일을 읽지 못하면 빈 캔버스로 덮어쓰지 않습니다.

현재 캔버스는 4096×4096 포인트의 **유한한 시험 공간**입니다. 획별 ID·월드 좌표·AI 레이어와 노트 형식으로의 마이그레이션은 다음 단계입니다. 실제 기기에서 1000획과 펜 지연을 측정하기 전까지 AET-32 완료로 간주하지 않습니다.

Mac에서 `brew install xcodegen`, `xcodegen generate` 후 생성된 `ReedlesCanvas.xcodeproj`를 Xcode로 열 수 있습니다. GitHub Actions의 `iPad app build`는 macOS에서 iPad Simulator 대상의 **서명 없는 컴파일**을 검사합니다. 이 빌드 산출물은 실제 iPad에 설치할 수 없으며 기기 설치에는 별도의 서명이 필요합니다.

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
