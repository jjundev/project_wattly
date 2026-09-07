# 클램쉘 방전 (Clamshell Discharge)

## 상태

- 단계: 구현됨 (2026-09-07)
- 구현 난이도: 어려움
- 권장 우선순위: 12

## 목표

강제 방전(CHIE) 중 뚜껑을 닫아도 Mac이 잠들지 않게 해, 외장 디스플레이로 작업하는 사용자가 방전을 위해 뚜껑을 열어 둘 필요가 없게 한다. 기본값은 꺼짐이며(`Defaults.batteryClamshellDischargeEnabled = false`), 사용자가 설정에서 명시적으로 켜야 한다.

## 왜 문제가 생기는가 (실측, 2026-09-07, macOS 26.6 / Mac17,2)

- CHIE로 강제 방전 중이면 `pmset`은 Battery Power, `ExternalConnected`는 No를 보고한다. 어댑터가 물리적으로 꽂혀 있어도 macOS는 배터리 구동으로 본다.
- powerd의 클램쉘 판정 규칙(바이너리 문자열로 확인): `EvaluateClamshell. Result: %d because {DesktopMode with AC: %u, assertions %d}`. 방전 중에는 첫 조건(AC)이 깨지므로 뚜껑을 닫는 순간 잠들 근거가 선다.
- 실제로 잠들면 방전은 정지한다 — 602초 동안 −0.01%p(같은 조건에서 깨어 있었으면 −2.37%p). CHIE 레지스터 자체는 sleep을 넘어 그대로 유지되지만, sleep 중 소비전력(~0.05W)이 방전할 대상이 없을 만큼 작아서 사실상 방전이 멈춘 것과 같다.
- `caffeinate -i`나 `PreventUserIdleSystemSleep` 계열 어설션은 뚜껑 닫힘(clamshell sleep)을 막지 못한다. 이들은 유휴 잠자기(idle sleep)용이다.
- **닫힌 경로 — 다시 시도하지 말 것**: `IOPMAssertionCreateWithProperties` + `AppliesOnLidClose` 어설션은 비루트·루트 모두에서 `kIOReturnNotPrivileged`(`0xE00002C1`)로 거부된다. powerd만 `com.apple.private.iokit.assertonlidclose` 사설 엔타이틀먼트를 갖고 있어, 제3자 프로세스는 루트 권한으로도 이 경로를 쓸 수 없다.
- **닫힌 경로 — 다시 시도하지 말 것**: `pmset desktopmode` / `IOPMTestDesktopModeSet`도 존재는 하지만 호출 시 "Not entitled to update desktopmode"로 거부된다. 데스크탑 모드를 직접 흉내 내는 접근은 쓸 수 없다.
- 반면 `IOPMSetSystemPowerSetting("SleepDisabled", true)`(`pmset -a disablesleep 1`이 내부에서 부르는 것과 같은 함수)는 **루트 권한만으로 성공**하고, 1.5초 안에 `pmset -g`·`ioreg` 양쪽의 `SleepDisabled`에 반영된다. 비루트 프로세스(즉 앱)에서 부르면 `kIOReturnNotPrivileged`로 거부된다 — 그래서 이 값은 반드시 데몬에서만 쓴다.
- `SleepDisabled`는 **재부팅을 넘어 남는** 시스템 전역 설정이다. 이 사실 하나 때문에 설계 전체가 "켜는 조건은 좁게, 끄는 경로는 여러 겹으로"가 됐다 — 아래 설계 참고.
- `ioreg`의 `AppleClamshellCausesSleep`은 클램쉘(뚜껑) 조건만 반영하며 `SleepDisabled`와는 무관하다. `SleepDisabled=1`이어도 이 값은 그대로 `Yes`로 남는다. 즉 **이 값으로는 이 기능이 실제로 동작하는지 검증할 수 없다** — 아래 검증 매트릭스의 1번 행처럼 실제로 뚜껑을 닫아 보는 것만이 유일한 증거다.

## 설계

