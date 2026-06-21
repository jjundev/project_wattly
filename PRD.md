# PRD — Wattly: macOS 메뉴바 시스템 모니터

> 상태: ready-for-agent (트래커 미구성으로 파일 발행 · CPU/GPU 온도 #13 반영)
> 타깃 환경: macOS 14.0+ / Apple Silicon · 개발기 macOS 26.5.1, Apple M5, Swift 6.3.2, Xcode 26.5
> 근거: grill-yourself v2.1 최종 결정 + grill-review(deep) 반영 + Metal 제외(#26r=pure-swiftui) + CPU/GPU 온도 grill-review/re-grill

---

## Problem Statement

맥북 사용자는 지금 이 순간 내 머신이 **전력을 얼마나 쓰는지, CPU·메모리가 얼마나 점유됐는지, CPU·GPU가 얼마나 뜨거운지**를 빠르게 확인하고 싶다. 그러나 macOS 기본 Activity Monitor는 별도 앱을 띄워야 하고, 전력(와트)과 CPU/GPU 온도를 한 화면에서 직관적인 숫자로 항상 보여주지 않는다. 사용자는 작업 흐름을 끊지 않고 **메뉴바에서 한눈에** 상태를 보고, 클릭하면 더 자세한 수치를 펼쳐 보고 싶다. 동시에, 이 모니터링 앱 자체가 배터리를 갉아먹어서는 안 된다(전력 도구가 전력을 많이 쓰면 모순).

## Solution

메뉴바에 상주하는 경량 Agent 앱(Dock 아이콘 없음)을 제공한다. 메뉴바에는 아이콘(옵션으로 CPU% 텍스트)이 보이고, 클릭하면 팝오버 패널이 펼쳐지며 **현재 전력 소모량(W), CPU 사용률, 메모리 점유율, CPU·GPU 최고 온도(°C)**와 최근 60초 추이 sparkline을 보여준다. 앱은 관리자 권한이나 helper 없이 사용자 공간 API만 사용하고, 유휴 시 폴링 빈도를 낮추는 적응형 동작으로 자기 전력 소비를 최소화한다. Metal 같은 GPU 가속은 쓰지 않는다 — 이 워크로드에선 SwiftUI/Swift Charts(내부적으로 이미 Metal 합성)가 더 저전력이다.

---

## User Stories

1. As a 맥북 사용자, I want 메뉴바에 항상 떠 있는 모니터 아이콘을 보고 싶다, so that 별도 앱을 열지 않고도 시스템 상태에 접근할 수 있다.
2. As a 사용자, I want 메뉴바 아이콘을 클릭하면 상세 패널이 펼쳐지길 원한다, so that 현재 전력·CPU·메모리·온도를 한 화면에서 본다.
3. As a 사용자, I want 현재 전력 소모량을 와트(W)로 보고 싶다, so that 지금 무엇이 배터리를 쓰는지 체감한다.
4. As a 노트북 사용자, I want 배터리 방전 전력(전체 시스템 W)을 보고 싶다, so that 실제 배터리 소모 속도를 안다.
5. As a 사용자, I want CPU/GPU/ANE 등 SoC 엔진별 전력(가능할 때)을 보고 싶다, so that 어떤 구성 요소가 전력을 쓰는지 구분한다.
6. As a 사용자, I want 전체 CPU 사용률을 퍼센트로 보고 싶다, so that 부하 수준을 즉시 파악한다.
7. As a 파워 유저, I want 코어별·성능 레벨별(Super/Performance/Efficiency 등 런타임 제공 명칭) CPU 사용률을 보고 싶다, so that 워크로드 분산을 이해한다.
8. As a 사용자, I want 메모리 사용량(used/wired/compressed)과 메모리 압력을 보고 싶다, so that 메모리 부족 여부를 안다.
9. As a 사용자, I want 각 지표의 최근 60초 추이를 미니 그래프(sparkline)로 보고 싶다, so that 순간값뿐 아니라 흐름을 본다.
10. As a 사용자, I want 메뉴바에 CPU%를 텍스트로 표시하는 옵션을 켜고 끄고 싶다, so that 패널을 열지 않고도 핵심 수치를 본다.
11. As a 저전력을 중시하는 사용자, I want 패널이 닫혀 있을 때 앱이 폴링 빈도를 낮추길 원한다, so that 모니터가 배터리를 거의 쓰지 않는다.
12. As a 사용자, I want 폴링 주기를 설정에서 조절하고 싶다, so that 정확도와 전력 사이에서 내 취향대로 맞춘다.
13. As a 사용자, I want 표시할 지표(전력/CPU/메모리/CPU 온도/GPU 온도)를 토글하고 싶다, so that 관심 있는 것만 본다.
14. As a 사용자, I want 로그인 시 자동 실행을 켜고 끄고 싶다, so that 매번 수동으로 켜지 않아도 된다.
15. As a 첫 실행 사용자, I want 첫 샘플이 도착하기 전(콜드 스타트)에도 깨지지 않는 플레이스홀더("—")를 보고 싶다, so that 빈 화면이나 0값 오해가 없다.
16. As a 사용자, I want 특정 지표를 못 읽을 때(예: 데스크톱 Mac이라 배터리 없음, IOReport 미지원, 검증된 온도 profile 없음) 그 카드에 사유가 표시되길 원한다, so that 앱이 고장 난 게 아님을 안다.
17. As a 사용자, I want 한 지표가 실패해도 나머지 지표는 계속 동작하길 원한다, so that 부분 실패가 전체를 마비시키지 않는다.
18. As a VoiceOver 사용자, I want 메뉴바 라벨과 각 수치에 접근성 라벨이 있길 원한다, so that 화면 낭독으로도 값을 듣는다.
19. As a 사용자, I want 패널을 닫으면 그래프·렌더가 멈추길 원한다, so that 보이지 않는 동안 자원을 쓰지 않는다.
20. As a 개발자, I want 앱이 자기 전력 소비를 스스로 측정해 회귀를 감시하길 원한다, so that 업데이트가 모니터를 전력 먹는 앱으로 만들지 않는다.
21. As a 사용자, I want 앱이 Dock에 아이콘을 띄우지 않길 원한다, so that 메뉴바 전용 유틸로 깔끔하게 동작한다.
22. As a 공유받는 사용자, I want 공증(notarized)된 앱을 받길 원한다, so that Gatekeeper 경고 없이 실행한다.
23. As a 데스크톱 Mac 사용자, I want 배터리가 없어도 IOReport 기반 전력 수치를 보고 싶다, so that 노트북이 아니어도 앱이 의미 있게 동작한다.
24. As a 사용자, I want 앱이 시스템 전반의 무권한 API만 쓰길 원한다, so that 관리자 비밀번호나 권한 헬퍼 없이 바로 쓴다.
25. As a 사용자, I want CPU에서 검증된 센서 중 가장 높은 온도를 보고 싶다, so that 현재 CPU hotspot을 즉시 파악한다.
26. As a 사용자, I want GPU에서 검증된 센서 중 가장 높은 온도를 보고 싶다, so that 그래픽 부하의 열 상태를 즉시 파악한다.

---

## Implementation Decisions

### 플랫폼 · 셸
- **언어/툴체인:** Swift 6 (strict concurrency), Xcode App 프로젝트(`.xcodeproj`). SPM executable 아님 — `.app` 번들·Info.plist·서명·로그인 항목이 번들을 요구.
- **배포 타깃:** macOS 14.0 (`@Observable` 매크로 사용을 위한 하한). 검증: SDK `Observation.swiftinterface`에 `Observable()` 매크로가 `@available(macOS 14.0)`.
- **UI 프레임워크:** SwiftUI `MenuBarExtra` + `.menuBarExtraStyle(.window)` — "메뉴바 상주 + 클릭 시 패널" 모델에 정확히 대응. 검증: `MenuBarExtra` `@available(macOS 13.0)`, `.window` 스타일 SDK에 존재.
- **앱 형태:** Agent 앱 — Info.plist `LSUIElement = YES` (Dock 아이콘 없음).
- **로그인 항목:** `SMAppService.mainApp` 토글. 검증: SDK 헤더 `SMAppService` `API_AVAILABLE(macos(13.0))`.
- **설정:** SwiftUI `Settings` scene + `@AppStorage`(폴링 주기, 표시 지표, CPU/GPU 온도 개별 on/off, 메뉴바 텍스트 on/off, 로그인 항목). 두 온도 카드가 모두 OFF면 온도 provider도 폴링하지 않는다.

### 데이터 소스 (전부 무권한)
- **CPU:** `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`로 코어별 tick 스냅샷, 직전 스냅샷과 차분 → 전체/코어별 사용률. 호출 후 `vm_deallocate`로 배열 해제. 토폴로지는 하드코딩하지 않고 `hw.perflevelN.name`/`physicalcpu`를 런타임 조회한다(개발기 M5 = 4 Super + 6 Efficiency).
- **메모리:** `host_statistics64`(HOST_VM_INFO64)로 active/wired/compressed 페이지 + `sysctl hw.memsize`(16 GB) → 사용량·메모리 압력.
- **전력 — 주 소스(IOReport):** `dlopen("libIOReport.dylib")` (leaf 이름 — 번들 경로 `IOReport.framework/...`는 이 macOS 디스크에 부재, dyld 공유 캐시의 leaf만 열림). "Energy Model" 그룹 구독 → 에너지(mJ)/dt → W (CPU/GPU/ANE/package). **배터리·AC와 무관하게 동작하므로 데스크톱 Mac에서도 유효.** 무권한 접근 검증됨(Energy Model 그룹 dict non-NULL). 심볼/그룹이 nil이면 `unavailable`로 graceful degrade.
- **전력 — 보조 소스(노트북 한정):** `IOServiceGetMatchingService("AppleSmartBattery")` → `Voltage`(mV) × `InstantAmperage`(mA) → 전체 시스템 방전 W. `InstantAmperage`는 **Int64 2의 보수**로 디코딩(큰 unsigned 값이면 `v - 2^64`). 라이브 검증: −938 mA × 12.027 V = 11.28 W, −1175 mA × 11.992 V = 14.09 W (정상 노트북 방전값). 배터리 없으면 카드 숨김.
- **두 전력 수치의 관계:** IOReport = SoC 엔진별 전력, AppleSmartBattery = 전체 시스템 순(net) 방전. 서로 **다른 것을 측정**하므로 fallback이 아니라 **별도 라벨 카드**로 병행 표기("SoC 전력" vs "배터리 방전"). 사용자에게 둘이 다른 이유를 UI에서 명시.
- **CPU/GPU 온도 — source resolution:** 전역 1차 소스를 미리 확정하지 않는다. 읽기 전용 AppleSMC/IOKit과 IOHID vendor temperature event를 후보로 두고, M5 실기 spike에서 service/key identity·data type·값을 검증한 source만 사용한다. `powermetrics`, shell parsing, root helper는 런타임 경로에서 제외한다.
- **온도 profile:** `TemperatureProfile`은 chip family·variant·OS 범위·source·sensor identity·data type·CPU/GPU category·집계법·정상 범위·검증 근거·상태(`verified`/`experimental`/`unsupported`)를 기록한다. 이름이 불명확한 key나 unknown `T*` key는 자동 분류하지 않는다.
- **온도 값:** 각 category의 verified sensor 중 최댓값을 각각 "CPU 최고 온도", "GPU 최고 온도"로 표시한다. v1 정식 실기 범위는 Apple M5이며, M1~M4는 동일 검증 절차를 통과한 profile이 생긴 뒤 순차 지원한다. verified profile이 없거나 유효 reading이 없으면 해당 카드만 `unavailable`이다.
- **M5 온도 검증 gate:** 독립 모니터와 idle/CPU/GPU 구간 동시 sample 10개를 비교해 중앙 절대 오차 ≤5°C, CPU/GPU 5분 부하 각 3회 중 대상 category가 ≥5°C 상승하는 run 2회 이상을 만족해야 `verified`로 승격한다. raw key, chip variant, OS build, 비교 도구와 결과를 profile 근거로 남긴다.

### 동시성 경계 (단일 seam)
- **`MetricSample`** — `Sendable` 값 타입. 액터 경계를 넘는 **유일한** 타입. 원시 C 포인터(`processor_info_array_t`, `vm_statistics64` 등 비-`Sendable`)는 프로바이더 내부에서 즉시 소비·해제하고 모델엔 `MetricSample`만 전달.
- **`MetricProvider`** 프로토콜 — `nonisolated`(또는 전용 actor)에서 동기 C API 호출, `MetricSample` 반환. 구현체: `CPUProvider`, `MemoryProvider`, `PowerProvider`(IOReport), `BatteryProvider`, `TemperatureProvider`.
- **온도 부분 실패 경계:** `MetricSample.temperature(TemperatureSnapshot)` 안에 CPU/GPU별 `value(TemperatureReading)` 또는 `unavailable(TemperatureError)`를 담는다. 원시 SMC/HID handle과 CF 객체는 provider 안에 남고 `TemperatureSnapshot`만 Sendable 값으로 이동한다.
- **`SystemMonitor`** — `@MainActor @Observable`. 적응형 주기로 프로바이더 폴링, 각 지표를 `MetricState`로 보유한다. history는 monotonic timestamp 기준 최근 60초를 유지하고 메모리 안전 상한 256개를 적용한다. SwiftUI 뷰는 이 모델만 관찰.

### 상태 모델
- **`MetricState`** = `loading` | `value(MetricSample)` | `unavailable(reason)`.
  - 콜드 스타트(첫 샘플 전) = `loading` → 메뉴바 아이콘만, 패널 카드엔 "—".
  - 샘플 실패 = 해당 지표만 `unavailable(reason)`, 나머지는 계속.
  - 전력 미가용(데스크톱 + IOReport nil, 또는 노트북 배터리 카드 부재 등)도 사유와 함께 표기.
  - CPU/GPU 온도는 한 snapshot 안에서도 독립 상태다. 한쪽 실패가 다른 온도 카드나 기존 지표에 전파되지 않는다.
- **온도 provider 연결 상태:** `disabled → disconnected → ready → backoff | terminal`. invalid connection은 즉시 1회 재연결하고, 다시 실패하면 1·2·4·8·16·30초 backoff한다. wake 또는 사용자 재활성화는 backoff를 초기화한다.
- **온도 오류 분류:** retryable = `connectionFailed`, 일시적 `readFailed`; terminal = `unsupportedChip`, `noVerifiedProfile`, `unsupportedDataType`, `invalidReadings`. retryable에만 "재시도 중"을 표시한다.

### 저전력 아키텍처 (Metal 미사용)
- **렌더:** 메뉴바 라벨·숫자 카드·sparkline = **SwiftUI / Swift Charts 전용**. 명시적 Metal API 미사용 — 이 워크로드에선 GPU 컨텍스트를 띄우는 비용이 순수 SwiftUI(이미 Core Animation→Metal로 합성)보다 전력을 더 씀.
- **적응형 폴링:** 패널 닫힘 = 5초(메뉴바 텍스트 OFF 시) / 2초(텍스트 ON 시), 패널 열림 = 1–2초. 설정에서 상한 조절.
- **타이머/스케줄:** `Timer`에 `tolerance` 부여(코얼레싱 허용), 폴링 Task QoS `.utility`.
- **렌더 정지:** 패널이 닫히면 그래프 갱신 정지(뷰 해제/구독 중단).
- **온도 폴링 생략:** CPU/GPU 온도 표시가 모두 OFF면 `TemperatureProvider` 호출과 sensor I/O를 생략한다.
- **메뉴바:** template 이미지 사용으로 합성 비용 최소화.
- **자기 측정(도그푸드):** 본 앱의 IOReport 경로로 자신의 전력을 측정, 회귀 감시 기준값으로 사용.

### 빌드 · 배포
- **App Sandbox:** OFF (비-MAS). IOReport와 온도용 SMC/HID private interface는 샌드박스/MAS에서 차단·불안정할 수 있다.
- **Hardened Runtime(공유 빌드):** ON. **1차로 entitlement 없이 notarize 시도**(Apple 서명 IOReport는 보통 library validation 통과). 실패 시 `com.apple.security.cs.disable-library-validation` 추가. notarization 로그에서 비공개 API 플래그 모니터.
- **서명/배포:** 개인용 = development/ad-hoc 서명. 공유 = Developer ID + `notarytool` 공증 + DMG.
- **자산:** 앱 아이콘(Agent 앱도 notarization·About·Finder에 필요), 메뉴바 라벨·수치에 VoiceOver 접근성 라벨.

### 모듈 요약
- `MetricSample`(값 타입), `MetricState`(enum), `MetricProvider`(프로토콜) — 경계.
- `CPUProvider` / `MemoryProvider` / `PowerProvider` / `BatteryProvider` / `TemperatureProvider` — 데이터 수집(경계 아래, 라이브 I/O).
- `TemperatureTransport` / `TemperatureProfile` / `TemperatureSnapshot` — 온도 source 격리, 검증 근거, CPU/GPU 부분 실패 경계.
- 순수 함수: `decodeAmperage(_:)`, `cpuUsage(prev:curr:)`, `usedBytes(_:)`, 온도 key-info decoder·profile별 filter·hottest 집계 — 파싱·델타·집계 수학.
- `SystemMonitor`(`@MainActor @Observable`) — 폴링·상태·추이.
- 뷰: `MenuBarLabel`, `DetailView`(카드 + Swift Charts), `SettingsView`.

---

## Testing Decisions

- **좋은 테스트의 기준:** 외부 동작만 검증한다. 라이브 하드웨어 상태에 의존하지 않고, 합성 입력 → 결정론적 출력을 확인한다. 구현 디테일(특정 Mach 호출 시퀀스)을 테스트하지 않는다.
- **단일 seam:** `MetricProvider` → `MetricSample` 경계. 가짜 프로바이더(미리 정한 `MetricSample` 시퀀스 반환)를 `SystemMonitor`에 주입해 폴링·상태 전이·timestamp 기반 60초 history·적응형 주기 로직을 하드웨어 없이 검증.
- **순수 함수 단위 테스트(고가치):**
  - `decodeAmperage` — 2의 보수 디코딩(예: `18446744073709550678` → −938 mA), 양수/음수/0 경계.
  - `cpuUsage(prev:curr:)` — tick 차분, idle 비율, 코어별 합산, 0-델타(동일 스냅샷) 처리.
  - `usedBytes` — VM 페이지 → 바이트 환산, wired/compressed 합산.
  - 온도 — key-info/FourCC와 실측 data type decode, chip·variant·OS별 profile 선택, profile별 값 filter, CPU/GPU hottest 집계.
- **온도 상태 전이 테스트:** CPU 성공+GPU 실패와 그 반대, retryable/terminal 오류, 즉시 1회 재연결, 1·2·4·8·16·30초 backoff, wake/enable reset, 두 토글 OFF 시 provider 미호출.
- **history 테스트:** polling 간격과 무관하게 60초 초과 sample이 제거되고 256개 안전 상한을 넘지 않는다.
- **상태 전이 테스트:** `loading` → `value`, 단일 지표 `unavailable` 시 나머지 유지(부분 실패 격리), 데스크톱(배터리 없음) 시나리오에서 전력 카드 표시 규칙.
- **온도 실기 acceptance:** M5에서 독립 oracle 오차 기준과 각 3회 CPU/GPU 부하 기준을 통과하고, sleep/wake 자동 복구·한쪽 sensor 부재·1시간 handle/메모리/wakeup 안정성을 확인한다.
- **Prior art:** greenfield라 기존 테스트 없음. Swift Testing(또는 XCTest) 기반 신규 테스트 스위트를 이 PRD에서 처음 수립.

---

## Out of Scope

- **추가 지표:** GPU 사용률, SoC·배터리·SSD·메모리 온도, fan RPM/제어, 온도 threshold 알림, 네트워크 처리량, 디스크 I/O, 프로세스별 Top(Activity Monitor류) — 후속. (provider 구조라 추가 저렴.)
- **Mac App Store 배포** — 비공개 IOReport 의존으로 불가; 비-MAS 직접 배포 전제.
- **powermetrics 기반 정밀 전력** — root 필요·권한 헬퍼(LaunchDaemon) 필요로 범위 밖.
- **Metal/GPU 가속 렌더** — 저전력 목표와 충돌하여 명시적으로 제외(#26r=pure-swiftui).
- **Activity Monitor급 풀 히스토리 차트** — 60초 슬라이딩 sparkline까지만.
- **Intel Mac 지원** — Apple Silicon(IOReport Energy Model) 전제. Intel은 검증 범위 밖.
- **M1~M4 CPU/GPU 온도 정식 지원** — v1은 M5 실기 검증 profile만 정식 지원한다. 각 세대·variant가 동일한 검증 gate를 통과하면 후속 지원한다.

---

## Further Notes

### 확정되지 않은 가정 (구현 전 사용자 확인 필요)
다음은 코드가 아니라 사용자의 제품·위험·비즈니스 판단으로만 결정 가능하다. 기본값을 PRD에 인코딩했으나 **미확정 가정**으로 남는다:

- **(#8r) 전력 측정 위험 수용:** IOReport는 비공개 API라 macOS 메이저 업데이트 시 채널/그룹 이름이 바뀌어 깨질 수 있다. 기본값 = **IOReport 채택(위험 수용)**, graceful degrade로 완화. 대안: 배터리-only(안정·노트북 한정) 또는 powermetrics root 헬퍼(정밀·복잡).
- **(#9) v1 메트릭 범위:** 기본값 = CPU·RAM·전력(+배터리%)·M5 CPU/GPU 최고 온도. 데스크톱 Mac을 1급 지원할지에 따라 전력 UX가 달라짐.
- **(#14/#15) 샌드박스·배포 채널:** 기본값 = 비-MAS, 개인용 ad-hoc / 공유 시 Developer ID 공증.
- **(#13-24/#13-27/#13-29) 온도 UX:** 기본값 = hottest 집계, °C 소수점 한 자리, CPU/GPU 카드 기본 ON 및 개별 토글. 메뉴바 텍스트에는 온도를 추가하지 않는다.
- **(#13-26) 온도 지원 범위:** 기본값 = v1 M5 정식 지원, M1~M4는 실기 검증 후 순차 지원.
- **(#13-30) 온도 private interface 위험 수용:** 기본값 = 비-MAS 직접 배포에서 SMC/HID 위험 수용. verified profile이 없으면 추측하지 않고 unavailable 처리.

### 리스크 메모
- **macOS 14→26 배포 폭:** IOReport 채널 구조가 OS 메이저마다 다를 수 있어, 동일 코드가 14와 26에서 다른 채널을 디코드할 수 있음. 버전별 매핑 또는 런타임 탐색 필요.
- **온도 source 안정성:** SMC key와 HID sensor identity는 chip variant·OS 업데이트별로 바뀔 수 있다. OS 업데이트마다 M5 profile을 재검증하고, 새 조합은 실기 gate 통과 전 `verified`로 승격하지 않는다.
- **첫 구현 착수 지점:** Phase 1(CPU/RAM)이 무권한·무위험·단독 출시 가능한 진짜 MVP. 전력(IOReport)의 비공개 API 리스크는 그 위에서 분리 검증.
- **온도 구현 착수 지점:** #1 metric spine 이후 #13 Phase 0 M5 source 검증을 먼저 수행한다. verified CPU/GPU source가 확인되기 전에는 UI 숫자를 확정하지 않는다.
