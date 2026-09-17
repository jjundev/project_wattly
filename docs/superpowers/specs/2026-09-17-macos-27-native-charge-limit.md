# macOS 27 네이티브 충전 제한 백엔드 설계

- 작성일: 2026-09-17
- 실기: MacBook Pro M5 (`Mac17,2`), macOS 27.0 (26A428), 시스템 펌웨어 `20457.1.29`, Xcode 27.0
- 배경 메모리: `macos-27-sensor-audit-facts.md`, `macos-27-charge-limit-direction.md`, `battery-charge-limit-register-axis.md`
- 범위: macOS 27 감사 3축 중 **3축(충전 제한)의 첫 라운드** — 네이티브 제한 + Top Up. CHIE 방전 계열 복구(캘리브레이션·수동 방전·클램쉘)는 별도 설계·계획이다.

## 1. 문제

macOS 27 릴리스 펌웨어에서 Wattly가 충전을 멈추는 데 쓰던 SMC 레지스터가 전부 사라졌다. 코드는 그대로 컴파일·테스트 통과하고 설계대로 "손을 뗀다" — 그래서 충전 제한·Top Up·방전·캘리브레이션이 전부 멈춘다.

| 키 | 비루트 | 루트(uid 0) | 의미 |
|---|---|---|---|
| `CHTE` `CH0B` `CH0C` `BCLM` `CHWA` `CH0I` | kern 0 / SMC 132 | 동일 | 진짜 부재 |
| `bfF0` `bfD0` `bfE0` `CHLS` `CH0J` | kern `0xE00002C1` | **동일(거부)** | 존재하나 커널이 막음 |
| `CHIE` | `hex_` 1B, writable | 쓰기 성공 | 남아 있음 |

- 데몬의 `keyInfo`는 커널 실패를 `nil`로 돌리므로(`WattlyFanDaemon/SMCControlConnection.swift:11-23`) `firmwareManagedKeys` 감지가 걸리지 않고 판정은 `.unsupported`다. 결과는 `canDriveCharging == false`(`FanControlShared/BatteryControlKeys.swift:56-61`) → `isHardwareSupported == false`(`FanControlShared/BatteryControlEngine.swift:63-65`) → 기능 전체 비활성.
- 상류 도구도 같다: `charlie0129/batt`는 펌웨어 `20457.0.125`+를 미지원으로 표시, `geoochi/battery-macos-27`·`srimanachanta/Stasis#31`는 `bf*`가 루트에서도 거부된다고 보고. SMC 직접 쓰기 경로는 닫혔다.

## 2. 실측된 대체 수단: 애플 네이티브 충전 제한(PowerUI)

비공개 `/System/Library/PrivateFrameworks/PowerUI.framework`의 `PowerUISmartChargeClient`(`initWithClientName:`). **전부 비루트·entitlement 없이 실측**(2026-09-17).

| 셀렉터 | 타입 인코딩 | 실측 |
|---|---|---|
| `isMCLSupported` | `B16@0:8` | `true` |
| `availableChargeLimitsWithError:` | `@24@0:8^@16` | `[80, 85, 90, 95, 100]` |
| `getMCLLimitWithError:` | `C24@0:8^@16` | 현재 제한(일시 해제 중에는 100으로 마스킹) |
| `isMCLCurrentlyEnabled:` | `Q24@0:8^@16` | `0` 꺼짐 · `1` 켜짐 · `3` 일시 해제 |
| `setMCLLimit:error:` | `B28@0:8C16^@20` | 80 → 즉시 켜짐, 100 → 자동 꺼짐, 70 → `PowerUISmartChargingErrorDomain Code=4` |
| `temporarilyDisableMCL:` | `B24@0:8^@16` | 1분 내 충전 재개, 상태 3 |

거동 실측:

