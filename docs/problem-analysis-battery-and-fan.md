# Wattly 시스템 메트릭 분석: 문제 인식 및 문제 도출 보고서

## 📌 문서 개요
본 문서는 Wattly 앱 내 **배터리 효율(Battery Efficiency)** 수치의 실시간 변동 원인 및 macOS 시스템 설정과의 차이점 분석, **팬 속도(Fan Speed)** 측정 시 2,300 RPM 고정 현상 및 제로팬(0 RPM) 제약 문제 인식, 그리고 이를 해결하기 위한 기술적 문제 도출 및 우회 해결 방안(Hybrid Handoff Strategy)을 정리한 보고서입니다.

---

## 1. 배터리 효율 (Battery Efficiency) 변동 분석

### 1.1 문제 인식 (Problem Identification)
* **현상**: Wattly 앱의 배터리 탭에서 표시되는 "배터리 효율(%)" 수치가 소수점 단위로 지속적으로 상승/하강(예: 99.0% ↔ 99.3%)하는 현상이 발생함.
* **의문점**: macOS "시스템 설정 > 배터리 > 배터리 성능 상태"에서는 `100%`로 수치가 고정되어 표기되는데, 왜 앱과 시스템 설정 간 표기 차이가 발생하는가?

### 1.2 문제 도출 및 분석 (Problem Analysis)
1. **코드 상의 배터리 효율 계산 로직**
   - 계산 공식:
     $$\text{배터리 효율 (\%)} = \frac{\text{AppleRawMaxCapacity (현재 완충 실측 용량)}}{\text{DesignCapacity (설계 용량)}} \times 100$$
   - 데이터 소스: macOS IOKit `AppleSmartBattery` 서비스 레지스트리 키.

2. **수치 실시간 변동 원인**
   - `DesignCapacity`는 공장 출하 시 하드코딩된 고정 상수값(예: 6,249 mAh).
   - `AppleRawMaxCapacity`는 배터리 관리 시스템(BMS)이 **온도, 부하(Current Draw), 전압 강화(Voltage Sag), 충전 상태(SOC)에 따라 실시간으로 Dynamic Re-estimation(동적 추정)**하는 가변 수치임 (예: 6,188 mAh ↔ 6,206 mAh).

3. **macOS 시스템 설정과의 표기 차이 원인**
   - macOS 시스템 설정(`system_profiler`)은 사용자 혼란을 방지하기 위해 다음 4가지 소프트웨어 보정 알고리즘을 적용함:
     - **장기 이동 평균 (Long-term Moving Average/Smoothing)**: 실시간 노이즈 제거 및 수일~수주 단위 평균 산출.
     - **100% 상한 캡 (Upper Bound Cap)**: 실측 비율이 100%를 초과(예: 100.1%)하더라도 100%로 고정.
     - **단조 감소 (Monotonic Trend/Hysteresis)**: 온도가 올라가 실측 용량이 일시적으로 늘어나더라도 수치 반등 억제.
     - **정수 단위 단순화**: 소수점을 없애고 정수로 단조화함.

---

## 2. 팬 속도 (Fan Speed) 및 제로팬 (0 RPM) 제약 분석

### 2.1 문제 인식 (Problem Identification)
* **현상 1**: CPU 온도가 낮고 팬 커브 시작점 이하임에도 불구하고 앱에 팬 속도가 약 **2,300 RPM**으로 측정됨.
* **현상 2**: 실제로 사용자는 팬 소음을 전혀 느낄 수 없어 팬이 멈춰 있는 것(0 RPM)으로 오인함.
* **의문점**: 사용자 지정 커브 및 수동 제어 모드에서 0 RPM(완전 정지) 조율이 불가능한가?

### 2.2 문제 도출 및 분석 (Problem Analysis)
1. **실시간 SMC 하드웨어 측정값 검증**
   - `FNum` (팬 개수): 1개
   - `F0Ac` (실제 회전 속도): 2,315 RPM
   - `F0Tg` (목표 회전 속도): 2,317 RPM
   - `F0Mn` (하드웨어 최소 속도): **2,317 RPM**
   - `F0Mx` (하드웨어 최대 속도): 6,550 RPM

