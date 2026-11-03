# 한 번만 완충이 충전 제한을 강제로 켜지 않게 하기

## 의도

Wattly 충전 제한을 꺼 둔 사용자(기본값 `batteryLimitEnabled = false`, `Wattly/Settings/Settings.swift:433`)가 "한 번만 완충"(Top Up)을 쓰면, `BatteryControlClient.startTopUp(preferences:)`/`cancelTopUp(preferences:)`가 `config.enabled = true`를 강제하고(`Wattly/Control/BatteryControlClient.swift:316`, `:324`), 60초 `reconcile`도 Top Up 중에는 `effectiveEnabled`로 같은 강제를 되풀이한다(`:450`). 그 결과:

- **시스템 설정에서 직접 건 제한이 사라진다.** macOS 27 네이티브 백엔드에서 Top Up이 끝나면(취소·만료·어댑터 분리) 서비스가 Wattly 값으로 `setLimit`하며 소유권을 가져가고, 다음 reconcile이 Wattly 제한이 꺼져 있다며 그것을 해제한다. 실측 재현: `tempDisable` → `set:80`(owned) → `set:100`(off). 사용자의 90%는 남지 않는다.
- **최대 60초 동안 원치 않는 제한이 걸린다.** 시스템 제한이 없어도 Top Up이 끝나면 Wattly가 80%를 걸었다가 풀고, 도우미 경로에서는 그동안 히스테리시스 억제와(설정이 켜져 있으면) 자동 방전이 돈다.

**완료 기준:** Top Up이 어떻게 끝나든 충전 제한이 Top Up 이전의 소유 상태·값으로 돌아간다. 이 시나리오의 회귀 테스트가 있고 전체 테스트가 green이다.

분류: **bounded** — 기존 Top Up 흐름의 `enabled` 처리만 바꾼다. 두 백엔드 모두 Top Up을 `enabled`보다 먼저 판정하므로(`Wattly/Control/NativeChargeLimitPlan.swift:63`, `FanControlShared/BatteryControlEngine.swift:360`) 강제는 애초에 필요 없다.

## 완료 후 동작

- Wattly 꺼짐 + 시스템 설정 90%: Top Up이 일시 해제하고, 끝나면(취소·만료·분리) 90%를 되돌린다. Wattly는 소유권을 가져가지 않는다.
- Wattly 꺼짐 + 시스템 제한 없음: Top Up 종료 시 제한 쓰기가 0회. 도우미 경로에서는 종료 즉시 억제가 풀린다.
- Wattly 꺼짐 + macOS 자체 "이번만 완충" 상태: Wattly가 손대지 않는다.
- Wattly 충전 제한 켜짐: 지금과 동일.
- 업데이트 직전에 시작된 Top Up(`enabled=true`로 저장됨): 첫 reconcile(60초 이내)에서 `enabled=false, topUpActive=true`로 한 번 고쳐 쓰고 Top Up은 유지된다.

## 이번 라운드에서 제외

- 수동 방전의 `effectiveEnabled` 강제 — 같은 모양이지만 이번 버그와 별개다.
- 캘리브레이션의 `enabled` 강제(`BatteryControlClient.swift:177`, `:209`) — 절차 설계의 의도다.
- 매개변수 버전 `startTopUp(limitPercentage:…)`/`cancelTopUp(…)`(프로덕션 호출부 없음, 여전히 `enabled: true` 강제) — 결정 #8로 이번엔 그대로 둔다.

## 구현 명세

1. `Wattly/Control/BatteryControlClient.swift`
   - `startTopUp(preferences:)`, `cancelTopUp(preferences:)`에서 `config.enabled = true`를 삭제한다. `p.configuration(...)`이 `limitEnabled`를 싣는다.
   - `reconcile`의 `effectiveEnabled`에서 `isTopUp`을 뺀다. 바로 아래 분기 조건 `if enabled || heatProtectionEnabled || isTopUp || isManualDischarge || isCalibrating`에는 `isTopUp`을 **남긴다** — 빼면 Top Up 중 `disableAndConfirm`(`topUpActive: false`를 보냄)으로 빠져 Top Up이 취소된다.
2. `Wattly/Views/BatteryControlBridge.swift:118-130` `preservingActivity` 주석: "Top Up 중 enabled가 한 틱 어긋난다"는 서술을 수동 방전에만 해당하도록 고친다. 코드 변경 없음.
3. 네이티브 서비스·플랜, 도우미 엔진·코디네이터는 변경하지 않는다. 지금은 도달 불가인 `NativeLimitCommand.restoreForeign` 경로가 살아난다.

## 결정

### 확신
| # | 결정 | 답 | 근거 |
|---|---|---|---|
| 1 | 고칠 자리 | 클라이언트 진입점. 엔진·플랜 불변 | 두 백엔드가 Top Up을 `enabled`보다 먼저 판정 (`NativeChargeLimitPlan.swift:63`, `BatteryControlEngine.swift:360`) |
| 2 | Top Up이 싣는 `enabled` | 저장된 `limitEnabled` | `BatteryPreferences.configuration`이 이미 그렇게 조립 (`BatteryPreferences.swift:86`) |
| 3 | `reconcile` | `effectiveEnabled`에서만 `isTopUp` 제거, 분기 조건은 유지 | 분기에서도 빼면 `disableAndConfirm`이 Top Up을 취소 (`BatteryControlClient.swift:381`) |
| 4 | 업데이트 마이그레이션 | 별도 없음 | `shouldReapply`가 Top Up을 보존한 채 `enabled` 차이를 고쳐 씀 (`BatteryControlPolicy.swift:64-79`) |
| 5 | 캘리브레이션·수동 방전 | 불변 | 별개 계약 |
| 6 | 단축어·예약 | 코드 변경 없이 함께 고쳐짐 | 둘 다 `preferences:` 버전을 부르고 `enabled`를 보지 않음 (`BatteryIntentBridge.swift:105`, `BatteryScheduleCoordinator.swift:225`) |

### 확정됨(기본값)
| # | 결정 | 값 |
|---|---|---|
| 7 | Wattly 제한 꺼짐일 때 Top Up 버튼 | 지금처럼 보이고 동작 **[confirmed by default]** |
| 8 | 매개변수 버전 Top Up 함수 | 이번엔 그대로 둠 **[confirmed by default]** |
| 9 | 병합 전 검증 | 유닛 테스트 + 이 Mac에서 시스템 설정 90% 실기 1회 **[confirmed by default]** |