- `setMCLLimit:80` 직후(어댑터 연결 시) `pmset -g battlimit`에 `manualChargeLimit`/`chargeSocLimitSoc = 80`/`chargeSocLimitDrain = 1` 항목 등장. 소유자는 `/usr/libexec/PowerUIAgent`.
- 58→80% 충전 후 **80% 도달 1분 내 0 mA 패스스루**, 오버슈트 없이 유지.
- 100%에서 80 재무장 → 어댑터 연결(`ExternalConnected = Yes`)인 채 **−0.85 A로 방전, 87분에 80% 안착 후 0 mA**. pmset은 "AC attached"로 표시하므로 방전 판정은 **전류 부호**로 한다.
- **일시 해제는 완충으로도, 어댑터 분리·재연결로도 풀리지 않는다.** `setMCLLimit:`을 다시 부르면 즉시 복귀한다.
- `currentChargeLimit:`은 시험 내내 100 — readback으로 쓰지 않는다.
- Swift 6 모드에서 `dlopen` + `NSClassFromString` + `@convention(c)` IMP 캐스트로 경고 없이 호출됨을 확인.

## 3. 결정

### 3-1. 사용자 결정(2026-09-17)

1. 80% 미만 제한은 macOS 27에서 포기한다. (제한 피커는 이미 `[80, 85, 90, 95]` — `Wattly/Views/Settings/SettingsBatterySection.swift:33`, `Wattly/Views/Settings/ScheduleEditorSheet.swift:123`.)
2. 비공개 PowerUI 의존을 수용한다. 전제는 "실패하면 조용히 미지원으로 떨어진다".
3. 연결 지점은 앱 안 별도 제어기다(루트 데몬·`BatteryControlHardwareProtocol` 뒤가 아님).

### 3-2. 설계 결정

| # | 결정 | 답 | 근거 |
|---|---|---|---|
| 0 | 접근 | 앱 안 서비스가 `BatteryControlClient`의 요청 계약(`.configure(Data)`/`.status` → 인코딩된 `BatteryControlServiceStatus`)을 그대로 말한다 | 주입점이 이미 있다(`Wattly/Control/BatteryControlClient.swift:12, 69-76`). 브리지·정책·표시·단축어·스케줄·제거 경로가 무수정 |
| 1 | 백엔드 선택 | **구동 가능한 레지스터가 전부 132로 부재 증명** + PowerUI 지원일 때만 네이티브. 테스트 호스트에서는 항상 SMC | `runtimeDrivableRegisterProbe`(`FanControlShared/BatteryControlKeys.swift:221-248`), 앱 `SMCConnection.probeKeyInfo`(`Wattly/Core/SMC.swift:69`). macOS 26.x 동작 불변 |
| 2 | 라우팅 위치 | 클라이언트 **기본 핸들러 안** | `BatteryControlClient()` 생성 지점 5곳(`WattlyApp.swift:27`, `BatteryIntentBridge.swift:16,26`, `AppUninstaller.swift:75`, `PopoverContentView.swift:22`) |
| 3 | 상태 보관 | 프로세스 전역 actor + `UserDefaults` | 단축어가 호출마다 새 클라이언트를 만든다 |
| 4 | Top Up 구현 | `temporarilyDisableMCL:` (100 설정 아님) | 시스템 UI에 정직하게 표시된다 |
| 5 | Top Up 종료 | 기존 `BatteryTopUpExpiry.decide`(100% 후 12 h) + 어댑터 분리 + 사용자 취소. 앱이 꺼져 있었으면 다음 요청(실행 직후) 때 | 네이티브는 스스로 안 풀린다(§2). 순수 함수 재사용(`FanControlShared/BatteryTopUpExpiry.swift`) |
| 6 | 자가 복구 | **모든 요청이 조정 패스**: 네이티브 상태를 읽고, 계획과 다르면 다시 쓴다 | 데몬과 같은 성질. 앱의 60초 reconcile·5초 상태 폴링이 곧 박동 |
| 7 | capability | `persistedPolicyV1`·`hardwareGateReadbackV1`·`systemPowerEventsV1` 광고 | `shouldReapply`가 `desiredConfiguration` 비교 경로로 가서 Top Up을 보존(`FanControlShared/BatteryControlPolicy.swift:62-79`), wake는 `.refreshStatus`(`Wattly/Views/BatteryControlBridge.swift:174-182`) |
| 8 | 수락 판정 | `desiredConfiguration` + `lastMaintenance(.clientConfiguration, .applied/.verified)` + `actualGate` 합성 | `accepted`가 셋 다 요구(`BatteryControlPolicy.swift:93-108`) |
| 9 | 기능 숨김 신호 | 새 옵셔널 필드 `controlBackend: BatteryControlBackend?` | 세일링·열 보호·잠자기 억제는 capability 게이트가 없다. 구버전 도우미 페이로드는 `nil`로 디코드 |
| 10 | 숨기는 것 | 세일링, 열 보호, "한도 도달 시까지 잠자기 방지" | 셋 다 "지금 충전을 멈춘다/재개한다" 원시 명령이 필요하거나(세일링·열 보호) 펌웨어가 잠든 동안에도 집행해 불필요(잠자기 방지) |
| 11 | 방전 섹션 | 손대지 않는다 — `isDischargeHardwareSupported = false`로 기존 "미지원" 사유가 그대로 뜬다 | 이번 라운드 범위 밖(§5) |
| 12 | 저장값 | 숨기되 지우지 않는다 | 기존 규칙(`Wattly/Core/BatterySectionPresentation.swift:252-262`) |
| 13 | 도우미 설치 | 네이티브에서는 제한 때문에 설치가 뜨지 않는다 | 설치는 `mode == .unavailable`일 때만(`BatteryControlPolicy.swift:121-123`), 합성 상태는 `.unavailable`을 내지 않는다 |
| 14 | 초과 방전 표시 | 어댑터 연결 + 잔량 > 제한 + 전류 ≤ −100 mA → 기존 `.discharging`/`.dischargingToTarget` | §2 실측 |
| 15 | 실패 | PowerUI 없음/셀렉터 누락 → 백엔드 선택에서 제외(오늘의 미지원 화면). 쓰기 오류 → `lastMaintenance.result = .failed` + `.applyFailed`/`.releaseFailed`. 읽기 오류 → `.hardwareReadbackFailed` | 결정 3-1-2의 전제 |

