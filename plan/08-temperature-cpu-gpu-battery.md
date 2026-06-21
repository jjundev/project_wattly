# 08 — 온도 · CPU / GPU / 배터리

> 막힘: 01,02,03 · 커버: 스토리 25,26 · 결정표 매핑: #7, #12, **보류 #22, #28**
> 프로토타입 근거: CPU/GPU/배터리 온도 카드 line 148–168, 로직 line 616–621
> 상세 설계 선례: [`issues/13-cpu-gpu-temperature.md`](../issues/13-cpu-gpu-temperature.md) (grill-review 반영본)

## 목표

CPU·GPU의 **최고 온도**와 배터리 온도를 보여준다. 무권한·부분 실패 격리·적응형 폴링·60초 추이·저전력 원칙 유지. 검증되지 않은 센서는 추측하지 않고 unavailable로 둔다.

## ⚠ 보류 #22 — Phase 0 실기 검증이 선행 조건

CPU/GPU 온도는 비공개 SMC/HID라 **실기 검증 spike 전엔 진짜 숫자를 낼 수 없다.** 검증 통과 전까지 해당 카드는 `unavailable`. 출시 범위를 과장하지 않는다.

### Phase 0 — M5 source 검증 spike (UI 없는 read-only 진단 타깃)

1. SMC와 IOHID vendor temperature event 후보를 각각 조사: service/key identity, key-info, data type, raw value, 칩 variant, OS build 기록.
2. idle / CPU 5분 부하 / GPU 5분 부하를 각 3회 실행, raw trace 보존.
3. 독립 모니터와 동시 sample 10개 비교 → **중앙 절대 오차 ≤ 5°C**.
4. 대상 category가 ≥5°C 상승하는 run이 **3회 중 2회 이상**(열적 결합으로 타 category 상승은 실패 아님).
5. identity·오차·반복 부하 기준을 **모두 통과한 source만** M5 `verified` profile로 등록.
6. CPU/GPU 중 verified 없으면 해당 카드 unavailable 유지.
- `powermetrics`/shell parsing/root helper는 런타임 경로에서 제외.

## 범위 (In) — 검증 후 Phase 1~2

1. **격리** — 읽기 전용 `TemperatureTransport` 아래에 검증된 `SMCClient`/선택적 `HIDTemperatureClient`만. UI·모델은 IOKit/CF 타입을 모른다.
2. **profile** — `TemperatureProfile`: chip family·variant·OS 범위·source·sensor identity·data type·category(CPU/GPU)·집계법·정상 범위·검증 근거·상태(`verified`/`experimental`/`unsupported`). unknown `T*` key 자동 분류 금지.
3. **data type decoder** — key-info 실측에서 발견된 type만 작은 read-only decoder(예 `flt`/`sp78`도 표본 확인 시에만). 순수 함수.
4. **값** — category별 verified sensor 중 **최댓값** = "CPU 최고 온도"/"GPU 최고 온도". non-finite 거부, 범위는 profile별 정책. v1 정식 = M5(M1~M4는 동일 gate 통과 후 순차, Intel 제외).
5. **단일 seam** — `MetricSample.temperature(TemperatureSnapshot)`. snapshot 안에 CPU/GPU별 `value(TemperatureReading) | unavailable(TemperatureError)` + timestamp. `io_connect_t`/CF/raw buffer는 provider 내부 직렬 접근·즉시 정리.
6. **부분 실패** — CPU 성공+GPU 실패(및 반대)를 독립 `MetricState`로. 한쪽 실패가 타 카드/지표에 전파 안 됨. stale 값을 현재값처럼 유지하지 않음(history에만 남김).
7. **연결 수명** — `disabled → disconnected → ready → backoff | terminal`. invalid connection 즉시 1회 재연결, 재실패 시 1·2·4·8·16·30초 backoff. wake/사용자 재활성화 시 reset.
8. **오류 분류** — retryable(`connectionFailed`, 일시 `readFailed`) vs terminal(`unsupportedChip`, `noVerifiedProfile`, `unsupportedDataType`, `invalidReadings`). retryable에만 "재시도 중" 표기. private key/kern code UI 노출 금지.
9. **배터리 온도 (보류 #28: 추천 = 포함, 저위험)**
   - AppleSmartBattery `Temperature` 키(무권한·안정, SMC보다 훨씬 저위험). 온디바이스에서 스케일(1/100 °C 등)만 확인 후 디코드.
   - 데스크톱 숨김(배터리 없음).
10. **폴링** — 별도 timer 없이 `SystemMonitor` 적응형 tick에서 1회 읽기. **두 온도 카드가 모두 OFF면 provider 호출·sensor I/O 생략**([09](09-adaptive-polling.md)).

## 범위 (Out)

- SoC·SSD·메모리 온도, 팬 RPM/제어, 온도 threshold 알림(Out of Scope). 화씨(°C 고정, 소수 1자리). 메뉴바 온도는 [14](14-menubar-text-metrics.md)에서 칩으로 제공(프로토타입 우선).

## 수용 기준

- (Phase 0) M5 oracle 오차·반복 부하 기준 통과한 source만 verified.
- CPU 성공/GPU 실패 등 부분 실패가 독립적으로 표기, 다른 지표 무영향.
- sleep/wake 자동 복구, 한쪽 sensor 부재 처리, 1시간 handle/메모리/wakeup 안정.
- 배터리 온도가 노트북에서 표시, 데스크톱에서 숨김.
- profile 선택·decoder·범위·최댓값 집계·부분 실패·backoff 합성 fixture 단위 테스트([18](18-testing.md)).

## 메모

- 외부 구현(Stats/mactop 등)은 dependency로 넣지 않고 최소 read-only client 자체 구현. 코드/표 직접 재사용 시 라이선스·attribution 선검토.
- OS 업데이트마다 M5 profile 재검증. 새 조합은 gate 통과 전 `verified` 승격 금지.
