# 앱 종료·Sleep 중 충전 제어 유지

## 상태

- 단계: 기능 정의 초안
- 구현 난이도: 보통~어려움
- 권장 우선순위: 6

## 목표

앱 종료, helper 재시작, 빠른 사용자 전환, sleep/wake 뒤에도 사용자가 설정한 충전 제한이 가능한 범위에서 유지되도록 한다. 동시에 앱과 helper가 사라졌을 때 배터리가 영구적으로 충전 불가 상태에 남지 않게 한다.

## 현재 Wattly 기반

- 앱 시작과 wake 시 저장된 충전 설정을 다시 적용한다.
- helper 재시작을 감지하기 위한 주기적 reconcile이 존재한다.
- helper 종료 시 충전 제어를 해제하는 복구 경로가 존재한다.
- 현재 battery register generation을 런타임 프로빙한다.

관련 코드와 문서:

- `Wattly/Views/BatteryControlBridge.swift`
- `FanControlShared/BatteryControlEngine.swift`
- `WattlyFanDaemon/FanControlDaemon.swift`
- `docs/plans/2026-08-22-battery-charge-limit-fixes.md`

## 최소 기능 범위

1. 정상 앱 종료 후에도 helper가 선택된 정책을 유지
2. wake 시 실제 하드웨어 상태 재확인·재적용
3. helper 재시작 시 앱 설정과 재동기화
4. 사용자 로그아웃·전환 시 정책 보존 여부 정의
5. 제거·비활성화·helper 종료 시 충전 허용 상태 복구
6. 마지막 재적용 결과와 실패 이유 표시

## 안전·동작 규칙

- 앱 상태보다 helper와 하드웨어 응답을 권위 있는 상태로 취급한다.
- sleep 중 앱 코드가 계속 실행된다고 가정하지 않는다.
- 실패한 쓰기를 무한 반복하지 않는다.
- 비정상 종료 뒤 충전 금지 레지스터가 남는 경우를 복구해야 한다.
- fan sleep 정책과 battery sleep 정책을 혼합하지 않는다.

## 미결정 사항

- LaunchDaemon의 sleep/wake 감지를 `IORegisterForSystemPower`로 전환할 범위를 정해야 한다.
- 앱 종료 시 제한 유지와 즉시 해제를 사용자 옵션으로 제공할지 결정해야 한다.
- 전원이 꺼진 동안 펌웨어가 레지스터를 유지하는지 세대별 실기 검증이 필요하다.

## 참고

- [AlDente Stop Charging when App Closed](https://apphousekitchen.com/aldente-overview/features/#stop-charging-when-app-closed)
- [AlDente Stop Charging when Sleeping](https://apphousekitchen.com/aldente-overview/features/#stop-charging-when-sleeping)