### 3-3. 기본 확정(그릴 Needs-you 라운드, 응답 없음 → 추천값)

| # | 결정 | 값 |
|---|---|---|
| N1 | 이번 라운드 범위 | 네이티브 제한 + Top Up만. CHIE 방전 복구는 다음 라운드 |
| N2 | 시스템 설정과 충돌 | Wattly가 켜져 있는 동안은 Wattly 값을 다음 요청(≤60초)에서 재무장 |
| N3 | Wattly 제한을 끌 때 | **Wattly가 건 제한만** 100으로 푼다(`nativeLimitOwned`). 아니면 손대지 않는다 |
| N4 | 목록 밖 값(단축어 "70%") | 요청값 이상인 최소 허용값으로 올려 적용하고(70 → 80) 적용값을 보고 |
| N5 | 빠진 설정 안내 | 설정에 안내 한 줄 추가, 30개 언어 번역 포함 |
| N6 | 도우미 상태 UI | 이번 라운드에서 손대지 않는다. 합성 상태가 `.unavailable`을 내지 않으므로 배터리 섹션의 설치 유도는 자연히 뜨지 않고, 팬 쪽은 그대로다 |

### 3-4. 외부 진입점(예약 충전 · 단축어)

설정 화면은 `hiddenFeatures(backend:)`로 표현 불가능한 옵션을 숨기지만, 예약 충전과 단축어는 그 게이트를 타지 않아 "성공했는데 아무 일도 안 일어나는" 자리가 남았다. 둘 다 백엔드를 직접 확인해 거절한다.