2. **2,300 RPM 측정 및 무소음의 원인**
   - Apple Silicon 맥북 프로 팬에는 하드웨어 차원의 최저 가동 속도(`F0Mn` = 2,317 RPM)가 설정되어 있음.
   - 애플의 비대칭 날개(Asymmetric Blade) 디자인으로 인해 2,300 RPM 구간은 인간의 청력 감도 이하(Inaudible, <15 dBA)로 유지되므로 체감상 0 RPM처럼 느껴짐.

3. **제로팬(0 RPM) 모드의 동작 조건 한계**
   - **macOS 순정 자동 모드 (`Automatic Mode`)**: 온도가 낮을 때 시스템 데몬(`thermalmonitord`)이 팬을 완전히 **0 RPM**으로 끌 수 있음.
   - **서드파티 수동/커브 제어 모드 (`Controlled/Manual Mode`)**: 앱이 SMC 수동 제어권(`F0Mode = 1`)을 갖는 순간, SMC 펌웨어 락에 의해 `F0Mn`(2,317 RPM) 이하의 속도 제어 명령이 강제로 거부되고 클램핑됨.

---

## 3. 0 RPM 구현을 위한 꼼수 아이디어 및 우회 해결 방안

### 3.1 기술적 문제 요약 (Core Technical Challenge)
> "서드파티 앱이 SMC 수동 제어권을 잡고 있을 때는 SMC 펌웨어 락으로 인해 0 RPM 설정이 불가능함."

### 3.2 우회 해결 방안 (Proposed Workaround Strategies)

#### 🔥 [제안 1] 하이브리드 모드 전환 (Hybrid Auto/Manual Handoff) — *추천 솔루션*
* **원리**:
  - 사용자 커브 상 0 RPM 구간 (예: CPU 온도 < 55°C): SMC 수동 제어를 해제하고 **macOS 순정 자동 모드(`Automatic Mode`)로 즉시 스위칭**. macOS가 온도가 낮음을 인식하여 **0 RPM으로 완전 정지**.
  - 쿨링 필요 구간 (예: CPU 온도 $\ge$ 55°C): 다시 **수동 제어 모드(`Manual Mode`)로 낚아채서** 사용자 팬 커브대로 고속 쿨링 수행.
* **헌팅 방지**:
  - 55°C 경계선에서 0 RPM과 2,300 RPM 사이의 잦은 스위칭을 막기 위한 **히스테리시스(Hysteresis, 예: 55°C ON / 48°C OFF)** 적용.

#### 💡 [제안 2] 저전력 모드 동적 연동 (Dynamic Low-Power Mode Throttling)
* 0 RPM 구간 진입 시 macOS 저전력 모드를 동적으로 켜서 발열 원천 차단 $\rightarrow$ macOS 자동 제어가 0 RPM 상태를 최대한 오래 유지하도록 유도.

#### 💡 [제안 3] 예측형 조기 해제 (Predictive Thermal Inertia)
* 온도가 하강 추세일 때 (dT/dt < 0) 목표 온도 이전(예: 53°C)에 선제적으로 자동 모드로 전환하여 빠른 0 RPM 진입 유도.

---

## 4. 결론 및 향후 개발 반영 방향

1. **배터리 효율 UI**: 실시간 생(Raw) 수치(예: 99.3%)를 보여주는 현재 방식을 유지하되, 필요 시 Tooltip 안내문으로 "BMS 동적 추정치"임을 명시.
2. **팬 제어 로직 개선**: 커브 설정 UI에 "제로팬(0 RPM) 허용" 옵션을 추가하고, 0 RPM 구간에서는 **`Hybrid Auto Handoff`** 로직을 적용하여 실제 0 RPM 진입이 가능하도록 엔진 확장.