- **소유자는 데몬 하나뿐**: `BatteryControlCoordinator`. 앱 프로세스는 비루트라 `IOPMSetSystemPowerSetting` 호출 자체가 거부되므로 `SystemSleepInhibiting`을 구현하지 않는다(`FanControlShared/SystemSleepInhibiting.swift`). 실제 구현은 데몬 전용 `WattlyFanDaemon/IOPMSystemSleepInhibitor.swift` 하나뿐이고, 앱·테스트에는 아무 것도 하지 않는 `NoopSystemSleepInhibitor`가 기본값으로 주입된다.
- **판정은 순수 함수 하나**: `FanControlShared/BatteryClamshellSleepPolicy.decide(allowed:isDischarging:inhibitedAt:expiredForCurrentDischarge:now:)`. 다섯 가지 결정만 낸다.
  - `.none` — 아무 것도 하지 않는다.
  - `.engage` — 마커(`sleepInhibitedAt`)를 저장하고 `SleepDisabled`를 켠다.
  - `.restamp(TimeInterval)` — 저장된 마커 시각이 미래에 있으면(시계가 뒤로 돌아간 경우) 지금 시각으로 다시 찍는다. 껐다 켜지는 것이 아니라 12시간 카운트다운만 재고정한다.
  - `.disengage` — `SleepDisabled`를 끄고 마커를 지운다.
  - `.expire` — `.disengage`와 같지만, 이번 방전 세션이 끝날 때까지 재개를 막는 래치(`clamshellExpiredForCurrentDischarge`)를 함께 세운다. 이 래치는 엔진의 방전이 꺼지는 순간(`isDischargingNow == false`) 코디네이터가 리셋한다.
  - 이 함수는 `BatteryControlCoordinator.syncSleepInhibition()` 하나에서만 호출되고, 이 메서드는 `sample`과 `publish` 양쪽 경로에서 지나가는 **유일한 동기화 지점**이다.
- **켜지는 조건(세 가지 모두 참)**: 앱이 보낸 `clamshellDischargeAllowed`(= 설정 옵트인 && 외장 디스플레이 존재) · 엔진의 `isDischargingNow`(수동·자동·캘리브레이션 방전 구분 없이 CHIE가 실제로 걸려 있으면 참) · 이번 방전 세션에서 12시간 만료 래치가 서 있지 않음.
- **12시간 절대 만료** (`BatteryClamshellSleepPolicy.duration = 12 * 60 * 60`): Top Up 만료와 같은 상수를 재사용한 값이 아니라 이 기능 전용으로 다시 계산된 값이다 — 실측 방전 속도 0.11~0.33 %p/분 기준으로 수동 100→50%가 최대 약 8시간, 캘리브레이션 100→20%가 약 7시간이므로 12시간이면 가장 느린 케이스에도 여유가 남는다.
- **마커 우선 순서가 안전성의 전부다**: 켤 때는 `persistPolicy`로 `sleepInhibitedAt`을 먼저 디스크에 쓴 뒤에 `setSleepDisabled(true)`를 부른다. 그 사이 데몬이 죽어도, 다음 시작(`restore`/`restoreWithoutPowerReading`)이나 삭제 검증(`--verify-battery-release`)은 파일의 마커만 보고 무조건 `SleepDisabled`를 끈다 — 하드웨어 상태를 몰라도 안전하게 정리된다.
- **끄는 경로는 한 곳(`releaseSleepInhibition`)으로 모이지만 호출부는 많다**: 방전 종료(목표 도달·사용자 중지) · 어댑터 분리 · 발열 보호 발동 · 옵트인 해제 · 외장 디스플레이 분리 · 12시간 만료 · 데몬 시작 시 고아 마커 정리(`restore`) · 데몬 정상 종료(`releaseForTermination`) · 헬퍼 교체·삭제 시 `--verify-battery-release`. 마지막 두 경로는 SMC 연결 성패와 무관하게 먼저 실행된다 — 아래 "구현 중 바뀐 것" 참고.
- **소유하지 않는 경우**: `.engage`로 켜기 직전 `sleepInhibitor.readSleepDisabled()`가 `false`가 아니면(이미 `true`이거나 읽기 자체가 실패해 `nil`이면) 아무 것도 하지 않는다. 사용자가 터미널에서 직접 `sudo pmset -a disablesleep 1`을 켜 둔 값을 Wattly가 가로채 나중에 꺼 버리는 사고를 막기 위해서다. 마커를 남기지 않으므로 이 경우 Wattly는 끌 때도 손대지 않는다.
- **저장하지 않는 것**: `persistPolicy`는 정책 파일에 쓸 때마다 `clamshellDischargeAllowed`를 무조건 `false`로 덮어써서 저장한다(`manualDischargeActive`와 같은 취급). 앱이 죽은 채 데몬만 재시작되면 잠자기 차단 없이 안전하게 시작한다 — 앱이 살아 있으면 60초 reconcile이 다시 옵트인 값을 실어 보낸다.
- **소유권 불일치 시에도 마커는 미러링한다**: `resolvedStoredPolicy()`는 정책 파일의 `ownerUID`가 이 데몬의 것과 달라도 `sleepInhibitedAt`만은 읽어 온다. 이 값은 "이 Mac"의 상태이지 특정 사용자의 정책이 아니기 때문이다 — 소유자가 바뀐 뒤에도 고아 플래그를 정리할 수 있게 한다.

