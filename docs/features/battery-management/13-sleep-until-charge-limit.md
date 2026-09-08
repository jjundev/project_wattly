# 충전 한도 도달 시까지 잠자기 방지 (Sleep Until Charge Limit)

## 상태

- 단계: 구현됨 (2026-09-09)
- 구현 난이도: 보통
- 권장 우선순위: 13

## 목표

맥북 사용자가 충전 한도(예: 80%)를 설정하고 충전기를 연결한 상태에서 덮개를 닫아도, 한도에 도달할 때까지 Mac이 잠들지 않고 충전을 계속 진행하도록 한다. 한도에 도달하면 즉시 잠자기 차단을 해제하여 Mac이 자동으로 정상 잠자기 상태로 들어가도록 한다. 기본값은 꺼짐이며(`Defaults.batterySleepUntilLimitEnabled = false`), 사용자가 설정에서 명시적으로 켜야 한다.

## 왜 필요한가 (배경 및 제약)

- **덮개 닫힘과 충전 중단 우려**: macOS는 기본적으로 외장 모니터가 없는 상태에서 노트북 덮개를 닫으면 즉시 클램쉘 슬립(Clamshell Sleep)에 들어간다. 절전 상태에서는 충전 속도가 매우 느려지거나 전원 프로파일에 따라 충전 동작이 의도대로 제어되지 않을 수 있으며, 사용자는 덮개를 닫고 자리를 비우더라도 목표 한도까지 완전히 충전되기를 원한다.
- **`caffeinate -i` / IOPMAssertion 한계**: 일반 유휴 잠자기 방지 어설션(`PreventUserIdleSystemSleep`)은 노트북 덮개 닫힘에 의한 잠자기를 막지 못한다.
- **`IOPMSetSystemPowerSetting("SleepDisabled", true)`**: 클램쉘 방전(12-clamshell-discharge)에서 입증되었듯, 루트 권한 데몬에서 이 설정을 켜면 덮개가 닫혀도 시스템 잠자기가 차단된다.
- **단일 소유자 및 상호 배제 원칙**: `SleepDisabled` 플래그는 시스템 전역 설정이다. 클램쉘 방전(`BatteryClamshellSleepPolicy`)과 한도 도달 잠자기 방지(`BatteryHoldSleepPolicy`)가 동일한 `IOPMSystemSleepInhibitor` 및 `sleepInhibitedAt` 타임스탬프 마커를 공유하되, 두 기능은 절대 동시에 켜지지 않는다 (방전 중 vs 충전 중).
- **다중 해제 안전망**: 한도 도달(`currentSoC >= limit`), 어댑터 분리(`!isPluggedIn`), 발열 보호 발동(`isInHeatProtection`), 4시간 절대 안전 타임아웃, 사용자 토글 OFF, 데몬 종료 시 즉시 차단이 해제된다.

## 설계 및 아키텍처

- **판정 엔진 (`BatteryHoldSleepPolicy.decide`)**: 순수 함수로 구현되어 5가지 결정을 내린다.
  - `.none` — 아무 작업도 필요 없음
  - `.engage` — 잠자기 차단 켜기 (`SleepDisabled = true`) 및 마커 저장
  - `.restamp(TimeInterval)` — 마커가 미래 시각으로 왜곡된 경우 현재 시각으로 재고정
  - `.disengage` — 잠자기 차단 해제 (`SleepDisabled = false`) 및 마커 삭제
  - `.expire` — 4시간 타임아웃 경과로 인한 자동 해제
- **켜지는 조건 (모두 참이어야 함)**:
  1. `allowed == true` (설정에서 옵트인 켜짐)
  2. `isPluggedIn == true` (AC 전원 어댑터 연결됨)
  3. `currentSoC < clampedLimitPercentage` (목표 충전 한도 미만)
  4. `!isCurrentlyInhibited` (충전이 하드웨어 또는 소프트웨어에 의해 억제되지 않고 활성 충전 중)
  5. `!isInHeatProtection` (발열 보호 미발동)
  6. 세션 만료 래치가 서 있지 않음
