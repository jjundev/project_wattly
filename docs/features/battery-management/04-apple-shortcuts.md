# Apple Shortcuts 연동

## 상태

- 단계: 기능 정의 초안
- 구현 난이도: 보통
- 권장 우선순위: 4

## 목표

Wattly의 배터리 관리 기능을 Apple Shortcuts와 App Intents에 노출해 사용자가 시간, 위치, 전원 연결, 집중 모드 등과 결합할 수 있게 한다.

## 현재 Wattly 기반

- 앱 내부에 충전 한도 적용과 상태 조회 명령이 존재한다.
- `BatteryControlClient`가 helper와의 XPC 요청을 담당한다.
- 배터리 온도와 현재 잔량을 읽을 수 있다.

관련 코드:

- `Wattly/Views/BatteryControlBridge.swift`
- `Wattly/Views/Settings/SettingsBatterySection.swift`
- `FanControlShared/BatteryControlProtocol.swift`

## 최소 기능 범위

1. 현재 배터리 잔량 가져오기
2. 현재 충전 한도 가져오기
3. 충전 한도 설정
4. 충전 일시정지
5. Top Up 시작·취소
6. 배터리 온도 가져오기
7. 현재 Wattly 배터리 제어 상태 가져오기

능동 방전과 Calibration은 해당 엔진이 안정화된 뒤 별도 Intent로 추가한다.

## 안전·동작 규칙

- 쓰기 Intent는 실제 helper 결과를 반환해야 한다.
- helper 미설치, 인증 취소, 하드웨어 미지원 오류를 구분한다.
- Shortcuts에서 요청해도 Heat Protection과 저잔량 보호를 우회하지 않는다.
- 사용자가 요청하지 않은 자동 관리자 권한 프롬프트를 반복하지 않는다.

## 미결정 사항

- 백그라운드에서 helper 설치가 필요한 Intent를 허용할지 결정해야 한다.
- Intent 실행 결과를 알림으로 표시할지 결정해야 한다.
- 앱 내부 Schedule과 Shortcuts 자동화의 책임 경계를 정해야 한다.

## 참고

- [AlDente Apple Shortcuts Integration](https://apphousekitchen.com/aldente-overview/features/#shortcuts)
