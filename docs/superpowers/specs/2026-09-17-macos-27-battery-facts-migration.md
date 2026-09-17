# macOS 27 배터리 사실 이관(레지스트리 → SMC 폴백) 설계

- 작성일: 2026-09-17
- 실기: MacBook Pro M5 (`Mac17,2`), macOS 27.0 (26A428), 시스템 펌웨어 `20457.1.29`, Xcode 27.0
- 배경 메모리: `macos-27-sensor-audit-facts.md`
- 범위: macOS 27 감사에서 드러난 3축 중 **1축**만. 프로세서 전력(IOReport Energy Model 갱신 주기)과 충전 제한(`CHTE` 소실)은 별도 설계·계획으로 다룬다.

## 1. 문제

macOS 27에서 `AppleSmartBattery` IORegistry 노드의 최상위 키 다섯 개가 사라졌다. 코드는 그대로 컴파일·테스트 통과하지만 이 키를 읽던 곳이 전부 `nil`을 받는다.

| 사라진 키 | 소비처 | 사용자 증상 |
|---|---|---|
| `AppleRawMaxCapacity` | `BatteryProvider`, `AppleSmartBatteryReader` | 배터리 효율 % 사라짐, 최대 Wh 사라짐, 잔량 % 추정(`BatterySample.percentage`) nil |
| `AppleRawCurrentCapacity` | `BatteryProvider` | 잔여 Wh 사라짐, Wh 기반 남은 시간 추정 불가 |
| `DesignCapacity` | `BatteryProvider`, `AppleSmartBatteryReader` | 효율 % 사라짐 |
| `Temperature` | `BatteryProvider`, `FanControlDaemon` | 배터리 온도 행·메뉴바 칩 사라짐, 데몬 열 보호가 항상 `batterySensorUnreadable` |
| `ChargingCurrent` | `AppleSmartBatteryReader` | 캘리브레이션 "외부 요인이 충전을 막음" 판정 불능 |

`CycleCount`, `Voltage`, `InstantAmperage`, `IsCharging`, `ExternalConnected`, `AdapterDetails.Watts`, `PowerTelemetryData.*`, `TimeRemaining`는 그대로다. mAh 값은 `BatteryData` 서브딕셔너리(`RemainingCapacity`/`FullChargeCapacity`/`NominalChargeCapacity`/`DesignCapacity`)로 옮겨갔다.

## 2. 실측된 대체 소스 (SMC, 앱·데몬 모두 이미 `SMCConnection`으로 읽는다)

| SMC 키 | 타입 | 실측값 | 의미 | 레지스트리 대응 |
|---|---|---|---|---|
| `B0RM` | ui16 | 4280 | 잔량 mAh | `BatteryData.RemainingCapacity` 4280 |
| `B0NC` | ui16 | 6255 | Nominal 충전 용량 mAh | `BatteryData.NominalChargeCapacity` |
| `B0FC` | ui16 | 6103 | Full-charge 용량 mAh | `BatteryData.FullChargeCapacity` |
| `B0DC` | ui16 | 6249 | 설계 용량 mAh | `BatteryData.DesignCapacity` 6249 |
| `B0CT` | ui16 | 137 | 사이클 | `CycleCount` 137 |
| `B0AT` | ui16 | 3067 | 배터리 온도 centi-°C | 옛 `Temperature`(centi-°C)와 같은 단위 |
| `B0AC` | si16 | +4137 / −2030 | 배터리 실전류 mA (+충전, −방전) | (`ChargingCurrent`의 대용) |

## 3. 결정

