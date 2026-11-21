# BAZE 실제 연결 검증

2026년 11월 21일 사용자 계정의 BAZE API 키로 모델 목록과 실제 모델 호출을 확인했다. 키를 발급한 배포의 주소는 `https://api.baze.co/v1/gateway`이며, 다른 BAZE 배포의 키와 호환되지 않는다. [공식 에이전트 설정](https://docs.factchat.kr/agent-setup/prompt.md)

## Codex 설정과 키 보관

Codex의 사용자 설정에서 `model_provider = "factchat"`, `model = "gpt-6.1-terra"`, `wire_api = "responses"`를 사용한다. `base_url`에는 `/responses`를 붙이지 않는다. 기존 설정은 백업하고 다른 플러그인과 프로젝트 설정은 보존했다. 새 Codex 세션에서 이 설정을 읽으며 이미 실행 중인 대화의 제공사를 바꾸지는 않는다.

키는 Windows CurrentUser DPAPI로 암호화해 저장한다. Codex는 공식 `model_providers.factchat.auth.command` 설정으로 로컬 인증 보조 스크립트를 실행하고, 스크립트는 복호화한 키를 Codex의 인증 파이프로만 전달한다. 설정 파일과 PowerShell 프로필에는 키 원문을 쓰지 않는다. PowerShell에서는 암호화 파일을 읽는 로더로 서버의 환경 변수도 설정한다. [Codex 외부 인증 명령](https://learn.chatgpt.com/docs/config-file/config-advanced)

인증 검증에서는 자식 프로세스의 `BAZE_API_KEY` 환경 변수를 제거한 상태로 Codex CLI를 실행했다. 인증 보조 명령을 통해 BAZE의 `gpt-6.1-terra`가 지정한 확인 문구를 반환했고 종료 코드는 0이었다. 모델 목록에는 전체 125개, LLM 55개가 있었다. 사용량은 키를 발급한 BAZE 계정에 청구된다.

Canvas 서버의 앱 접속 토큰은 BAZE 키와 별도로 생성하고 같은 Windows 암호화 저장 방식으로 보관했다. 앱에는 서버 접속 토큰만 제공하며 BAZE 키는 제공하지 않는다. 키와 로컬 보조 스크립트는 저장소 밖에 있고 원본 필기 평가 자료와 원시 응답은 Git에서 제외한 `.build/`에 둔다.

Mac 시뮬레이터의 실제 모델 검사는 실행마다 RSA 3,072비트 키 쌍을 만든다. 공개키 artifact의 실행 ID·소스 커밋·ZIP SHA-256과 공개키 지문을 확인한 뒤 RSA-OAEP-SHA256으로 BAZE 키를 암호화해 전달한다. 공개 암호문은 해당 실행 ID와 공개키에 묶이며 전달 파일을 활성 브랜치에서 제거해도 커밋 이력에는 남는다. 해독에 필요한 개인키는 Mac 런너에만 두고 실행 종료 시 삭제한다. 이 경로는 외부 터널과 SSH 접속이 시간 초과된 뒤 선택했다.

Mac에서 해독한 BAZE 키는 메모리에서 읽어 로컬 게이트웨이 자식 프로세스의 환경에만 제공한다. Xcode와 iPad 테스트 앱에는 별도 접속 토큰과 루프백 HTTPS 주소를 전달한다. 공급자 호출은 실행당 최대 6회로 제한한다. 시뮬레이터에만 테스트 인증서를 신뢰하도록 설정하며, `finally`에서 게이트웨이 종료와 개인키·TLS 키·앱 테스트 토큰 파일 삭제를 수행한다. 잘못된 실행·공개키 지문·암호문 변조·토큰 형식과 실패 시 정리를 로컬 검사로 확인했다. [Mac 검사 실행 도구](../tools/run_live_ipad.py)

## 실제 PNG와 스트리밍

`gpt-6.1-terra`에 수학 수식, 루이스 구조, 회로 PNG를 하나씩 전송했다. 실제 로컬 HTTPS 서버와 BAZE HTTPS를 통과했으며, 양쪽 모두 앱과 같은 SSE 경로를 사용했다. 세 입력 모두 과목, 전사, 신뢰도, 관찰 대상 ID와 판정을 담은 유효한 JSON Schema 응답을 반환했다. 대상 연결은 3/3이었고 저신뢰도 개입은 없었다. 이 세 사례는 모두 개입이 필요하지 않은 입력이다.

| 사례 | 과목 | 첫 초안 알림 | 검증된 최종 응답 |
| --- | --- | ---: | ---: |
| `math-real-03` | 수학 | 6,430 ms | 6,895 ms |
| `chemistry-real-01` | 화학 | 3,107 ms | 3,858 ms |
| `physics-real-03` | 물리 | 3,539 ms | 3,784 ms |

첫 호출에서 BAZE가 후속 청크의 역할을 `role: null`로 명시하는 것을 확인했다. 서버가 이를 거부하던 호환성 오류를 수정했다. 동일 입력 형식을 재현한 회귀 검사는 수정 전에 실패했고 수정 후에 최종 액션과 사용량까지 통과했다. 서버 검사 65개와 평가 도구 검사 19개가 통과했다. 미완료 스트림, 출력 잘림, 도구 호출과 잘못된 대상은 계속 판서로 적용하지 않는다.

세 사례의 인식 품질과 전체 60개 실제 필기 평가는 [평가 기록](evaluation.md)에 별도로 기록한다. 유효한 구조화 응답이 실제 필기를 정확히 읽었다는 뜻은 아니며, 원본 평가 라벨을 그대로 사용해 채점한다.

## 비용과 제한

이 계정에서 조회한 `gpt-6.1-terra`의 단가는 입력 100만 토큰당 USD 1, 출력 100만 토큰당 USD 5, 캐시 읽기 100만 토큰당 USD 0.05였다. 세 연결 검증의 합은 입력 3,544토큰, 출력 791토큰이다. 캐시 할인 없이 계산한 모델 정가 예상액은 USD 0.007499다. 모델 목록의 문맥 한도는 1,050,000토큰, 출력 한도는 128,000토큰이다. [모델과 단가](https://docs.factchat.kr/docs/general/api-gateway/getting-started/models)

이 계정의 실제 응답에는 `billing` 블록이 없어 서버 비용 로그의 `cost_usd`와 `deducted_credit`는 `None`이었다. 일간 `/usage/?scope=key&by=model` 조회는 성공했다. 이 집계에는 같은 키로 실행한 Codex 확인 요청과 모든 평가 호출이 함께 들어가므로 세 이미지의 실제 차감 크레딧으로 간주하지 않는다. 실제 원화 환산과 크레딧 단가는 계정 설정에 따른다. [청구 필드](https://docs.factchat.kr/docs/general/api-gateway/reference/pricing) · [사용량 집계](https://docs.factchat.kr/docs/general/api-gateway/reference/usage)

BAZE가 공개한 제한은 회원당 60초에 120건, 요청 본문 25MB다. Canvas는 PNG 512 KiB, 가장 긴 변 1,280픽셀, 관찰 요청 본문 750,000바이트와 대상 128개로 제한한다. 기본 설정은 시도당 7초, 최대 2회, UTC 하루 100회 시도다. 재시도도 일간 한도에 포함하며 운영자가 더 낮게 설정할 수 있다. [BAZE 호출 제한](https://docs.factchat.kr/docs/general/api-gateway/getting-started/overview#호출-제한) · [서버 설정](../server/README.md)

429와 일시적인 5xx는 제한된 재시도와 회로 차단기로 처리한다. 긴 `Retry-After`는 대기 루프를 만들지 않고 클라이언트에 전달한다. 시간 초과, 스트림 중단과 잘못된 JSON은 학생 잉크를 변경하지 않는다. 로그에는 상태·시간·숫자 토큰 및 청구 필드만 기록하며 키나 입력 이미지, 원시 제공사 응답을 기록하지 않는다. 실제 검증 출력과 Git 추적 파일에서 API 키 원문이 없음을 확인했다.
