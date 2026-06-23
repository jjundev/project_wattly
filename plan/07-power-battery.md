# 07 — 전력 · 배터리 (노트북)

> 막힘: 01,02,03 · 커버: 스토리 4,16 · 결정표 매핑: #9, #12
> 프로토타입 근거: 배터리 카드 line 97–109, 로직 line 590–596, setBatteryMode line 445–451
> 상태: grill → review → 구현 → 실기 디버깅 완료 (2026-06-21). **전력 소스 = SMC(라이브 ~1초), AppleSmartBattery 폴백.**

## 목표

노트북에서 전체 시스템 순(net) 방전/충전 전력을 부호와 함께, **HWiNFO처럼 라이브로** 보여준다. 데스크톱에선 카드를 숨긴다.

## ⚠ 실기 여정 — AppleSmartBattery는 너무 느림 → SMC가 정답

온디바이스 디버깅(Mac17,2 / macOS 26, 2026-06-21):

1. **`InstantAmperage`(가스게이지 전류)는 AC에서 못 씀** — 플러그인 후 ~30–60초 지연 + 부호 오류(방전 중인데 +로 읽힘). → `PowerTelemetryData.BatteryPower`로 전환.
2. **`BatteryPower`도 게이지라 ~8–20초 평활 갱신**(plateau) + idle 시 간헐적 0. 정확하나 라이브 아님.
3. **SMC가 진짜 라이브(~1초)** — `AppleSMC` user client를 직접 읽으면 HWiNFO/iStat급 전력 센서가 나옴. 검증: 매 초 값이 바뀜(B0AP −9519→−10245→−14990 mW…). **이게 최종 소스.**

## 범위 (In)

1. **SMCConnection (`Core/SMC.swift`, 무권한 read-only · 재사용 가능 — issue 08 온도도 사용)**
   - `AppleSMC` 서비스 `IOServiceOpen` → `io_connect_t` 보유(`@unchecked Sendable`, actor 내부 직렬 접근; `IOReportEnergySubscription` 선례). `deinit`서 `IOServiceClose`.
   - 키 읽기: `IOConnectCallStructMethod(conn, 2, …)` — cmd 9(keyInfo) + cmd 5(read). **struct = 정확히 80바이트**(함정: Swift가 keyInfo 꼬리 패딩에 result/status/data8를 채워 76이 되면 kernel이 `kIOReturnBadArgument` → keyInfo를 12바이트로 패딩). `IOByteCount dataSize`는 32비트.
   - `read(key) -> (type, bytes)?`; 디코딩은 순수 `smcDouble`(테스트).
2. **BatteryProvider (actor) — SMC 1차 + AppleSmartBattery 폴백**
   - **1차(라이브):** `B0AP`=배터리 전력 mW(부호, 음수=방전), `B0AV`=mV, `B0AC`=mA, `PDTR`=어댑터 W(>0.5 ⇒ AC). **netW = −B0AP/1000**(방전>0/충전<0), volts=B0AV/1000, milliamps=|B0AC|, charging=netW<−0.2, externalConnected=PDTR>0.5.
   - **폴백:** SMC/배터리 키 부재 시 AppleSmartBattery `PowerTelemetryData.BatteryPower`(`twosComplement` 디코딩, 거침). **데스크톱**은 여기서 service==0 → `.notPresent`(카드 숨김). Voltage/telemetry 미독 → `.pending`.
   - `smcDouble(bytes, type)`: `flt `=LE Float32, `si*`/`ui*`=LE 정수(SMC가 LE 반환; `B0AV` b6 30 → 12470 mV), `si*` 부호확장. 순수·테스트.
3. **표시 (부호 규칙 · UI 기구축 + #17 분기)**
   - 충전/방전 = `charging`(= netW<−0.2). 값 = 부호 + 크기(소수 1자리): 충전 `+`, 방전 `−`. 값 색 `c.text`. **부하>어댑터면 꽂혀 있어도 "방전 중"으로 정확히**(실측 전력).
   - **[#17] 크기 `0.0`(|netW|<0.05)이면 부호 생략** → `0.0 W`.
   - sub = "±mA · {V} V · 충전 중/방전 중 · 1분 평균 x.x W". 1분 값은 원시 netW의 τ=60초 EMA이며, 4초 헤드라인 EMA와 독립적이다. 스파크라인 area 없음(중립색).
   - **그래프 리셋 = `externalConnected` 변화**(꽂기/뽑기 즉시) — `SystemMonitor.recordHistory`의 `lastExternalConnected`.

## 범위 (Out)

- 배터리 %(결정표 #20). 배터리 온도([08](08-temperature-cpu-gpu-battery.md), SMC 재사용). 메뉴바 배터리 텍스트([14](14-menubar-text-metrics.md)). 접근성 라벨([15](15-accessibility.md)).
- "AC 연결" 3-state — v1 미포함(`externalConnected` 이미 seam에 있음). SMC 키는 모델별이라 폴백으로 robustness 확보.

## 수용 기준

- 노트북에서 충전/방전 부호·크기·mA·V·상태가 **~1초 라이브**(SMC). 꽂는 즉시 그래프 리셋. net≈0에서 `0.0 W`. 부하>어댑터면 꽂혀도 "방전 중".
- 데스크톱(배터리 없음)에서 카드 숨김(폴백 `.notPresent`).
- `smcDouble`(flt/si/ui LE), `twosComplement`, `netWatts`, `isCharging`, `batteryMilliamps` 순수 테스트. `ExternalConnected` history 리셋 SystemMonitor 테스트.

## 신규/변경 파일

- **+** `Wattly/Core/SMC.swift`(SMCConnection — 재사용), **+** `Wattly/Providers/BatteryProvider.swift`, **+** `Wattly/Core/BatteryPower.swift`(순수: `smcDouble`·`twosComplement`·`netWatts`·`isCharging`·`batteryMilliamps`), **+** `WattlyTests/BatteryPowerTests.swift`.
- `MetricSample.BatterySample`에 `externalConnected: Bool`. 와이어링 `FakeProviders.all`. `MetricCardView` #17 분기. `SystemMonitor` `lastExternalConnected` 리셋. 파일 추가 → `xcodegen generate` 재실행.
- `BatterySample.average1mW`는 provider가 아니라 `SystemMonitor`가 채우는 표시 전용 값이다. 어댑터 연결 상태가 바뀌면 4초 EMA와 함께 리셋한다.

## 검증 완료

- 빌드 그린(Swift 6, deploy 14.0), **48 테스트 통과**. 앱이 실배터리에서 무crash 구동.
- SMC 라이브 확인: B0AP가 매 초 갱신(−9519→−10245→−14990 mW), AppleSmartBattery의 ~10–20초 plateau 해소.
- 충전 부호: B0AP>0 → netW<0 → "+ · 충전 중"(B0AC>0 = 전류 유입). 미해결 없음.