1. **최대 용량 = Nominal(`AppleRawMaxCapacity` → `B0NC` / `BatteryData.NominalChargeCapacity`)**, Full-charge가 아니다. 근거: (a) 옛 `AppleRawMaxCapacity` 관측 범위 6166~6252는 Nominal(6234~6281)에 가깝고 FCC(6082~6129)는 그 아래다. (b) Apple 자체 "최대 용량 100%"(system_profiler)는 Nominal/Design이다 — FCC를 쓰면 업데이트 직후 효율이 갑자기 97%로 떨어져 보인다. 미확정이므로 100% 충전 시 `B0RM`이 `B0NC`/`B0FC` 중 어느 쪽에 붙는지 실기 확인 항목으로 남긴다.
2. **우선순위는 레지스트리 → SMC 폴백.** macOS 26 이하에서는 오늘과 바이트 단위로 같은 값을 보여 회귀 위험이 0이고, 27에서만 SMC가 채운다. 앱 프로바이더·캘리브레이션 리더·데몬 세 곳이 같은 우선순위를 쓴다(같은 mAh를 보고해야 한다).
3. **디코딩·우선순위 결정은 순수 함수 하나로 모은다**(`BatteryFacts` + `BatteryFactsSource`), IOKit·SMC I/O는 세 소비처가 각자 한다 — 기존 `BatteryPower`/`Temperature` 패턴과 같다. 데몬 타깃에도 컴파일된다.
4. **캘리브레이션 정체 전류**: 레지스트리 `ChargingCurrent`가 없으면 `max(0, B0AC)`를 쓴다. 정체 판정("어댑터 있음 + 전류 < 300 mA")은 실전류로도 성립한다(게이트가 열렸는데 충전이 안 되면 실전류도 0에 붙는다).
5. **범위 가드는 기존 것을 재사용**: 온도 `batteryCelsius(rawCentiCelsius:in: 0...80)`, mAh는 양수만, 사이클 `validatedBatteryCycleCount`, 효율 `batteryEfficiencyPercent`.
6. **UI·모델·인텐트·XPC 계약은 건드리지 않는다.** `BatterySample`의 필드 의미가 그대로라 소비처는 자동으로 복구된다.

## 4. 비범위

- 잔량 %를 `B0UC`(UI %)로 바꾸는 것 — `BatterySample.percentage`는 Wh 비율 유지(옛 동작과 동일한 98.99% 상한 특성).
- `CardPresentation.batteryZeroWattStatusText`의 "잔량을 모르면 완충됨" 기본값 — 이번 이관으로 잔량이 다시 채워지므로 도달하지 않는다.
- 프로세서 전력(2축), 충전 제한(3축).

## 5. 검증 기준

- 새 순수 함수 테스트: SMC 바이트 → 사실, 레지스트리(레거시 키 우선, `BatteryData` 폴백) → 사실, 병합 우선순위, 온도·mAh 범위 가드.
- 기존 테스트 전부 green.
- 실기(macOS 27): `Wattly -WattlyBatteryProbe`가 효율·잔여 Wh·최대 Wh·온도·사이클을 전부 non-nil로 출력. 팝오버 배터리 카드 펼침에 온도 행·잔여 용량·효율·사이클 행이 다시 보임.

## 6. 실기 결과 (2026-09-17, macOS 27.0 26A428, Mac17,2)

- `-WattlyBatteryProbe`: remaining/max/efficiency/cycles/temp 전부 non-nil. 관측값:
  `[battery-probe] sample 0: net 11.03 W · 856 mA · 12.89 V · charging=false ext=false · remaining 65.36 Wh / max 72.42 Wh · pct 90 · efficiency 100.34 % · cycles 137 · temp 30.58 °C · timeRemaining 487 min`
- 팝오버 배터리 카드(사용자 직접 확인): 배터리 온도 30.6°C · 남은 용량 65.1 Wh · 배터리 효율 100.3% · 사이클 137 행 복구 확인. "약 6시간 3분 남음"도 정상.
- 데몬 열 보호: 미검증 — 설치된 도우미(2026-09-09 빌드)를 아직 재설치하지 않음. 설정 > 배터리 > 도우미 "재설치" 후 열 보호 상태가 "배터리 센서를 읽을 수 없음"이 아니면 통과.
- 미확정: `AppleRawMaxCapacity`가 Nominal이었는지 FCC였는지. 100% 충전 시 `B0RM`이 `B0NC`(6255)·`B0FC`(6103) 중 어느 쪽에 붙는지 확인하면 결정된다 — FCC 쪽이면 `BatteryFactsSource`의 `B0NC`/`NominalChargeCapacity` 두 곳을 `B0FC`/`FullChargeCapacity`로 바꾸고 `BatteryFactsTests`의 기대값을 갱신한다.
