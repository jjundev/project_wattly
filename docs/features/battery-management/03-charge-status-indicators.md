# 충전 상태 아이콘과 상태 표시

## 상태

- 단계: 기능 정의 초안
- 구현 난이도: 쉬움
- 권장 우선순위: 3

## 목표

사용자가 현재 배터리 제어 상태와 실제 전력원을 즉시 이해할 수 있게 한다. 단순히 `충전 중/아님`이 아니라 Wattly가 어떤 정책을 적용하고 있는지 구분한다.

## 현재 Wattly 기반

- helper 상태에 `.charging`, `.inhibited`, `.unsupported`, `.unavailable`이 존재한다.
- 구조화된 `BatteryControlStatusReason`과 하드웨어 지원 여부를 UI까지 전달한다.
- 배터리 카드에서 충전·방전 전력과 어댑터 연결 상태를 표시한다.

관련 코드:

- `FanControlShared/BatteryControlProtocol.swift`
- `Wattly/Core/BatterySectionPresentation.swift`
- `Wattly/Views/Settings/SettingsBatterySection.swift`

## 최소 기능 범위

다음 상태를 서로 다른 문구와 아이콘으로 표시한다.

- 충전 한도까지 충전 중
- 충전 한도 도달·어댑터 우회 구동
- Sailing 범위에서 유지 중
- Heat Protection으로 충전 중지
- Top Up 진행 중
- 능동 방전 중
- Calibration 진행 중
- 하드웨어 미지원 또는 제어 실패

## 안전·동작 규칙

- 명령한 상태와 helper가 확인한 실제 상태를 구분한다.
- 실패 상태를 정상적인 충전 중지로 표시하지 않는다.
- 색상만으로 상태를 전달하지 않고 문구와 접근성 레이블을 함께 제공한다.
- 마지막 갱신 시각이 오래된 상태는 `현재 상태`로 단정하지 않는다.

## 미결정 사항

- 메뉴바 아이콘 자체를 동적으로 변경할지 결정해야 한다.
- 여러 정책이 동시에 성립할 때 대표 상태 우선순위가 필요하다.
- 상세 상태 이력을 보관할지 결정해야 한다.

## 참고

- [AlDente Live Status Icons](https://apphousekitchen.com/aldente-overview/features/#live-status-icons)
