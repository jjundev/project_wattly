# 07 — 전력 · 배터리 (노트북)

> 막힘: 01,02,03 · 커버: 스토리 4,16 · 결정표 매핑: #9, #12
> 프로토타입 근거: 배터리 카드 line 97–109, 로직 line 590–596, setBatteryMode line 445–451
> 상태: grill-yourself + grill-review(deep) 수렴 **SHIP** (2026-06-21). UI/seam/scalar/데스크톱 숨김은 **이미 구축** → 본질은 **provider swap**(+ #17용 소폭 UI 분기).

## 목표

노트북에서 전체 시스템 순(net) 방전/충전 전력을 부호와 함께 보여준다. 데스크톱에선 카드를 숨긴다.

## 범위 (In)

1. **BatteryProvider (무권한, 노트북 한정 · stateless `actor`)**
   - `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))` → 매 폴 fetch 후 `defer { IOObjectRelease }`. CF 핸들 비보유 → `@unchecked Sendable` 래퍼 불필요(`PowerProvider`보다 단순). actor는 @MainActor 폴에서 IOKit 동기 호출을 off-main으로 돌리기 위해 **필수**. dt/rebaseline 없음(순간값, 카운터 아님). `import IOKit`(저장소 첫 사용, XcodeGen 자동 링크).
   - `Voltage`(mV)/1000 = **실측 V**(~12.6 V; 프로토타입 하드코딩 12.0 아님). `InstantAmperage`는 `NSNumber.uint64Value`(원시 비트패턴)로 읽어 `decodeAmperage`로 디코딩 — `.int64Value`(암묵 디코딩 → 항등 no-op) 금지.
   - **netW = −(volts × mA_signed / 1000)** — 부호 반전 **필수**. 라이브 검증: `InstantAmperage < 0 = 방전`(`ExternalConnected=No` 확인), 예 −754 mA × 12.762 V → netW = **+9.62 W**(방전이 양수). PRD 검증값: −938 mA × 12.027 V = 11.28 W, −1175 mA × 11.992 V = 14.09 W.
   - `decodeAmperage(_ raw: UInt64) -> Int` 순수 함수, Int64 2의 보수(큰 unsigned면 `v − 2^64`). 예 `18446744073709550678` → −938.
   - `BatterySample.milliamps` = **크기(abs)** 저장(뷰가 부호 prepend; 부호 저장 시 "−−754"). seam은 기구축(`netW, milliamps, volts, charging`).
   - 배터리 없음(데스크톱) `IOServiceGetMatchingService==0` → `.unavailable(.notPresent("배터리 없음 — 데스크톱 Mac"))` → **카드 숨김**(모드 A는 desktop 시 배터리/배터리온도 숨김). 서비스 존재하나 속성 일시 미독 → `.pending`(에러 점멸 방지).
2. **표시 (부호 규칙, 프로토타입대로 · UI 기구축 + #17 분기)**
   - net > 0 = 방전, net < 0 = 충전. charging = net < −0.2.
   - 값 = 부호 + 크기(소수 1자리): **충전 시 `+`, 방전 시 `−`**. 값 색 `c.text`(임곗값 착색 없음).
   - **[#17] 크기가 `0.0`으로 표시될 때(|netW| < 0.05) 부호 생략** — AC 연결·완충 등 net≈0에서 `−0.0 W`가 아니라 **`0.0 W · 방전 중`**. 같은 조건에서 sub의 mA 부호도 생략. ("AC 연결" 별도 상태(seam `charging: Bool`→enum)는 v1 범위 밖 — 2-state 유지.)
   - sub = "±mA · {실측 V} V · 충전 중/방전 중". 스파크라인 area 없음(라인만, 중립색 `c.spark`).
   - 방향 전환(충전↔방전) 시 배터리 그래프 히스토리 리셋 — `SystemMonitor.recordHistory`에서 직전 `charging`과 비교, flip 시 `history[.battery] = HistoryBuffer()`(상태는 history를 소유한 SystemMonitor에 둠 → provider는 stateless 유지). 프로토타입 `setBatteryMode`(데모 버튼)의 **의도**를 실 트리거(추론된 flip)로 적응(축자 이식 아님). 대안: 연속 부호 라인(리셋 없음).
3. **IOReport와의 관계** — 별도 라벨 카드로 병행. UI에서 "SoC 전력"과 "배터리"가 다른 것을 측정함을 명확히([06](06-power-ioreport-soc.md)). 배터리 온도([08](08-temperature-cpu-gpu-battery.md))는 동일 `AppleSmartBattery` 서비스를 **별도 provider**로 읽음(핸들 비공유, 결합 없음).

## 범위 (Out)

- 배터리 %(메뉴바 목업의 100%는 macOS 크롬이지 Wattly 아님 — 결정표 #20). 배터리 온도([08](08-temperature-cpu-gpu-battery.md)). 메뉴바 배터리 텍스트([14](14-menubar-text-metrics.md); 현 `MenuBarLabel`은 CPU 전용). 접근성 라벨([15](15-accessibility.md); 값의 U+2212 `−` VoiceOver 처리 포함).
- **"AC 연결" 3-state(seam `charging: Bool`→enum + 뷰 + 카피)** — v1 미포함. net≈0은 #17 부호 생략으로 처리.

## 수용 기준

- 노트북에서 충전/방전 부호·크기·mA·V·상태가 라이브 반영. **net≈0(AC 완충)에서 `0.0 W`(부호 없이) · "방전 중"** 표기.
- 데스크톱(배터리 없음)에서 배터리 카드가 사라지고 나머지 유지.
- `decodeAmperage` 2의 보수 단위 테스트(예 `18446744073709550678` → −938) + 양수/음수/0 경계([18](18-testing.md)). `netWatts`(방전>0/충전<0), `isCharging`(−0.2 경계) 순수 테스트.
- 방향 전환 history 리셋 `SystemMonitor` 테스트(`ScriptedProvider` + `ManualClock`, 폴 2회, flip 후 `history[.battery]` 리셋 검증).

## 신규/변경 파일 (provider swap)

- **+** `Wattly/Providers/BatteryProvider.swift`, **+** `Wattly/Core/BatteryPower.swift`(순수: `decodeAmperage`·`netWatts`·`isCharging`), **+** `WattlyTests/BatteryPowerTests.swift`.
- 와이어링 1줄 — `FakeProviders.all`의 `default:`(현 `FakeProvider.swift:162`) **앞**, `.power where scenario != .fail`(:161) 옆에: `case .battery where scenario != .desktop: return BatteryProvider()`. 데스크톱은 `default:`→`FakeProvider`가 이미 `.notPresent`(:47–49).
- **[#17]** `MetricCardView` 배터리 값(:317)·sub(:333) 렌더에 "크기 0 → 부호 생략" 분기 추가.
- (선택) `SystemMonitor` 방향전환 history 리셋(~4줄) + 위 테스트.
- 파일 추가 후 `xcodegen generate` 재실행 → `xcodebuild build`(Swift 6, deploy 14.0) → `xcodebuild test`.

## 미해결 (사용자 확인 필요)

- **#18** 충전 부호("+ · 충전 중")는 **방전만** 라이브 검증됨(grill 시 기기가 방전 중). 충전기 연결 후 `ioreg AppleSmartBattery`(`InstantAmperage`/`IsCharging`/`ExternalConnected`) 재측정으로 `A>0 → net<0 → "+ · 충전 중"` 확정.