- **4시간 절대 안전 타임아웃** (`BatteryHoldSleepPolicy.duration = 4 * 60 * 60`): 충전기가 꽂힌 채 예기치 못한 상태로 무한정 Mac이 깨어 있는 것을 방지한다.
- **데몬 동기화 (`BatteryControlCoordinator.syncSleepInhibition`)**:
  - 클램쉘 방전 정책을 먼저 평가하고, 방전 중이 아니면 한도 도달 잠자기 방지 정책을 순차 평가하여 단일 `sleepInhibitedAt` 마커 및 `sleepInhibitor.setSleepDisabled`를 제어한다.
- **상태 미러링**: 잠자기 차단 활성화 여부는 `BatteryControlStatus.isSystemSleepInhibited`로 앱에 전파된다.
- **캐퍼빌리티 (`BatteryControlCapability.sleepUntilLimitV1`)**: 데몬이 지원하는 기능 목록에 포함되며, 설정 UI 토글의 활성화 가드로 사용된다 (전역 `requiredCapabilities`에는 추가하지 않아 구버전 헬퍼 사용자에게 불필요한 업데이트 알림을 띄우지 않음).

## 앱 및 UI

- **설정 항목**: 설정 › 배터리 카드의 "최대 충전 한도" 바로 아래에 `SettingsToggleRow`로 배치.
  - 타이틀: "충전 한도 도달 시까지 잠자기 방지"
  - 설명: "충전 중 덮개를 닫아도 목표 한도에 도달할 때까지 잠들지 않고 충전을 마칩니다. 도달 시 자동으로 잠자기에 들어갑니다."
  - 충전 제한이 꺼져 있거나 도우미가 캐퍼빌리티를 지원하지 않으면 비활성화 및 사유 안내.
- **상태 문구 (`BatterySectionPresentation.sleepUntilLimitHoldingText`)**:
  - "잠자기 차단 중 (충전 완료 후 자동으로 잠듭니다)"
- **30개 전 언어 로컬라이제이션 완료**: `Localizable.xcstrings`에 등록.

## 문제가 생겼을 때 — 긴급 복구 명령

시스템 잠자기가 계속 차단되어 있는 경우 수동으로 복구:

```bash
sudo pmset -a disablesleep 0
```

## 실기 검증 매트릭스

아래 항목은 사용자가 실기에서 직접 수행하여 검증한다.
확인 명령: `pmset -g | grep -i sleepdisabled`

| # | 시나리오 | 사전 조건 · 조작 | 기대 (통과 기준) |
|---|---|---|---|
| 1 | **기본 상태** | 충전 제한 ON, "충전 한도 도달 시까지 잠자기 방지" OFF | 어댑터 연결 상태에서 `SleepDisabled`가 0이어야 함 |
| 2 | **기능 활성화** | 충전 중(SoC < 한도) 상태에서 "충전 한도 도달 시까지 잠자기 방지" 토글 ON | 수 초 내 `SleepDisabled`가 1로 변경됨 |
| 3 | **덮개 닫힘 중 충전 유지** | 2번 상태에서 노트북 덮개를 닫음 | Mac이 잠들지 않고 계속 충전됨 (W 소비 유지) |
| 4 | **한도 도달 시 자동 해제** | 덮개가 닫힌 상태로 목표 충전 한도에 도달 | `SleepDisabled`가 0으로 복귀하고 Mac이 즉시 정상 잠자기에 들어감 |
| 5 | **어댑터 분리 즉시 해제** | 2번 상태에서 전원 어댑터 분리 | 5초 내 `SleepDisabled`가 0으로 복귀 |
| 6 | **발열 보호 발동 시 해제** | 2번 상태에서 발열 보호 발동 | 즉시 `SleepDisabled`가 0으로 복귀 |
| 7 | **4시간 타임아웃** | 4시간 동안 목표 한도에 미도달 | 타임아웃 경과 후 `SleepDisabled`가 0으로 복귀 |
| 8 | **토글 OFF 즉시 해제** | 2번 상태에서 토글을 끔 | 즉시 `SleepDisabled`가 0으로 복귀 |
