# Sailing Mode

## 상태

- 단계: 기능 정의 초안
- 구현 난이도: 쉬움
- 권장 우선순위: 1

## 목표

충전 상한에 도달한 뒤 배터리가 1~2% 떨어질 때마다 다시 충전되는 동작을 피한다. 사용자가 정한 범위 안에서는 어댑터가 시스템을 구동하고, 배터리가 하한까지 자연 방전된 뒤에만 상한까지 다시 충전한다.

## 현재 Wattly 기반

- `BatteryControlConfiguration.lowerHysteresisDelta`가 기본 2%, 허용 범위 1~5%로 존재한다.
- `BatteryControlEngine`은 상한에서 충전을 막고 `상한 - delta`에서 재개한다.
- 현재 설정 화면에는 이 범위가 노출되지 않는다.

관련 코드:

- `FanControlShared/BatteryControlProtocol.swift`
- `FanControlShared/BatteryControlEngine.swift`
- `Wattly/Views/Settings/SettingsBatterySection.swift`

## 최소 기능 범위

1. Sailing Mode 활성화 토글
2. 2%, 5%, 10% 범위 선택
3. 상한과 재충전 하한 동시 표시
4. `유지 중`, `Sailing 중`, `재충전 중` 상태 구분
5. Top Up 또는 Calibration 실행 중 일시 중단

## 안전·동작 규칙

- Sailing은 배터리를 능동적으로 방전하지 않는다.
- 범위 안에서 어댑터가 연결되면 충전을 시작하지 않는다.
- 사용자가 상한을 변경하면 새 범위를 즉시 다시 계산한다.
- 기능을 끄면 기존 충전 제한의 기본 히스테리시스로 돌아간다.

## 미결정 사항

- 10% 범위를 허용하려면 현재 delta 상한 5%를 확장해야 한다.
- Sailing Mode와 기본 히스테리시스를 하나의 설정으로 통합할지 결정해야 한다.
- Apple 기본 충전 제한이 활성화된 경우 충돌 감지 정책이 필요하다.

## 참고

- [AlDente Sailing Mode](https://apphousekitchen.com/aldente-overview/features/#sailing-mode)
