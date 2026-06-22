# 08 — 온도 · CPU / GPU / 배터리

> 막힘: 01,02,03 · 커버: 스토리 25,26 · 결정표 매핑: #7, #12, **보류 #22, #28**
> 프로토타입 근거: CPU/GPU/배터리 온도 카드 line 148–168, 로직 line 616–621
> 설계 상태: `/grill-yourself` → `/grill-review deep auto` 반영(SHIP, 2026-06-22). seam·상태·fan-out·UI는 06/07처럼 **이미 구축** — 본 계획은 주로 provider 빌드.

## 목표

CPU·GPU의 **최고 온도**와 배터리 온도를 보여준다. 무권한·부분 실패 격리·적응형 폴링·60초 추이·저전력 원칙 유지. 검증되지 않은 센서는 추측하지 않고 unavailable로 둔다.

## ⚠ 보류 #22 — Phase 0 실기 검증이 선행 조건

CPU/GPU 온도는 비공개 SMC/HID라 **실기 검증 spike 전엔 진짜 숫자를 낼 수 없다.** 검증 통과 전까지 해당 카드는 `unavailable`. 출시 범위를 과장하지 않는다.

### Phase 0 — M5 source 검증 spike (DEBUG 전용 read-only 프로브)

진입 = `#if DEBUG` + 런치 인자 `-WattlyThermalProbe`(`-WattlyScenario` 패턴 미러, 메뉴바 대신 프로브 실행). 별도 Xcode 타깃 없음.

1. **발견** — SMC·IOHID vendor temperature event 후보 조사: service/key identity, key-info, data type, raw value, 칩 variant, OS build 기록. ⚠ SMC 키 발견엔 **인덱스 열거가 필요**(`#KEY` count + get-key-by-index selector + 키별 key-info) — 현재 `SMCConnection.read(_:)`는 name-기반뿐이라 이는 **신규 IOKit 경로**(DEBUG 전용, Phase 0 최대 신규 네이티브 작업). 미지의 `T*` key 자동 분류 금지.
2. **부하 구동·기록** — idle / CPU 5분 / GPU 5분을 각 3회. read-only 프로브는 부하를 못 만드므로 드라이버 동반: CPU = N-스레드 `yes`(이 M5는 12-스레드로 포화), GPU = Metal compute 루프(또는 외부 GPU 벤치). raw trace는 **파일(CSV, 홈/tmp) + `os_log`**로 보존.
3. **게이트 = 논리곱** (단일 "독립 모니터 ≤ 5°C = 진실"은 폐기 — Stats/TG Pro/iStat은 모두 **같은** private 키를 읽어 decode-일치일 뿐 독립 진실이 아니고, `powermetrics`는 root 필요 + Apple Silicon에서 깨끗한 per-die CPU/GPU 온도 미노출):
   - (a) 동일소스 2번째 도구와 decode 일치(스케일/엔디안 버그 포착, 표본 10개),
   - (b) 절대 타당성(예 20–110 °C),
   - (c) **부하응답** — 대상 category ≥5°C 상승 run이 **3회 중 2회 이상**(타 category 동반 상승은 열결합, 실패 아님; 틀린 센서가 떨어지는 진짜 판별자),
   - (d) SMC↔IOHID 교차일치(둘 다 존재 시).
4. **등록** — (a)~(d) **모두 통과한 source만** M5 `verified` profile로. CPU/GPU 중 verified 없으면 카드 unavailable(terminal) 유지.
- `powermetrics`/shell parsing/root helper는 **런타임 경로**에서 제외(오프라인 오라클로 사용은 무방).
- ※ 진짜 독립 오라클(하드웨어 프로브 등) 도구 선택은 미해결 — (a)·(d)는 결국 동일/유사 소스라 **(c) 부하응답이 1차 판별자**.

## 범위 (In) — 2단계 출시 (※시퀀싱 = 권장 가정, 최종은 제품 결정)

- **Stage A (Phase 0 무관, 즉시 출시 가능):** 배터리 온도(§9) + provider 스캐폴드(§1·5·6·7·8·10). CPU/GPU는 정직하게 `noVerifiedProfile`(terminal · I/O 0).
- **Stage B (Phase 0 통과 후):** M5 `verified` profile 등록 → CPU/GPU 점등(§2·3·4).

