# 06 — 전력 · IOReport (SoC)

> 막힘: 01,02,03 · 커버: 스토리 3,5,16,23 · 결정표 매핑: #12, **보류 #26, #27**
> 프로토타입 근거: SoC 전력 카드 line 84–95, sub line 588, unavailable line 90–95/744

## 목표

SoC 엔진별 전력(W)을 보여준다. 배터리·AC 무관하게 동작하므로 데스크톱 Mac에서도 유효하다.

## 범위 (In)

1. **PowerProvider (IOReport, 무권한)**
   - `dlopen("libIOReport.dylib")` (leaf 이름 — `IOReport.framework/...` 경로는 디스크에 부재, dyld 공유 캐시의 leaf만 열림).
   - "Energy Model" 그룹 구독 → 에너지(mJ)/dt → W (CPU/GPU/ANE/package).
   - 심볼/그룹이 nil이면 `unavailable`로 graceful degrade(크래시 금지).
2. **표시**
   - 카드 값 = package(또는 합산) W(소수 1자리), 값 색 = accent.
   - sub = "CPU x.x W · GPU y.y W · ANE z.z W"(엔진별 분해).
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

- **보류 #26**: macOS 14→26에서 채널 구조가 메이저별로 달라 같은 코드가 다른 채널을 디코드할 수 있음 → 런타임 탐색 + 버전 매핑 + graceful degrade로 완화.
- **보류 #27**: IOReport는 비공개 API. 비-MAS 직접 배포 전제로 위험 수용. notarization 로그에서 비공개 API 플래그 모니터([17](17-packaging-notarization.md)).