## 앱 쪽 옵트인 계산과 "취소 대 유지" 라우팅

- `Wattly/Control/BatteryControlClient.swift`의 `clamshellAllowance` 클로저(기본값 `defaultClamshellAllowance`)가 `clamshellDischargeAllowed`의 유일한 계산식이다: `UserDefaults의 옵트인 && ExternalDisplayDetector.hasExternalDisplay()`. `revivedConfiguration`과 `reconcile` 양쪽에서 이 클로저를 통해 값을 실어 보낸다.
- `Wattly/Views/BatteryControlBridge.swift`에는 이 값을 바꾸는 두 개의 트리거가 있고, **둘 다 `handleConfigChange`→`push` 경로를 타지 않고 `applyRequested`로 직접 간다**:
  1. `.onChange(of: clamshellDischargeEnabled)` — 설정의 토글.
  2. `NSApplication.didChangeScreenParametersNotification` — 외장 모니터 연결·해제.
- 이렇게 우회하는 이유가 이 기능의 핵심 안전장치다: 일반 `push`는 `enabled`와 발열 보호가 둘 다 꺼져 있으면 "비활성화 요청"으로 취급해 `manualDischargeActive=false`를 실어 보낸다. 그런데 수동 방전은 충전 한도가 꺼진 채로도 동작할 수 있으므로, 그 경로를 그대로 탔다가는 **클램쉘 토글을 만지거나 모니터를 뽑는 것만으로 진행 중인 방전 자체가 취소된다.** `applyRequested`는 `preservingActivity`로 직전에 읽은 상태의 진행 중 활동을 되살리므로, 방전은 그대로 두고 잠자기 차단 값만 바뀐다.
- 이 라우팅 규칙은 SwiftUI `.onChange` 핸들러 본문이라 이 코드베이스의 유닛 테스트로는 도달할 수 없다 — 아래 검증 매트릭스 10번 행이 이 회귀를 잡는 유일한 안전망이다.
- `Wattly/Core/BatterySectionPresentation.swift`가 토글 자체의 게이팅을 담당한다: `isClamshellDischargeToggleEnabled`/`clamshellDischargeToggleDisabledReason`은 헬퍼 미연결(`도우미에 연결되지 않음`), 구버전 헬퍼(`.clamshellDischargeV1` 캐퍼빌리티 없음 → `클램쉘 방전을 사용하려면 도우미 업데이트가 필요합니다.`), CHIE 미지원 기기(`이 Mac은 강제 방전을 지원하지 않습니다.`) 세 가지를 구분한다. `.clamshellDischargeV1`은 전역 `requiredCapabilities`에는 넣지 않는다 — 넣으면 이 기능을 쓰지 않는 모든 사용자가 "도우미 업데이트 필요"로 뜬다.
- 같은 파일의 `sleepInhibitedText`가 데몬이 `isSystemSleepInhibited == true`를 보고할 때 진행 배너에 붙는 "잠자기 차단 중 (덮개를 닫아도 방전이 계속됩니다)" 줄이고, `calibrationLidGuidanceText`가 캘리브레이션 preflight의 뚜껑 안내 문구를 클램쉘 허용 여부에 따라 "닫아도 된다"/"열어 둬야 한다"로 갈라 준다.

## 사용자에게 알리는 부작용