1. **격리** — 읽기 전용 `TemperatureTransport` 아래에 검증된 `SMCClient`/선택적 `HIDTemperatureClient`만. UI·모델은 IOKit/CF 타입을 모른다. **이 transport가 테스트 주입 seam**(fake transport로 backoff/연결을 하드웨어 없이 검증 — §수용 기준).
2. **profile** — `TemperatureProfile`: chip family·variant·OS 범위·source·sensor identity·data type·category(CPU/GPU)·집계법·정상 범위·검증 근거·상태(`verified`/`experimental`/`unsupported`). unknown `T*` key 자동 분류 금지.
3. **data type decoder** — `smcDouble`(순수 함수, 기구축)이 이미 `flt `를 디코드 → flt는 추가 작업 없음. **Phase 0에서 검증된 type 외에는 거부 → `.unsupportedDataType`(terminal).** 미지의 type을 `smcDouble`의 정수 fallback으로 흘리지 말 것(`sp78`/`fpe2` 등 fixed-point를 raw LE int로 **조용히 오디코드**함). `sp78` decoder는 Phase 0가 sp78 키를 찾을 때만 추가.
4. **값 (구현반영 2026-06-22)** — 메인 카드 = category별 verified sensor의 **평균**(`averageCelsius`; 과거 최댓값에서 변경 — 평균이 더 안정적인 헤드라인이고 펼침 요약과 일치). 펼침(아래 §11) = 클러스터별 평균+최고. non-finite·범위 밖 거부, 범위는 profile별 정책. v1 정식 = M5(M1~M4는 동일 gate 통과 후 순차, Intel 제외).
5. **단일 seam (기구축)** — `MetricSample.temperature(TemperatureSnapshot)`. 각 category = `reading(TemperatureReading) | unavailable(TemperatureError) | notPresent(String)` **3-케이스**(데스크톱 배터리온도 = `notPresent`). **per-snapshot timestamp 없음** — `SystemMonitor`가 주입 clock으로 history 스탬프. `io_connect_t`/CF/raw buffer는 provider 내부 직렬 접근·즉시 정리.
6. **부분 실패** — CPU 성공+GPU 실패(및 반대)를 독립 `MetricState`로. 한쪽 실패가 타 카드/지표에 전파 안 됨. stale 값을 현재값처럼 유지하지 않음(history에만 남김).
7. **연결 수명** — `disabled → disconnected → ready → backoff | terminal`. invalid connection 즉시 1회 재연결, 재실패 시 1·2·4·8·16·30초 backoff. wake(큰 `dt`로 감지 — `PowerProvider.maxPlausibleDt` 미러)·사용자 재활성화 시 reset. backoff schedule = 순수 함수 `(state,outcome,dt)→(state,nextDelay)`; provider가 자체 `prevInstant` 보유. **terminal은 I/O 0**(09 이전의 자체 저전력 가드).
8. **오류 분류** — retryable(`connectionFailed`, 일시 `readFailed`) vs terminal(`unsupportedChip`, `noVerifiedProfile`, `unsupportedDataType`, `invalidReadings`). retryable에만 "재시도 중" 표기. private key/kern code UI 노출 금지.
9. **배터리 온도 (보류 #28: 추천 = 포함, 저위험 · Stage A · Phase 0 무관 · profile gate 없음)**
   - AppleSmartBattery `Temperature` 키(무권한·안정, SMC보다 훨씬 저위험). 온디바이스에서 스케일(1/100 °C 등)만 확인 후 디코드.
   - 데스크톱 숨김(배터리 없음).
10. **폴링·게이팅** — 별도 timer 없이 `SystemMonitor` 적응형 tick에서 1회 읽기. **소유권 분리(순환 해소):** 08은 provider 훅 `TemperatureProvider.setEnabled(_:)`만 제공(기본 true; 재활성화 시 backoff·연결상태 reset; 비활성 시 I/O 0 — `setMemoryProcessEnumeration` 선례 미러). **두 카드 모두 OFF 시 이 훅을 호출하는 결정·`SystemMonitor` 배선·call-count 테스트는 [09](09-adaptive-polling.md)가 소유.**
11. **카드 펼침 (구현반영 2026-06-22)** — **cpuTemp만** 메모리/CPU 카드처럼 클릭하면 펼쳐진다. gpuTemp는 클러스터가 하나뿐이라 펼쳐도 헤드라인과 중복 → 펼침 없음(평균값만 표시). batTemp도 단일 센서라 펼침 없음. CPU 펼침 = **클러스터 요약**(P-코어/E-코어 2행), 각 행 = 라벨 + 막대(고정 0–110 °C) + 평균°·최고°. seam은 `TemperatureReading.groups:[TemperatureGroup{name,average,hottest}]`(클러스터 *요약*; raw 센서 전체 아님 — SMC는 다이 센서라 1:1 코어가 아니므로 클러스터 평균이 정직한 단위). 라벨은 **정적**("P-코어"/"E-코어"/"GPU") — CPU 사용률 카드의 런타임 perf-level명과 별개. 전 센서를 매 폴링 읽으므로 추가 게이팅 불필요(메모리의 `ProcessEnumerating`과 달리). 막대 색은 중립(임곗값 색은 [10](10-thresholds-color-coding.md)).

## 범위 (Out)

- SoC·SSD·메모리 온도, 팬 RPM/제어, 온도 threshold 알림(Out of Scope). 화씨(°C 고정, 소수 1자리). 메뉴바 온도는 [14](14-menubar-text-metrics.md)에서 칩으로 제공(프로토타입 우선).

## 수용 기준

- (Phase 0) decode-일치·타당성·부하응답·교차일치 게이트(논리곱)를 통과한 source만 verified.
- CPU 성공/GPU 실패 등 부분 실패가 독립적으로 표기, 다른 지표 무영향.
- sleep/wake 자동 복구, 한쪽 sensor 부재 처리, 1시간 handle/메모리/wakeup 안정.
- 배터리 온도가 노트북에서 표시, 데스크톱에서 숨김.
- profile 선택·decoder·범위·최댓값 집계·부분 실패 단위 테스트. backoff/연결은 **fake `TemperatureTransport`(§1 seam)를 실제 provider에 주입** → `read(at:)` 반복 + hand-advanced instant로 검증(`ScriptedProvider`는 canned·I/O 0이라 provider backoff 불가, SystemMonitor 레벨 전용); backoff schedule 순수 함수는 표로 직접; I/O call-count(backoff 창·terminal 중 0)는 fake transport 카운터([18](18-testing.md)).

## 메모

- 외부 구현(Stats/mactop 등)은 dependency로 넣지 않고 최소 read-only client 자체 구현. 코드/표 직접 재사용 시 라이선스·attribution 선검토.
- OS 업데이트마다 M5 profile 재검증. 새 조합은 gate 통과 전 `verified` 승격 금지.
