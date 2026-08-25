# Apple Shortcuts 연동

## 상태

- 단계: 구현 완료 (`AppIntents` 프레임워크 연동 완료)
- 구현 난이도: 보통
- 권장 우선순위: 4

## 목표

Wattly의 배터리 관리 기능을 Apple Shortcuts와 App Intents에 노출해 사용자가 시간, 위치, 전원 연결, 집중 모드 등과 결합할 수 있게 한다.

## 현재 Wattly 기반

- 앱 내부에 충전 한도 적용과 상태 조회 명령이 존재한다.
- `BatteryControlClient`가 helper와의 XPC 요청을 담당한다.
- `BatteryIntentBridge`가 AppIntents와 XPC / `UserDefaults` / `BatteryProvider` 간 중계를 담당한다.
- 배터리 온도와 현재 잔량을 실시간으로 읽을 수 있다.

관련 코드:

- `Wattly/Intents/WattlyShortcuts.swift`
- `Wattly/Intents/BatteryIntentBridge.swift`
- `Wattly/Intents/Intents/GetBatteryStatusIntent.swift`
- `Wattly/Intents/Intents/GetBatteryLimitIntent.swift`
- `Wattly/Intents/Intents/SetBatteryLimitIntent.swift`
- `Wattly/Intents/Intents/SetBatteryLimitEnabledIntent.swift`
- `Wattly/Intents/Intents/SetBatterySailingIntent.swift`
- `Wattly/Intents/Intents/SetBatteryTopUpIntent.swift`
- `Wattly/Intents/Intents/SetBatteryHeatProtectionIntent.swift`
- `Wattly/Views/BatteryControlBridge.swift`
- `Wattly/Views/Settings/SettingsBatterySection.swift`
- `FanControlShared/BatteryControlProtocol.swift`

## 최소 기능 범위

1. 현재 배터리 잔량 가져오기 (`GetBatteryStatusIntent`)
2. 현재 충전 한도 가져오기 (`GetBatteryLimitIntent`)
3. 충전 한도 설정 (`SetBatteryLimitIntent`)
4. 충전 일시정지 / 활성화 (`SetBatteryLimitEnabledIntent`)
5. Sailing 모드 설정 (`SetBatterySailingIntent`)
6. Top Up 시작·취소 (`SetBatteryTopUpIntent`)
7. 발열 보호 설정 (`SetBatteryHeatProtectionIntent`)
8. 배터리 온도 및 Wattly 배터리 제어 상태 가져오기 (`GetBatteryStatusIntent`)

능동 방전과 Calibration은 해당 엔진이 안정화된 뒤 별도 Intent로 추가한다.

## 안전·동작 규칙

- 쓰기 Intent는 실제 helper 결과를 반환해야 한다.
- helper 미설치, 인증 취소, 하드웨어 미지원 오류를 구분한다 (`BatteryIntentError`).
- Shortcuts에서 요청해도 Heat Protection과 저잔량 보호를 우회하지 않는다.
- 사용자가 요청하지 않은 자동 관리자 권한 프롬프트를 반복하지 않는다 (백그라운드 실행 시 에러 반환).

## 결정 사항 (해결 완료)

- **백그라운드 도우미 미설치**: 암호 팝업 없이 `BatteryIntentError.helperNotInstalled` 에러를 즉시 반환.
- **알림 표시**: Shortcuts 자체 실행 결과/다이얼로그로만 안내하며, 중복 시스템 배너는 띄우지 않음 (Top Up 완료 등 기존 비동기 알림만 유지).
- **스케줄링 책임 경계**: 앱 내부 별도 스케줄러 대신 Apple Shortcuts의 개인용 자동화 기능에 스케줄링을 일원화.

## 참고

- [AlDente Apple Shortcuts Integration](https://apphousekitchen.com/aldente-overview/features/#shortcuts)
