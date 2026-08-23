# 수동·자동 방전

## 상태

- 단계: 기능 정의 초안
- 구현 난이도: 어려움
- 권장 우선순위: 10

## 목표

전원 어댑터를 연결한 상태에서도 시스템을 배터리로 구동해 현재 잔량을 목표 충전 한도까지 낮춘다. 자동 방전이 활성화되어 있으면 새 한도가 현재 잔량보다 낮을 때 별도 조작 없이 방전을 시작한다.

## 현재 Wattly 기반

- 충전 억제용 SMC 레지스터 generation 프로빙과 쓰기 경로가 있다.
- 배터리 잔량, 어댑터 연결, 충방전 전력을 읽을 수 있다.
- 개발기 조사 문서에는 `CHIE`가 어댑터 연결 중 방전을 강제하는 키로 기록되어 있으나 현재 구현 범위에서는 제외되어 있다.

관련 코드와 문서:

- `FanControlShared/BatteryControlKeys.swift`
- `WattlyFanDaemon/BatteryControlHardware.swift`
- `docs/plans/2026-08-23-battery-register-generations.md`

## 최소 기능 범위

1. 목표 잔량을 지정한 수동 방전
2. 현재 잔량이 한도보다 높을 때 자동 방전
3. 목표 도달 즉시 강제 방전 해제
4. 진행 상태, 현재 전력, 예상 조건 표시
5. 즉시 중지·충전 복구 버튼
6. 지원되지 않는 Mac에서는 기능 숨김 또는 비활성화

## 안전·동작 규칙

- `CHIE`를 포함한 모든 방전 키는 세대별 런타임 프로빙과 실기 검증을 거친다.
- 어댑터 분리, 저잔량, 센서 오류, helper 종료, sleep 진입 시 안전 정책을 명시한다.
- 목표 이하로 내려가지 않도록 정지 여유 구간을 둔다.
- Heat Protection과 저온·고온 보호가 능동 방전보다 우선한다.
- 실패한 쓰기를 무한 반복하지 않는다.
- 중지 또는 제거 시 강제 방전 레지스터를 반드시 원복한다.

## 검증 요구

- M1~M5 각 generation의 키 존재 여부와 payload 크기
- 어댑터 연결 중 실제 전력원이 배터리로 전환되는지
- 목표 도달 시 자동 복귀
- sleep, wake, crash, SIGTERM, helper 재시작 복구
- 저출력 USB-C 허브와 MagSafe 연결 시 동작 차이

## 미결정 사항

- 최소 허용 목표 잔량을 정해야 한다.
- 방전 중 sleep을 차단할지, 방전을 취소할지 결정해야 한다.
- 실험 기능으로 시작할지 정식 기능으로 노출할지 결정해야 한다.

## 참고

- [AlDente Discharge](https://apphousekitchen.com/aldente-overview/features/#discharge)
- [AlDente Automatic Discharge](https://apphousekitchen.com/aldente-overview/features/#automatic-discharge)
