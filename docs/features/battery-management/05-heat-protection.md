# Heat Protection

## 상태

- 단계: 기능 정의 초안
- 구현 난이도: 보통
- 권장 우선순위: 5

## 목표

배터리 온도가 사용자가 정한 임계값을 넘으면 충전을 멈추고, 충분히 식은 뒤에만 충전을 재개한다. 고부하 작업과 충전이 동시에 발생하는 상황에서 추가 발열을 줄인다.

## 현재 Wattly 기반

- 배터리 온도 텔레메트리가 존재한다.
- 충전 허용·중지 상태 머신과 privileged helper가 존재한다.
- 기존 팬 제어에도 히스테리시스와 실패 안전장치가 있다.

관련 코드:

- `Wattly/Providers/TemperatureProvider.swift`
- `FanControlShared/BatteryControlEngine.swift`
- `WattlyFanDaemon/BatteryControlHardware.swift`

## 최소 기능 범위

1. Heat Protection 활성화 토글
2. 배터리 온도 임계값 설정
3. 임계값 초과 시 충전 중지
4. 최소 대기시간과 복귀 온도를 모두 만족하면 충전 재개
5. 현재 온도와 중지 이유 표시
6. 센서 읽기 실패 상태 표시

## 안전·동작 규칙

- 충전 한도보다 Heat Protection이 우선한다.
- 임계값 주변에서 충전이 반복 전환되지 않도록 온도와 시간 히스테리시스를 함께 사용한다.
- 센서 값이 비정상적이거나 오래되면 정상 온도로 간주하지 않는다.
- Calibration이 Heat Protection을 자동으로 해제하지 않는다.
- CPU/GPU 온도가 아니라 배터리 온도를 직접 판단 기준으로 사용한다.

## 미결정 사항

- 기본 임계값과 사용자 허용 범위를 정해야 한다.
- 재개 조건을 `임계값 - delta`로 할지 별도 복귀값으로 설정할지 결정해야 한다.
- 온도 센서 미지원 Mac에서 기능 노출 정책이 필요하다.

## 참고

- [AlDente Heat Protection](https://apphousekitchen.com/aldente-overview/features/#heat-protection)