| 진입점 | 네이티브에서의 동작 |
|---|---|
| 예약 충전 `.pauseCharging` | `BatteryScheduleCoordinator`가 실행하지 않는다. 환경설정도 바꾸지 않고 `SkipReason.unsupportedOnNativeLimit`으로 이력에 남긴다. `ScheduleEditorSheet`은 이 동작을 선택지에서 뺀다(상위가 `Bool` 하나를 내려 준다) |
| 단축어 `applySailing` · `applyHeatProtection` | 저장 **전에** `refreshStatus`로 백엔드를 확인하고 `BatteryIntentError.hardwareUnsupported`를 던진다. 환경설정은 그대로 |
| 단축어 `applyLimit` · `applyTopUp` | 그대로 동작한다(§3-2 #0의 요청 계약 위) |

## 4. 구성

```
@AppStorage → BatteryControlBridge(불변) → BatteryControlClient.apply(불변)
    → 기본 requestHandler ─ BatteryControlBackendSelector.current
          ├─ .smc         → 기존 XPC → 루트 데몬
          └─ .nativeLimit → NativeChargeLimitService.shared.handle(_:)
                               ├─ NativeChargeLimitPlan.command(...)      순수
                               ├─ NativeChargeLimitDriving (PowerUI)      I/O
                               ├─ NativeLimitBatteryReader.read()         I/O
                               ├─ BatteryTopUpExpiry.decide(...)          기존 순수
                               └─ NativeChargeLimitStatus.make(...)       순수
    ← 인코딩된 BatteryControlServiceStatus → client.status → 화면·단축어·스케줄(불변)
```

| 파일 | 책임 |
|---|---|
| `FanControlShared/BatteryControlProtocol.swift` (수정) | `BatteryControlBackend` enum, `BatteryControlServiceStatus.controlBackend` |
| `Wattly/Control/NativeChargeLimitPlan.swift` (신규, 순수) | 네이티브 상태 타입, 스냅, 설정 → 명령 |
| `Wattly/Control/NativeChargeLimitStatus.swift` (신규, 순수) | 배터리 판독 타입, 상태 DTO 합성 |
| `Wattly/Control/NativeChargeLimitDriver.swift` (신규, I/O) | `NativeChargeLimitDriving` 프로토콜 + `PowerUIChargeLimitDriver` |
| `Wattly/Control/NativeChargeLimitService.swift` (신규) | 전역 actor: 요청 처리, 영속, Top Up 종료, 소유 플래그 |
| `Wattly/Control/NativeLimitBatteryReader.swift` (신규, I/O) | 잔량·어댑터·전류 판독 |
| `Wattly/Control/BatteryControlBackendSelector.swift` (신규) | 백엔드 선택 + 프로세스 캐시 |
| `Wattly/Control/BatteryControlClient.swift` (수정) | 기본 핸들러 라우팅, `updateUnavailable`이 `controlBackend` 보존 |
| `Wattly/Core/BatterySectionPresentation.swift` (수정) | `BatteryFeature`, `hiddenFeatures(backend:)`, 안내 문구 |
| `Wattly/Views/Settings/SettingsBatterySection.swift` (수정) | 세 행 게이팅 + 안내 한 줄 |
| `Wattly/Settings/Settings.swift` (수정) | `StorageKey` 3개 |
| `Wattly/App/WattlyApp.swift` (수정) | `-WattlyNativeLimitProbe` |

영속 키(`UserDefaults.standard`): `nativeLimitDesiredConfiguration`(JSON `Data`), `nativeLimitTopUpReachedFullAt`(`Double`), `nativeLimitOwned`(`Bool`), `nativeLimitSuspendedLimit`(`Int`, Top Up이 일시 해제하기 직전의 **남의 제한** 값 — 이 값이 있으면 Wattly가 꺼질 때 그 제한을 소유권 없이 다시 걸어 준다). 설정 초기화(`SettingsReset`)는 이 키를 건드리지 않는다 — 환경설정이 아니라 서비스 상태이고, 초기화가 `batteryLimitEnabled = false`를 쓰면 브리지가 disable을 밀어 서비스가 스스로 푼다.

## 5. 비범위

- CHIE 방전 계열 복구(캘리브레이션·수동/자동 방전·클램쉘): 루트 데몬의 `.unsupported` 게이트 변경이 필요한 독립 작업. 실기 가능성은 확인됨(어댑터 연결 + 제한 유지 중 `CHIE=08` → −0.5 A, 복원 5초 내 0 mA, 제한 항목 유지).
- 80% 미만 제한, 열 보호의 대체 구현.
- `IOPSCopyBatteryLevelLimits` readback — 진단 프로브에서만 읽는다.
- `.firmwareManaged` 감지 정리와 `BatteryControlKeys` 주석 갱신(다음 라운드에서 CHIE 게이트와 함께).
- 팬·도우미 상태 UI 변경.

## 6. 검증

- 순수 함수·서비스: Swift Testing, 가짜 드라이버·가짜 판독·가짜 시계·임시 `UserDefaults` 스위트.
- 기존 테스트 무수정 통과(테스트 호스트에서는 선택기가 항상 `.smc`).
- 실기(릴리스 전 체크리스트): `-WattlyNativeLimitProbe`, 80% 정지, 초과 drain, Top Up 왕복(취소·어댑터 분리·12 h는 시계 조작 없이 취소/분리만), 잠자기 10분, 재부팅, 시스템 설정에서 값 변경 후 60초 내 재무장, Wattly 토글 off → 시스템 설정에서 꺼짐 확인.
