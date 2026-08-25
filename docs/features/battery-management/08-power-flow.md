# Power Flow & 전력 흐름 텔레메트리

## 상태

- 단계: 구현 완료 (Production Ready)
- 구현 난이도: 보통
- 권장 우선순위: 완료

## 목표

어댑터, 배터리, 시스템 사이의 실시간 전력 흐름을 측정하여 배터리 카드 펼침 영역에 3대 논리적 범주(전원 공급 및 소비 전력, 실시간 전기 지표, 배터리 팩 건강 & 용량)로 명확히 표시한다.
과도한 그래픽 다이어그램 대신 macOS 기본 배터리 위젯의 표준 명명 체계(`전원 공급원: 전원 어댑터 / 배터리 / 전원 어댑터 및 배터리`, `어댑터 전력`, `시스템 소비 전력`)를 적용하여 미니멀하고 직관적인 UI를 제공한다.

## 하드웨어 데이터 소스 및 매핑

1. **어댑터 입력 전력 ($P_{\text{adapter}}$)**:
   - SMC 센서 `PDTR` (W, `flt` / `sp78` / `ioft`)
   - 보조/폴백: AppleSmartBattery `PowerTelemetryData.SystemPowerIn` (mW)
2. **배터리 순전력 ($P_{\text{batt}}$)**:
   - SMC 센서 `B0AP` (mW, 음수=충전, 양수=방전)
   - 보조/폴백: AppleSmartBattery `PowerTelemetryData.BatteryPower` (mW)
3. **시스템 총 소비 전력 ($P_{\text{sys}}$)**:
   - SMC 센서 `PSTR` (W, System Total Power)
   - 보조/폴백: AppleSmartBattery `PowerTelemetryData.SystemLoad` (mW)
   - 계산 폴백: 에너지 평형 방정식 $P_{\text{sys}} = P_{\text{adapter}} + P_{\text{batt\_discharge}}$

## 5대 전력 흐름 시나리오 판정 규칙

| 시나리오 | 조건 | `전원 공급원` 표기 | UI 노출 여부 |
|---|---|---|---|
| **1. 충전 중 (Charging)** | $P_{\text{batt}} < -0.2\text{W}$, 어댑터 연결 | `전원 어댑터` | 상단 전력 흐름 범주 노출 |
| **2. 바이패스/상한 유지 (Adapter Bypass)** | $|P_{\text{batt}}| \le 0.2\text{W}$, 어댑터 연결 | `전원 어댑터` | 상단 전력 흐름 범주 노출 |
| **3. 배터리 단독 구동 (Battery Only)** | 어댑터 미연결 (`externalConnected == false`) | - | **전력 흐름 범주 완전 숨김** |
| **4. 능동 방전 (Active Discharge)** | 어댑터 연결 중 CHTE 억제 및 방전 ($P_{\text{batt}} > 0.2\text{W}$) | `배터리` | 상단 전력 흐름 범주 노출 |
| **5. 보조 방전 (Power Assist)** | 어댑터 연결 중 고부하 ($P_{\text{adapter}} > 0.5\text{W}$, $P_{\text{batt}} > 0.2\text{W}$) | `전원 어댑터 및 배터리` | 상단 전력 흐름 범주 노출 |

## UI 레이아웃 및 3대 범주화 구조

```text
┌────────────────────────────────────────────────────────┐
│ [헤더 서브라인] (CardPresentation.batteryRemainingTimeSummary)
│  • 충전 중: "완충까지 약 24분 남음"
│  • 직결 유지: "80% 한도 유지 중"
│  • 배터리 구동: "약 4시간 15분 남음"
│  • 능동 방전: "목표치(70%)까지 방전 중"
├────────────────────────────────────────────────────────┤
│ [1. 전원 공급 및 소비 전력] (어댑터 연결 시에만 표시)
│  • 전원 공급원: "전원 어댑터" / "배터리" / "전원 어댑터 및 배터리"
│  • 어댑터 전력: 48.5 W
│  • 시스템 소비 전력: 16.1 W
├────────────────────────────────────────────────────────┤
│ [2. 실시간 전기 지표] (CardPresentation 상수 그대로 사용)
│  • 1분 평균: CardPresentation.batteryAverage1mLabel (W)
│  • 전류: "전류" (mA)
│  • 전압: "전압" (V)
│  • 배터리 온도: CardPresentation.batteryTemperatureLabel (°C)
├────────────────────────────────────────────────────────┤
│ [3. 배터리 팩 건강 & 용량] (CardPresentation 상수 그대로 사용)
│  • 남은 용량: CardPresentation.batteryRemainingCapacityLabel (Wh)
│  • 배터리 효율: CardPresentation.batteryEfficiencyLabel (%)
│  • 사이클: CardPresentation.batteryCycleLabel
├────────────────────────────────────────────────────────┤
│ [4. 제어 영역] (CardExpandRegion)
│  • 한 번만 완충: [ 비활성화됨 / 활성화됨 ]
└────────────────────────────────────────────────────────┘
```

## 관련 파일

- `Wattly/Core/PowerFlow.swift`: 순수 전력 흐름 시나리오 분기 및 전력 평형 계산 모델
- `Wattly/Models/MetricSample.swift`: `BatterySample.powerFlow` 스냅샷
- `Wattly/Providers/BatteryProvider.swift`: SMC `PDTR`, `PSTR`, AppleSmartBattery IOKit 텔레메트리 수집
- `Wattly/Core/CardPresentation.swift`: `powerSourceLabel`, `powerSourceText`, `adapterPowerLabel`, `systemPowerLabel` 포맷터
- `Wattly/Views/CardExpandRegion.swift`: 3대 범주화 및 조건부 전력 흐름 렌더링
- `WattlyTests/PowerFlowTests.swift`, `WattlyTests/CardPresentationTests.swift`, `WattlyTests/BatteryPowerTests.swift`, `WattlyTests/PanelPresentationTests.swift`
