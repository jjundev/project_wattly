# Top Up

## 상태

- 단계: 기능 정의 초안
- 구현 난이도: 쉬움
- 권장 우선순위: 2

## 목표

평소 충전 한도를 유지하면서 외출이나 장시간 이동 전에 한 번만 100%까지 충전한다. 전원 어댑터를 한 번 분리하면 자동으로 기존 한도로 복귀한다.

## 현재 Wattly 기반

- 앱은 저장된 충전 한도를 helper에 적용할 수 있다.
- 배터리 텔레메트리에서 어댑터 연결 여부를 확인한다.
- 설정 변경과 wake 시 충전 구성을 다시 적용한다.

관련 코드:

- `Wattly/Views/BatteryControlBridge.swift`
- `Wattly/Views/Settings/SettingsBatterySection.swift`
- `FanControlShared/BatteryControlProtocol.swift`

## 최소 기능 범위

1. `한 번만 100% 충전` 실행 버튼
2. 실행 전 원래 충전 한도 저장
3. 100% 도달 상태 표시
4. 어댑터 분리 시 Top Up 종료
5. 다음 연결부터 원래 충전 한도 복원
6. 사용자가 언제든 취소 가능
7. 100% 도달 후 12시간 경과 시 자동 종료 + 알림

## 안전·동작 규칙

- Top Up은 영구 설정을 100%로 덮어쓰지 않는다.
- 앱이나 helper가 재시작되어도 원래 한도와 임시 상태를 복원해야 한다.
- Heat Protection이 발동하면 Top Up보다 온도 보호가 우선한다.
- Calibration과 동시에 실행할 수 없다.
- 만료 판정은 데몬(`BatteryControlCoordinator.evaluateTopUpExpiry`) 한 곳에서만 내린다. Calibration이 최종 100% 홀드에 `topUpActive`를 빌려 쓰게 되면 그 지점의 `calibrationActive` 인자로 예외를 넣는다.

## 미결정 사항

- ~~100% 도달 즉시 종료할지, 어댑터 분리 전까지 100% 상태를 유지할지 결정해야 한다.~~ **결정됨(2026-08-28)**: 100% 도달 후에도 홀드하되, 어댑터 분리 또는 **완충 후 12시간 경과** 중 먼저 오는 쪽에서 종료한다. 상시 전원 연결 사용자가 켜고 잊는 경우를 막기 위한 상한이다(Battery University BU-808 기준 25°C·100% 상시 유지는 연 20% 용량 손실).
- 메뉴바 팝오버와 설정 화면 중 어느 곳을 주 실행 위치로 할지 결정해야 한다.
- ~~완료·취소 알림 제공 여부를 결정해야 한다.~~ **결정됨(2026-08-28)**: 100% 도달 알림과 자동 해제 알림을 모두 제공한다. 자동 해제는 사용자가 직접 취소한 경우와 상태가 구분되지 않으므로, 앱은 데몬이 남긴 `BatteryMaintenanceTrigger.topUpExpired` 레코드를 보고 알린다.

## 참고

- [AlDente Top Up](https://apphousekitchen.com/aldente-overview/features/#top-up)

## 유예된 항목 (2026-08-28)

- **일부 문구는 아직 "어댑터 분리"만 말한다.** `BatteryStatusText`의 `topUpComplete`/`topUpHeldAtMax` 문장과 `SetBatteryTopUpIntent`의 단축어 확인 문구가 그렇다. 앞의 두 개는 `LegacyBatteryDetail`이 문장 전체를 정확히 일치시켜 구버전 헬퍼를 인식하므로, 문구를 바꾸려면 옛 문장을 인식 표에 함께 남겨야 한다. 별도 작업으로 분리한다.
- **헬퍼 능력 플래그를 추가하지 않았다.** 앱만 업데이트하고 헬퍼는 구버전인 사용자는 설정 화면에서 "12시간 뒤 자동 복귀"를 읽지만 실제로는 만료되지 않는다. `BatteryControlCapability`에 항목을 추가하면 감지할 수 있으나, `requiredCapabilities`에 넣으면 전 사용자가 재인증을 요구받으므로 지금은 넣지 않는다.
- **예약 충전은 이 상한의 적용을 받지 않는다.** `BatteryScheduleCoordinator`는 `topUpActive`가 아니라 `limitPercentage`를 100으로 바꾸므로, "평일 08:00 100% 완충" 같은 예약은 여전히 배터리를 100%에 무기한 둘 수 있다.