- 플래그가 켜진 동안 Apple 메뉴의 "잠자기"도 동작하지 않는다 — 설정의 토글 설명 문구("외장 디스플레이가 연결된 동안 방전 중에는 Mac이 잠들지 않습니다. Apple 메뉴의 잠자기도 동작하지 않습니다.")에 명시했다.
- 화면 끄기(displaysleep)는 그대로 동작한다. `SleepDisabled`는 시스템 잠자기만 막을 뿐 디스플레이 절전과는 무관하며, 방전은 화면이 꺼져도 계속된다.

## 구현 중 계획서와 달라진 것

1. **`--verify-battery-release`의 고아 플래그 정리 순서.** 원래 계획은 SMC 연결을 먼저 열고 실패하면 `exit(74)`으로 나가는 기존 흐름 아래에 정리 코드를 붙이는 것이었다. 그렇게 두면 SMC 연결이 실패하는 순간(하드웨어 이상이 가장 자주 겹치는 바로 그 경로) 정리 코드에 도달하기도 전에 프로세스가 종료돼, 재부팅을 넘어 살아남는 `SleepDisabled`가 영원히 켜진 채 남는다 — Mac이 다시는 자동으로 잠들지 않는 최악의 결과다. 그래서 `WattlyFanDaemon/main.swift`에서 이 정리를 **SMC 연결 가드보다 먼저** 실행하도록 옮겼다. 정책 파일에 Wattly의 소유 마커(`sleepInhibitedAt != nil`)가 있을 때만 `IOPMSystemSleepInhibitor().setSleepDisabled(false)`를 부르고, 실패하면 `"Unable to clear orphaned SleepDisabled"`를 stderr에 남긴다(종료 코드는 SMC 해제 안전성 보고용으로 그대로 둔다).
2. **데몬 단독 빌드 명령.** 계획서 초안의 `-target WattlyFanDaemon`은 이 툴체인에서 `-derivedDataPath`와 함께 쓰면 "The flag -scheme, -testProductsPath, or -xctestrun is required when specifying -derivedDataPath"로 거부된다. `xcodegen`이 `WattlyFanDaemon` 스킴도 함께 생성해 두므로, 실제로 쓰는 명령은:
   ```bash
   xcodebuild -project Wattly.xcodeproj -scheme WattlyFanDaemon -configuration Debug \
     -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
   ```

## 관련 코드

- `FanControlShared/BatteryClamshellSleepPolicy.swift` — 순수 판정 함수, 12시간 상수
- `FanControlShared/SystemSleepInhibiting.swift` — 프로토콜 + `NoopSystemSleepInhibitor`
- `FanControlShared/BatteryControlCoordinator.swift` — `syncSleepInhibition`, `releaseSleepInhibition`, `persistPolicy`, `restore`/`restoreWithoutPowerReading`/`releaseForTermination`의 마커 정리
- `WattlyFanDaemon/IOPMSystemSleepInhibitor.swift` — `IOPMSetSystemPowerSetting`/`IOPMCopySystemPowerSettings` 바인딩
- `WattlyFanDaemon/main.swift` — `--verify-battery-release`의 고아 마커 정리, 억제기 주입
- `Wattly/Core/ExternalDisplayDetector.swift` — 외장 디스플레이 판정(앱만 수행; 데몬은 WindowServer 없이 CG를 못 부른다)
- `Wattly/Control/BatteryControlClient.swift` — `clamshellAllowance`, `revivedConfiguration`
- `Wattly/Views/BatteryControlBridge.swift` — 토글·모니터 변화 → `applyRequested` 직결 라우팅
- `Wattly/Core/BatterySectionPresentation.swift` — 토글 게이팅, 배너·preflight 문구
- `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift` — 토글 행 UI
- `Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift` — 캘리브레이션 preflight 조건부 안내

## 문제가 생겼을 때 — 복구 명령

플래그가 어떤 이유로든 고아로 남아 Mac이 잠들지 않는다면(예: 위 버그가 고쳐지기 전 버전, 또는 예상 못 한 경로), 다음 명령이 즉시 되돌린다.

```bash
sudo pmset -a disablesleep 0
```

## 실기 검증 매트릭스

아래 항목은 **사용자가 실기에서 직접 수행**한다 — `sudo`가 필요하거나 실제로 뚜껑을 닫는 조작이 포함되어 있어 에이전트가 대신 수행할 수 없다. 각 행은 정확한 사전 조건 · 조작 · 통과/실패를 가르는 관찰값을 담고 있다.

