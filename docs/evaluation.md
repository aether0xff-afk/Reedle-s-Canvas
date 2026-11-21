# 필기 인식과 튜터 개입 평가

수학 20개, 화학 루이스 구조 20개, 물리 도식 20개를 합성 잉크로 렌더링합니다. 각 항목은 올바른 풀이, 합리적인 중간 단계, 또는 개입할 만큼 분명한 오류로 라벨링했습니다. 수학에는 정수 연산과 `Fraction`으로 검산한 계산을 포함했고, 화학에는 결합 차수·비공유 전자쌍·전하를, 물리에는 힘의 방향·그래프 기울기·회로의 연결·반사각을 포함했습니다. 60개 이미지는 사례 ID와 잠긴 Python 의존성으로 재생성할 수 있습니다. [AET-50 평가셋](https://linear.app/aethers-lab/issue/AET-50), [AET-44 구조화 인식](https://linear.app/aethers-lab/issue/AET-44)

## 로컬 평가

저장소 루트에서 실행합니다.

```sh
uv run --project server --locked python -m evaluation render .build/tutor-evaluation
uv run --project server --locked python -m evaluation replay evaluation/fixtures/smoke.json --fixture-scope --report .build/tutor-evaluation/smoke-report.json
uv run --project server --locked python -m pytest -q evaluation/tests
uv run --directory server --locked pytest -q
```

`render`는 60개 PNG와 `manifest.json`을 생성합니다. `replay`는 저장된 판정을 오프라인에서 채점합니다. `--fixture-scope`는 의도적으로 결과를 넣은 12개만 채점하며 리포트에는 60개의 원본 데이터셋 크기도 기록합니다. 테스트는 합성 PNG 요청을 실제 FastAPI 검증 경로에서 확인하고 격리된 가짜 공급자로 신뢰도 미달 시 개입이 보류되는지 확인합니다.

## 지표

전체와 과목별로 유효 응답 수, 오류 수, 누락된 사례, 아래 지표를 기록합니다. 개별 사례에는 오류 유형과 각 지표의 통과 여부가 포함됩니다.

| 지표 | 채점 방식 |
| --- | --- |
| 과목 인식 | 반환된 `kind`가 수학, 화학, 물리 중 기대 과목과 일치하는 비율 |
| 전사 | 기호와 공백을 정규화한 필기가 전사 별칭과 일치하는 비율. 학생이 쓴 오답도 그대로 읽어야 정답으로 채점 |
| 구조 | 과목이 일치하고 전사에서 수식 전체, 결합과 전자쌍, 힘의 방향 등 각 필수 요소의 별칭을 찾은 비율 |
| 대상 연결 | 반환된 `targetEntityIds`가 기대 영역을 모두 포함하는 비율. 개입한 사례의 동작이 기대 영역에 연결된 비율도 집계 |
| 개입 | 분명한 오류에서 `act`를 기대. 올바른 답과 중간 단계에서는 `observe_only`를 기대. FPR은 불필요한 개입/비개입 대상, FNR은 놓친 개입/개입 대상 |
| 지연 | 유효 응답과 전체 시도의 p50·p95를 각각 계산. 실측은 HTTPS 요청 시작부터 응답 검증까지, 백분위는 오름차순에서 `ceil(n × p)`번째 값 |

실패 및 누락 사례는 커버리지에 반영하며 비율의 분모는 유효 응답입니다. 분모가 0인 지표는 `null`입니다. 구조 채점은 현재 API의 전사 문자열과 명시된 별칭으로 평가하므로 표현에 따라 놓치는 경우가 있습니다. 자동 지표 외에 힌트의 교육적 품질은 별도의 검토가 필요합니다.

### 합성 리플레이 실행 결과

아래 수치의 입력은 과목마다 4개씩, 총 12개의 의도적으로 구성한 fixture 판정과 지연입니다.

| 과목 | 전사 | 구조 | 대상 연결 | 기본 FPR | 기본 FNR | p50 | p95 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 수학 | 3/4 | 4/4 | 4/4 | 1/3 | 0/1 | 1,100 ms | 1,800 ms |
| 화학 | 3/4 | 4/4 | 4/4 | 1/3 | 0/1 | 1,030 ms | 1,520 ms |
| 물리 | 3/4 | 3/4 | 3/4 | 1/3 | 0/1 | 1,210 ms | 2,010 ms |

예시 목표는 과목별 FPR 5%, FNR 20%, p50 2,500 ms, p95 7,000 ms입니다. `--max-fpr`, `--max-fnr`, `--max-p50-ms`, `--max-p95-ms`로 조정할 수 있습니다. 리플레이는 해당 범위의 응답이 모두 유효하고 과목별로 개입/비개입 사례가 있을 때 FPR·FNR 목표를 만족하는 가장 낮은 후보를 제안합니다. 서버가 반환한 개입을 보류하는 방식이므로 서버 기본값 0.82 이상에서 후보를 비교합니다. 지연 목표 충족 여부는 별도 필드로 확인할 수 있습니다.

이 fixture에서는 0.90에서 불필요한 개입 3건이 사라졌고 필요한 개입 3건이 유지됐습니다. 이 값은 리플레이 로직의 확인용입니다. 실제 BAZE 품질과 지연 또는 운영 임계값을 정하려면 익명화된 실제 필기와 해당 모델의 응답이 필요합니다. 배포 기본값은 0.82입니다.

## 익명 필기와 실측

PNG와 manifest를 같은 디렉터리에 둡니다. `render`가 만든 manifest를 포맷 예제로 사용할 수 있습니다. 실제 필기에서는 `source`에 `anonymized-handwriting`을 지정하고, 익명 사례 ID, `subject`, `status`, `category`, 기대 답안 `answers`, 실제 필기 전사 별칭 `transcripts`, 필수 요소별 별칭 `structure`를 작성합니다. `boxes`의 각 항목은 `[x, y, width, height]`이며 이미지에 대해 0–1로 정규화합니다. `targets`에는 기대 대상 상자의 0 기반 인덱스를 넣습니다. 실제 필기 속의 이름, 학교, 개인 메모와 그림 파일의 개인정보는 수집 단계에서 제거합니다.

`audit`는 로컬 PNG와 manifest가 실제 게이트웨이 요청 형식 및 크기 제한을 만족하는지 확인합니다. 중복 이미지를 검사하고 과목·라벨별 개수와 데이터셋 지문을 기록합니다.

```sh
uv run --project server --locked python -m evaluation audit --manifest .build/ReedlesCanvas-RealHandwriting/manifest.json --report .build/ReedlesCanvas-RealHandwriting/audit.json
```

### 공개 실제 필기 검증셋

로컬 `.build/ReedlesCanvas-RealHandwriting.zip`에 수학 풀이, 루이스 구조, 손으로 그린 회로 이미지를 각각 20개 담았습니다. 출처와 사용 조건은 `ATTRIBUTION.md`에, 원본 식별자·해시·잘라낸 좌표는 `provenance.json`에 기록했습니다. DrawEduMath의 학생 풀이에는 원저작자의 개인정보 제거 과정을 거친 공개 이미지를 사용했습니다. 이 자료가 포함된 ZIP은 CC BY-NC 4.0의 비영리 범위에서 사용합니다. [DrawEduMath 데이터셋](https://huggingface.co/datasets/allenai/DrawEduMath#license), [SMARE 루이스 구조](https://doi.org/10.5281/zenodo.15191704), [CGHD 회로](https://doi.org/10.5281/zenodo.10056817)

| 과목 | 정답 | 부분 풀이·맥락 미제공 | 오류 |
| --- | ---: | ---: | ---: |
| 수학 | 12 | 1 | 7 |
| 화학 | 17 | 1 | 2 |
| 물리 | 0 | 20 | 0 |

물리 자료는 부품 주석으로 회로 기호 인식을 채점합니다. 과제 지시나 학생 풀이의 정오 정보가 없어 물리 사례의 개입 누락률과 개입 임계값은 이 자료만으로 산출할 수 없습니다. 각 사례의 대상 영역은 잘라낸 이미지 전체입니다. 한 이미지 안의 여러 필기 영역에서 개입 대상을 고르는 성능은 별도의 평가가 필요합니다.

로컬 감사에서 60개 입력이 요청 형식을 통과했고 가장 큰 요청은 431,391바이트였습니다. 감사 리포트에는 실제 모델 응답이 필요 없는 입력 검증만 담았습니다. 실제 BAZE 전사·개입 정확도와 지연은 아직 측정하지 않았습니다.

`live`는 명시한 `https://…/v1/tutor/observe`에 `REEDLE_CLIENT_TOKEN`을 사용해 요청합니다. 이 명령에는 실제 모델 호출 비용이 발생할 수 있습니다. `--stream`을 지정하면 iPad 앱과 같은 SSE 경로를 사용하고 첫 초안 알림과 최종 응답까지의 지연을 각각 기록합니다. 지연에는 서버와 네트워크가 포함됩니다. 모델의 구조화 응답을 검증할 수 없어 게이트웨이가 돌려준 판단 보류는 `invalid_provider_draft`로 집계합니다. 유효한 모델 응답에 따른 판단 보류는 계속 채점합니다. 실행은 첫 요청 오류에서 멈추고 부분 리포트를 남깁니다.

```sh
uv run --project server --locked python -m evaluation live --stream --endpoint https://gateway.example/v1/tutor/observe --manifest /path/to/manifest.json --record .build/tutor-evaluation/live-replay.json --report .build/tutor-evaluation/live-report.json
uv run --project server --locked python -m evaluation replay .build/tutor-evaluation/live-replay.json --manifest /path/to/manifest.json
```

현재 공개 필기 자료로 처음 연결을 확인할 때는 두 명령에 같은 `--case math-real-03 --case chemistry-real-01 --case physics-real-03`를 붙여 세 과목에서 각각 하나씩 확인할 수 있습니다. 합성 자료는 `--manifest`를 생략하고 합성 사례 ID를 사용합니다. `--case`를 생략하면 전체 자료를 평가합니다.

요청에는 이미지, 영역, 관찰 메타데이터를 보냅니다. 라벨과 답안은 로컬 채점에 사용합니다. 선택 항목 `--record`는 전사와 인식·개입 판정을 로컬 파일에 저장합니다. 리포트의 `dataset_fingerprint`는 라벨, 영역, PNG의 SHA-256이며 실제 응답을 리플레이할 때 같은 평가셋인지 확인합니다. 유효 응답이 누락된 `live` 또는 `replay` 실행은 부분 리포트를 작성하고 종료 코드 `1`을 반환합니다.
