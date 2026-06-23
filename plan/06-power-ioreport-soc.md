# 06 — 전력 · IOReport (SoC)

> 막힘: 01,02,03 · 커버: 스토리 3,5,16,23 · 결정표 매핑: #12, **보류 #26, #27**
> 프로토타입 근거: SoC 전력 카드 line 84–95, sub line 588, unavailable line 90–95/744

## 목표

SoC 엔진별 전력(W)을 보여준다. 배터리·AC 무관하게 동작하므로 데스크톱 Mac에서도 유효하다.

## 범위 (In)

1. **PowerProvider (IOReport, 무권한)**
   - `dlopen("libIOReport.dylib")` (leaf 이름 — `IOReport.framework/...` 경로는 디스크에 부재, dyld 공유 캐시의 leaf만 열림).
   - "Energy Model" 그룹 구독 → 채널별 단위를 J로 정규화하고 에너지 delta/dt → W.
   - CPU는 정확한 개별 코어 채널 합(`ECPU#`/`PCPU#`, 세대별 `MCPU`/`PACC` 계열)을 사용한다. `_SRAM`·`*DTL*`·클러스터 롤업은 제외한다.
   - 인식한 per-core 채널이 0개인 칩에서만 `CPU Energy` 롤업으로 폴백한다.
   - GPU 별칭은 `GPU Energy` 우선으로 하나만 사용하고, ANE를 더해 Combined Power를 만든다.
   - 심볼/그룹이 nil이면 `unavailable`로 graceful degrade(크래시 금지).
2. **표시**
   - 카드 값 = Combined Power(개별 CPU 코어 합+GPU+ANE) W(소수 1자리), 값 색 = accent.
   - sub = "CPU x.x W · GPU y.y W · NPU z.z W"(엔진별 분해).
   - **미가용 카드**: 주황 경고(bg `rgba(255,146,0,.07)`, border `rgba(255,146,0,.22)`, 삼각형 `#d47800`), 사유 "Energy Model 그룹을 읽을 수 없음 — 이 macOS에서 채널이 바뀌었을 수 있습니다."
3. **데스크톱 1급 지원** — 배터리 없어도 IOReport 기반 전력은 표시(스토리 23).
4. **두 전력 수치 관계** — IOReport = SoC 엔진별, AppleSmartBattery = 전체 시스템 순 방전. **다른 것을 측정**하므로 fallback이 아니라 별도 라벨 카드로 병행([07](07-power-battery.md)).
5. **자체 소비 입력** — 이 경로로 앱 자신의 전력도 측정([16](16-self-power-guard.md), 설정 푸터).

## 범위 (Out)

- powermetrics 기반 정밀 전력(root 필요, Out of Scope). 배터리 방전 W([07](07-power-battery.md)).

## 수용 기준

- 노트북·데스크톱 양쪽에서 W 와 엔진 분해 sub 표시.
- IOReport 심볼/그룹 nil 시 주황 미가용 카드, 나머지 지표 정상(부분 실패 격리).
- 무권한 접근 검증(Energy Model 그룹 dict non-NULL).

## 메모

- **2026-06-23 실기 게이트(Mac17,2/macOS 26.5.1):** 생 `sudo powermetrics` 30샘플의 유휴 중앙값 CPU 2.560 W, 유휴 부분집합 평균 2.550 W. IOReport 분해의 개별 코어 합 2.509 W와 일치하고 `CPU Energy` 롤업 약 3.4 W와는 불일치하여 per-core 경로를 채택했다.
- per-core 적용 후 같은 구간에서 기존 롤업 합계 3.309 W → 새 합계 2.664 W로 19.5% 감소했다. 같은 시점 Mx GUI는 0.880 W여서, Mx 화면은 깊은 idle에서 생 powermetrics와 동일한 수치 래퍼가 아니다. 정확도 앵커는 계획대로 Mx GUI가 아니라 생 powermetrics다.
- 수동 차등 검증은 `scripts/power-differential.sh`로 수행한다. `powermetrics` 때문에 sudo가 필요하며 무인 CI 대상이 아니다. 원시 IOReport의 rollup/per-core/cluster와 powermetrics를 같은 구간에서 기록한다.
- 엔진 채널의 단위 라벨이 nil/미상이면 mJ로 추정하지 않고 해당 interval을 드롭한 뒤 리베이스라인한다.
- IOReport 샘플 시각은 monitor 폴 시작 시각이 아니라 provider 내부의 호출 전후 중간 시각을 사용한다.
- 비현실 값 ceiling은 200 W이며 초과 interval은 리베이스라인한다.

- **보류 #26**: macOS 14→26에서 채널 구조가 메이저별로 달라 같은 코드가 다른 채널을 디코드할 수 있음 → 런타임 탐색 + 버전 매핑 + graceful degrade로 완화.
- **보류 #27**: IOReport는 비공개 API. 비-MAS 직접 배포 전제로 위험 수용. notarization 로그에서 비공개 API 플래그 모니터([17](17-packaging-notarization.md)).
