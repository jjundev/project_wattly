# 17 — 패키징 · 공증 · 배포

> 막힘: 01–16 · 커버: 스토리 22 · 결정표 매핑: #18, **보류 #25, #27**
> 근거: PRD 빌드·배포 절

## 목표

Gatekeeper 경고 없이 실행되는 공증 앱을 만든다. 무권한·Agent 형태 유지.

## 범위 (In)

1. **번들 형태** — Xcode `.app`, `LSUIElement=YES`(Dock 없음), 배포 타깃 macOS 14.0. 앱 아이콘(Agent도 notarization·About·Finder에 필요).
2. **App Sandbox OFF** — 비-MAS. IOReport·SMC/HID private interface는 샌드박스/MAS에서 차단·불안정.
3. **Hardened Runtime ON(공유 빌드)**
   - **1차로 entitlement 없이 notarize 시도**(Apple 서명 IOReport는 보통 library validation 통과).
   - 실패 시에만 `com.apple.security.cs.disable-library-validation` 추가(선제 추가 금지).
   - notarization 로그에서 비공개 API 플래그 모니터([06](06-power-ioreport-soc.md),[08](08-temperature-cpu-gpu-battery.md)).
4. **서명/배포 (보류 #25)**
   - 개인용 = development / ad-hoc 서명.
   - 공유 = Developer ID + `notarytool` 공증 + DMG. (Apple Developer 계정 필요 — 비즈니스 결정.)
5. **로그인 항목** — `SMAppService.mainApp`([13](13-settings-window-login-item.md))이 번들 서명과 정합.

## 범위 (Out)

- Mac App Store 배포(비공개 IOReport 의존으로 불가). Intel Mac(Apple Silicon 전제).

## 수용 기준

- 클린 머신에서 Gatekeeper 경고 없이 실행(공유 빌드).
- Dock 아이콘 없이 메뉴바에만 상주, 로그인 시 자동 실행 동작.
- notarization 통과, 로그에 차단성 비공개 API 플래그 없음(또는 문서화된 entitlement로 해결).

## 메모

- **보류 #27**: 비공개 API(IOReport+SMC/HID) 위험은 비-MAS 직접 배포 전제로 수용. OS 메이저 업데이트마다 채널·profile 재검증.
- #12(기존 issues)와 달리 이 계획은 온도([08](08-temperature-cpu-gpu-battery.md)) 완료도 패키징 의존에 포함.
