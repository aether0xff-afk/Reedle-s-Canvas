# 기존 iPad 충돌 기록 수집

90초/10분 시험에서 이미 발생한 충돌의 원인을 찾는 묶음입니다. 새 시험이나 앱 재설치는 실행하지 않습니다. 기기에 남아 있는 최근 앱 충돌과 메모리 종료 기록을 노트북으로 복사합니다.

1. 노트북에 이 ZIP을 압축 해제합니다. 원래 시험 폴더에 풀면 기존 `.uv` 런타임을 재사용할 수 있습니다.
2. iPad를 USB로 연결하고 잠금을 해제합니다. **Diagnose-Crash.cmd**를 두 번 클릭합니다.
3. 생성된 **results/run-…zip**을 이 채팅으로 보내주세요. 90초/10분 버튼은 누를 필요가 없습니다.

첫 실행은 인터넷으로 검증된 로컬 Python 환경을 준비합니다. 수집기는 현재 날짜의 전후 하루에 해당하는 Reedle/DeviceLab/AppModule/Playground 충돌을 최대 6개, 메모리 종료(JetsamEvent) 기록을 최대 2개 복사합니다. 기기의 원본 기록을 삭제하지 않습니다. 관련 앱의 번들 ID도 함께 확인해 앞선 소스 전송 실패를 진단합니다. 개인 앱 목록 전체와 개인 앱의 파일 컨테이너는 저장하지 않습니다.

충돌 파일에는 기기와 프로세스 정보가 들어갈 수 있으므로 결과 ZIP은 공개 저장소에 올리지 않습니다. 수집 결과가 0개이면 기존 Swift Playgrounds 충돌 화면의 **Show Backtrace / 역추적 표시** 내용을 저장해 전달해주세요. 콘솔이 비어 있어도 충돌 역추적은 별도로 남을 수 있습니다. [Apple의 iPad 충돌 화면 안내](https://support.apple.com/en-ca/guide/playgrounds-ipad/itc650868b1f/ipados)

이 묶음은 진단 수집 도구이며 앱 충돌을 수정한 버전은 아닙니다. 전체 진행률은 22/23개이고 AET-49의 실기기 충돌 해결·재검증이 남아 있습니다.

## 노트북 직접 조사 경로

에이전트가 노트북에서 작업하는 경우 수집·분석·소스 패키징은 에이전트가 맡으며,
사용자에게 ZIP을 복사하거나 명령을 반복 실행하도록 요청하지 않는다.
현재 조사와 미검증 범위는 [2026-11-22 기기 세션 기록](ipad-device-session-2026-11-22.md)에 있다.

Diagnose는 USB 조회 전에 Windows의 기존 Apple CrashReporter 동기화 폴더에서
최근 관련 기록을 읽는다. 로컬 Apple USB 서비스 소켓 접근이 `10013`으로 거부되면
`blocked_host_transport`를 기록한다. 이는 잠금·신뢰 실패나 기기 미연결의 증거가 아니다.
기기 보안 설정을 해제하지 않고 USB 서비스에 접근 가능한 실행 환경에서 이어간다.

`crash-analysis.json`과 `synced-crash-analysis.json`은 **로컬 검토용**이며 공개 전 별도
가림 검토가 필요하다. 예외·종료 사유·충돌 스레드·최대 64개 프레임을 추출하되
스택이나 특정 프로세스 종료 근거가 없으면 원인을 확정하지 않는다. Image Playground는
Swift Playgrounds와 구분한다. 이미 받은 파일은 USB 없이 다음 경로로 분석할 수 있다:

```powershell
python runner.py analyze-crash --report 'path/to/AppModule.ips'
```

수집·분석은 원본을 수정하거나 삭제하지 않는다. 새 시험 앱은
`ReedleDeviceLab/Results/Sessions/<run_id>/`에 회차별 보고서와 동기화된 단계 기록을 남긴다.
마지막 단계는 실패 구간을 좁히는 자료이고 충돌 원인 확정 자료를 대신하지 않는다.
