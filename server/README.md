# Reedle Tutor Gateway

iPad의 관찰 요청을 받아 BAZE로 현재 필기 영역을 읽고, 검증된 제안을 앱에 반환합니다. 앱은 HTTPS 게이트웨이 주소와 `REEDLE_CLIENT_TOKEN`만 사용합니다. `BAZE_API_KEY`는 서버 환경에서 관리합니다.

## 실행과 검증

Python 3.11 이상과 `uv`가 필요합니다. 아래 명령은 저장소 루트에서 실행합니다.

```sh
uv run --directory server --locked pytest -q
uv run --directory server --locked --no-dev uvicorn reedle_server.app:app --host 127.0.0.1 --port 8000
```

테스트는 로컬 ASGI 요청과 가짜 BAZE 응답으로 동작합니다. 두 PNG 관찰로 `2+2=5`에 힌트를 주고, 같은 노트에서 이어 쓴 `4`를 확인하는 흐름을 검증합니다. 2026년 11월 21일 실제 BAZE의 `gpt-6.1-terra`에서 PNG 입력, `response_format.json_schema`, SSE 스트리밍을 함께 확인했고 실제 필기 60개의 인식·개입·지연을 측정했습니다. [실제 연결 검증](../docs/baze-verification.md) · [평가 결과](../docs/evaluation.md#실제-baze-평가-결과--2026-11-21)

로컬 예시는 루프백 HTTP에서 실행합니다. iPad에서 연결할 때는 Uvicorn 앞에 HTTPS 서버를 두고 해당 HTTPS 주소를 앱에 입력합니다.

| 환경 변수 | 값 |
| --- | --- |
| `REEDLE_CLIENT_TOKEN` | 필수. 앱과 서버에서 공유하는 별도 토큰 |
| `BAZE_API_KEY` | 필수. 서버에서만 사용하는 BAZE API 키 |
| `BAZE_MODEL` | 필수. 이미지 입력과 JSON Schema 출력이 가능한 모델 ID |
| `BAZE_BASE_URL` | 기본값 `https://factchat-cloud.mindlogic.ai/v1/gateway`. 서버에서 `/chat/completions/`를 추가 |
| `REEDLE_BUDGET_DB` | 기본값 `server/.reedle-attempts.sqlite3` (위 실행 명령 기준). 재시작 후에도 유지되는 파일 경로 |
| `REEDLE_DAILY_ATTEMPT_LIMIT` | UTC 날짜별 BAZE 시도 수. 기본값 100. `0`이면 호출 비활성화 |
| `REEDLE_PROVIDER_TIMEOUT_SECONDS` | 한 번의 시도 제한 시간. 기본값 7초 |
| `REEDLE_PROVIDER_MAX_ATTEMPTS` | 재시도를 포함한 최대 시도 수. 기본값 2 |
| `REEDLE_PROVIDER_MAX_OUTPUT_TOKENS` | BAZE 시도당 출력 상한. 기본값 1,200 |
| `REEDLE_REPLY_CACHE_SECONDS` | 완료 응답의 메모리 보관 시간. 기본값 300, 최대 900. `0`이면 완료 응답을 보관하지 않음 |

키를 `api.baze.co`에서 발급했다면 `BAZE_BASE_URL=https://api.baze.co/v1/gateway`를 명시합니다. 키는 발급한 배포에서만 동작합니다. 이번에 검증한 모델 ID는 `gpt-6.1-terra`입니다. [배포별 설정](https://docs.factchat.kr/agent-setup/prompt.md)

## 관찰 엔드포인트

`POST /v1/tutor/observe`는 `Authorization: Bearer <REEDLE_CLIENT_TOKEN>`과 `Content-Type: application/json`을 받습니다. 본문의 `observation`은 [관찰 계약](../contracts/observation-v1.schema.json)을 따릅니다. `image`에는 최대 512 KiB, 가장 긴 변이 1,280픽셀 이하인 단일 PNG의 Base64 값을 보냅니다. `entities`에는 현재 이미지의 `id`, `x`, `y`, `width`, `height`를 정규화된 좌표로 보냅니다. 선택 항목 `recent`에는 더 이른 revision의 텍스트 관찰을 최대 3개 보낼 수 있습니다. 요청 본문 한도는 750,000바이트입니다.

HTTP 200 응답의 `response`는 [튜터 응답 계약](../contracts/tutor-response-v1.schema.json)을 따릅니다. `model`, `reason`, `recognition`이 함께 돌아옵니다. 유효한 제안은 현재 관찰에서 읽은 대상만 가리킵니다. 인식 신뢰도가 0.82 미만이거나 과목이 `unknown`이거나 모델 응답이 유효하지 않으면 `observe_only`를 반환합니다.

앱은 `Accept: text/event-stream`으로 스트리밍을 요청합니다. `progress` 이벤트에는 `reading` 또는 `drafting` 단계만 들어갑니다. `result` 이벤트에는 검증이 끝난 JSON 응답 전체가 들어갑니다. 스트림 중 오류는 `error` 이벤트의 `status`와 초 단위 `retryAfter`로 전달합니다. HTTPS 프록시는 각 이벤트를 받는 대로 앱에 전달하도록 버퍼링을 끕니다.

성공 응답은 프로세스의 최대 128개 항목 캐시에서 기본 5분간 재사용됩니다. 만료 시 트래픽이 없어도 메모리에서 지웁니다. 처리 중인 동일 요청은 BAZE 호출을 공유합니다. 캐시나 진행 중인 요청의 ID가 같고 입력이 바뀌면 409 오류를 반환합니다. 캐시와 회로 차단기는 워커별로 동작하므로 단일 워커로 실행합니다. SQLite는 UTC 날짜와 BAZE 시도 수만 저장하며 재시도도 한도에 포함합니다. 기본 Uvicorn 로그에는 시도 순번, HTTP 상태, 지연과 숫자로 검증한 토큰 사용량이 남습니다. BAZE가 청구 정보를 제공하면 `cost_usd`와 `deducted_credit`도 기록합니다. [BAZE 청구 필드](https://docs.mindlogic.ai/docs/general/api-gateway/reference/pricing)

마지막 클라이언트 연결이 닫히면 서버도 진행 중인 작업과 재시도를 중단합니다. 같은 응답을 기다리는 연결이 남아 있으면 작업을 이어갑니다. 이미 BAZE로 전송한 호출은 취소 뒤에도 제공사에서 처리되거나 청구될 수 있습니다. 앱은 429와 5xx에 제공되는 `Retry-After`를 지키며, 연결 실패가 반복되면 요청 간격을 늘립니다.

BAZE 키를 교체할 때는 서버의 `BAZE_API_KEY`를 새 값으로 설정하고 프로세스를 재시작합니다. 앱의 접속 토큰은 별도로 유지하거나 `REEDLE_CLIENT_TOKEN`과 앱 설정을 함께 갱신합니다.

## BAZE 검증과 비용 측정

조직의 `GET /v1/gateway/models/?type=llm` 목록에서 이미지 입력과 JSON Schema 응답을 지원하는 모델을 고릅니다. BAZE가 공개한 게이트웨이 한도는 회원당 60초 120건, 요청 본문 25MB입니다. Reedle은 관찰 요청을 750,000바이트와 PNG 512 KiB로 제한하고 기본 설정에서는 시도당 7초, 요청당 최대 두 번, UTC 하루 100회 시도로 제한합니다. 세 건으로 연결을 확인할 때는 기본 설정에서 최대 여섯 번의 공급자 시도를 사용합니다. [BAZE 모델 목록](https://docs.mindlogic.ai/docs/general/api-gateway/getting-started/models) · [BAZE 호출 제한](https://docs.mindlogic.ai/docs/baze/api-gateway/getting-started/overview#호출-제한)

비용은 전용 평가 키로 실행한 뒤 `baze_attempt` 로그의 차감 크레딧과 같은 키의 `/usage/` 집계를 확인합니다. 기본 단가로 예산을 잡을 때는 모델 목록의 백만 토큰당 입력·출력 단가에 관측한 각 토큰 수를 곱해 합산합니다. 실제 크레딧에는 조직 단가와 환율이 반영됩니다. `billing`을 받지 못한 호출은 로그에 `None`으로 남으므로 실제 차감은 키 사용량으로 확인합니다. [스트리밍 실측](../docs/evaluation.md#익명-필기와-실측) · [BAZE 요금](https://docs.mindlogic.ai/docs/general/api-gateway/reference/pricing) · [BAZE 사용량](https://docs.mindlogic.ai/docs/general/api-gateway/reference/usage)
