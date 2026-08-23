# 앱 종료·Sleep 중 충전 제어 유지

## 상태

- 단계: 구현 및 자동 검증 완료 · 실기 검증 진행 중
- 앱 정상 종료: 정책 유지(별도 옵션 없음)
- 사용자 전환: helper 설치 UID 단일 소유, 명시적 재설치로만 이전
- Sleep/Wake: LaunchDaemon의 IORegisterForSystemPower 완료-wake 이벤트에서 실제 레지스터 재확인
- Helper 재시작: root 소유 원자적 정책 파일을 읽어 앱 없이 복원
- 비활성화/제거: 실제 충전 허용 readback 확인 전에는 완료하지 않음

## 구현된 동작

앱은 정책의 요청자일 뿐이며, 실제 정책·상태의 권위는 LaunchDaemon helper와 하드웨어 readback에 있다. 정책은 `/Library/Application Support/Wattly/battery-control-v1.json`에 schema 1과 설치 UID, 정규화된 설정으로 원자 저장된다. helper는 시작 시 같은 UID의 유효한 정책만 복원하고, 누락·손상·다른 UID 정책은 fail-safe로 충전 허용을 검증한다.

정상적인 앱 종료는 충전 제한을 해제하지 않는다. helper의 KeepAlive 재시작, 앱 재실행, 완료-wake, 어댑터 재연결 같은 복구 경계에서만 상태 우선 reconcile을 수행해 불필요한 SMC 쓰기를 피한다. sleep 시작은 항상 acknowledge하며 배터리 gate를 해제하지 않는다. 비활성화, helper 교체/제거, 관리된 SIGTERM은 현재 one-shot release verifier로 `allowed` readback을 확인해야 완료된다.

두 번째 UID는 기존 정책을 조용히 변경할 수 없다. Settings는 설치된 소유권과 갱신/유지보수 상태를 표시하며, 소유권 이전은 명시적 재설치와 관리자 인증 뒤에만 가능하다. Settings는 백그라운드에서 인증을 요구하지 않는다.

## 자동 검증 근거

- `xcodegen generate` 뒤 새 임시 DerivedData에서 `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath <fresh> test` 통과.
- `plutil -lint Resources/com.dev.jjundev.WattlyFanDaemon.plist`, 두 helper 스크립트의 `zsh -n`, Debug build, 그리고 `Wattly.app/Contents/Helpers/WattlyFanDaemon` 실행 가능 파일 검증 통과.
- Swift Testing은 저장 전 하드웨어 쓰기, 매칭 UID 복원, 손상/다른 UID의 검증된 release, register payload/readback 거부, wake 완료 시점, retry 경계, 소유권 거부 및 release-before-removal을 자동 검증한다.

## 세대별 근거

| register generation | 이 검증의 레이블 | 범위 |
| --- | --- | --- |
| CHTE (modern) | 자동 테스트 통과 · 해당 세대 실기 미검증 | 4-byte gate 파싱·apply·release는 자동 검증만 수행 |
| CH0B/CH0C (legacy) | 자동 테스트 통과 · 해당 세대 실기 미검증 | 1-byte pair 파싱·apply·release는 자동 검증만 수행 |
| BCLM (Intel) | 자동 테스트 통과 · 해당 세대 실기 미검증 | ceiling 파싱·apply·release는 자동 검증만 수행 |
| bfF0/bfD0/bfE0 (firmware-managed) | 지원하지 않음 · firmware-managed hands-off | 감지 시 제어를 시도하지 않으며 release 안전 경로만 보존 |

이 작업에서는 물리 SMC 쓰기나 해당 세대 하드웨어 readback을 실행하지 않았으므로, 현대 Apple silicon의 과거 측정값으로 legacy 또는 Intel 성공을 추론하지 않는다.

## 남은 실기 검증 매트릭스

권한 있는 소유자 계정과 측정 대상 Mac에서 다음을 수행해 battery percentage, adapter 상태, register readback, UI maintenance record, 결과를 기록한다.

1. 80%를 설정한 뒤 Wattly를 정상 종료하고 helper가 정책을 유지하는지, 앱 재실행 시 status-first reconcile이 중복 SMC write를 만들지 않는지 확인한다.
2. 앱 종료 뒤 helper의 SIGTERM 및 SIGKILL 각각에서 KeepAlive 재시작과 startup restore를 확인한다.
3. gate inhibited 상태로 sleep/wake를 수행하고, 완료-wake readback과 단 한 번의 reconcile을 확인한다. hysteresis band 안의 pre-sleep allowed/inhibited 양쪽도 반복한다.
4. 어댑터를 분리·재연결해 recovery window가 한 번만 새로 열리는지, 제한을 비활성화해 desired `enabled=false`와 actual `allowed`를 확인한다.
5. 빠른 사용자 전환에서 두 번째 UID의 mutation 거부, 취소 시 원 소유자 보존, 관리자 인증 이전 시 durable save 후 적용을 확인한다.
6. readback 실패에서 full uninstall이 helper/store/default 삭제 전에 멈추는지, 복구 후 disable/full uninstall이 `allowed` 확인 뒤에만 진행되는지 확인한다.
7. CHTE, CH0B/CH0C, BCLM 장비 각각에서 readback/apply/release subset을 수행해 위 세대별 레이블을 갱신한다.

관리된 disable, uninstall, helper termination, KeepAlive restart는 Wattly의 복구 범위다. 반대로 root가 launchd까지 함께 제거한 수동 파일 삭제나 SIGKILL은 실행 중인 사용자 공간 코드가 남아 있지 않으므로 Wattly가 복구할 수 없다.

## 관련 코드

- `Wattly/Views/BatteryControlBridge.swift`
- `FanControlShared/BatteryControlEngine.swift`
- `FanControlShared/BatteryPolicyPersistence.swift`
- `WattlyFanDaemon/FanControlDaemon.swift`
- `WattlyFanDaemon/SystemPowerObserver.swift`
- `docs/plans/2026-08-22-battery-charge-limit-fixes.md`

## 참고

- [AlDente Stop Charging when App Closed](https://apphousekitchen.com/aldente-overview/features/#stop-charging-when-app-closed)
- [AlDente Stop Charging when Sleeping](https://apphousekitchen.com/aldente-overview/features/#stop-charging-when-sleeping)
