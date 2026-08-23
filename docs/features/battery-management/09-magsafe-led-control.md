# MagSafe LED 제어

## 상태

- 단계: 기능 정의 초안
- 구현 난이도: 어려움
- 권장 우선순위: 9

## 목표

MagSafe LED 색상과 점멸을 Wattly의 실제 배터리 제어 상태에 맞춰 표시한다. 화면을 열지 않고도 충전, 충전 중지, 오류, 능동 방전 상태를 확인할 수 있게 한다.

## 현재 Wattly 기반

- helper가 SMC 쓰기를 수행할 수 있다.
- 배터리 제어 상태와 실패 이유가 구조화되어 있다.
- MagSafe LED용 레지스터 탐지와 쓰기 구현은 없다.

## 최소 기능 범위

1. 자동 상태 표시 모드
2. 충전 중: 주황
3. 충전 한도 도달: 초록
4. 제어 오류: 주황 점멸
5. 기능 비활성화 시 macOS 기본 제어로 복귀

수동 색상 선택과 Shortcuts 제어는 후속 범위로 둔다.

## 안전·동작 규칙

- 런타임 프로빙으로 지원 여부를 확인한다.
- 확인되지 않은 키를 모델 이름만으로 추정해 쓰지 않는다.
- 앱 종료, helper 종료, 기능 비활성화 시 macOS 기본 상태로 복구한다.
- 배터리 제어 실패를 정상 완료 색으로 표시하지 않는다.

## 미결정 사항

- MagSafe 2와 MagSafe 3를 모두 지원할지 결정해야 한다.
- USB-C 충전 사용자에게 기능 행을 숨길지 결정해야 한다.
- LED 제어가 충전기 펌웨어나 macOS 표시와 충돌하는지 실기 검증이 필요하다.

## 참고

- [AlDente Control MagSafe LED](https://apphousekitchen.com/aldente-overview/features/#control-magsafe-led)