공통 확인 명령: `pmset -g | grep -i sleepdisabled` (0 또는 1이 아니면 키가 아예 없는 것 — 기본값 꺼짐).

| # | 시나리오 | 사전 조건 · 조작 | 기대(통과 기준) | 결과 |
|---|---|---|---|---|
| 1 | **실제 뚜껑 닫힘 (핵심 검증)** | 외장 디스플레이 연결 + 어댑터 연결 + 설정에서 "덮개를 닫아도 방전 계속" ON. 수동 방전을 시작한 뒤, 노트북 뚜껑을 실제로 닫는다. `AppleClamshellCausesSleep`은 이 기능과 무관하게 항상 `Yes`로 남으므로 검증에 쓸 수 없다 — 아래 관찰만이 유일한 증거다. | 뚜껑을 닫은 채로: 외장 화면이 계속 켜져 있다, `pmset -g`의 `SleepDisabled`가 1이다, 몇 분 뒤 SoC가 실제로 하락해 있다(정지해 있지 않다) | |
| 2 | 어댑터 분리 | 1번 상태에서 전원 어댑터를 뽑는다 | 5초 내 방전이 취소되고 `SleepDisabled`가 0으로 내려간다, 이후 Mac이 정상적으로 잠자기에 들어간다(뚜껑이 닫혀 있으면 즉시, 열려 있으면 idle 타이머 경과 후) | |
| 3 | 외장 모니터 분리 | 1번 상태에서 외장 모니터 케이블을 뽑는다 | 앱이 `allowed=false`를 보내 `SleepDisabled`가 0으로 내려가고, Mac이 잠자기에 들어간다 | |
| 4 | 데몬 강제 종료 | 방전 진행 중 `sudo kill -9 <daemon pid>` | launchd 재기동 후 `SleepDisabled`가 일단 0(고아 마커 정리), 60초 내 앱의 reconcile로 다시 1로 복귀 | |
| 5 | 목표 도달 | 수동 방전이 목표 SoC에 도달할 때까지 기다린다(또는 낮은 목표로 설정) | `SleepDisabled`가 0으로 내려가고, 진행 배너의 "잠자기 차단 중" 줄이 사라진다 | |
| 6 | 사용자가 직접 켜둔 값은 건드리지 않는다 | 방전을 시작하기 **전에** `sudo pmset -a disablesleep 1`을 미리 실행해 둔 뒤, 옵션 ON 상태로 방전을 시작했다가 종료까지 진행 | 시작·진행·종료 전 과정에서 Wattly가 값을 바꾸지 않는다(계속 1로 유지) | |
| 7 | 앱 삭제 흐름 | 방전이 진행 중인 상태에서 공식 삭제 흐름(헬퍼 제거 포함)을 실행한다 | 삭제 완료 후 `pmset -g`의 `SleepDisabled`가 0 | |
| 8 | 외장 디스플레이 없이 시작 | 옵션 ON, 외장 디스플레이는 연결하지 않은 채 수동 방전 시작 | `clamshellDischargeAllowed`가 false로 계산되어 `SleepDisabled`는 계속 0 | |
| 9 | 캘리브레이션 방전 단계 | 옵션 ON, 외장 디스플레이 연결 상태에서 캘리브레이션 모드를 시작해 방전 단계(`dischargeToFloor`)까지 진행 | 방전 단계에서만 `SleepDisabled`가 1이고, 충전 단계(`rechargeToFull`)로 전환되는 순간 0으로 내려간다 | |
| 10 | **`push` 대 `applyRequested` 라우팅 (핵심 검증)** | 충전 한도 OFF + 발열 보호 OFF 상태에서 수동 방전을 시작한다(이 조합이면 일반 `push`가 "비활성화 요청"으로 오인하기 가장 쉬운 상태). 방전이 도는 동안: (a) 클램쉘 토글을 ON→OFF→ON으로 두 번 뒤집는다, (b) 외장 모니터를 뽑았다가 다시 꽂는다. 이 코드 경로는 SwiftUI `.onChange` 핸들러 본문이라 유닛 테스트로 도달할 수 없다 — 이 행이 유일한 안전망이다. | 매 조작 후 방전이 취소되지 않고 계속 진행 중이어야 한다(SoC 표시가 계속 움직인다). `SleepDisabled`만 1↔0으로 토글의 상태·모니터 연결 여부를 따라 바뀐다 | |
