# 보안·구조 감사 수정 계획 — 인덱스

> **For agentic workers:** 이 문서는 인덱스다. 실제 실행은 아래 여섯 계획 파일을 **번호 순서대로** 하나씩 집행한다. 각 파일은 superpowers:subagent-driven-development 또는 superpowers:executing-plans로 실행한다.

**Goal:** 2026-09-08 코드베이스 감사(Critical 1 · High 5 · Medium 12)에서 나온 결함을 위험 감소량 대비 비용 순으로 여섯 단계에 걸쳐 제거한다.

**Spec:** 감사 보고서 — https://claude.ai/code/artifact/20a3c5b7-ad33-4ec3-ae78-288a0259454d (본문의 "5. 권장 수정 순서"가 이 인덱스의 순서다)

## 순서와 의존성

| # | 계획 파일 | 해소하는 감사 항목 | 선행 조건 |
|---|-----------|--------------------|-----------|
| 1 | `2026-09-08-01-update-verification.md` | Critical: 무결성 검증 없는 자동 업데이트 · Medium: `cancel()`이 교체를 못 막음 · `rm -rf` 후 `ditto` | 없음 |
| 2 | `2026-09-08-02-helper-install-hardening.md` | High: 사용자 쓰기 경로에서 root 실행/설치(TOCTOU) · Medium: 작은따옴표 인젝션 · Low: 정책 디렉터리 lazy 생성 | 없음 |
| 3 | `2026-09-08-03-battery-preferences-single-writer.md` | High: 이중 쓰기 경합 · High: 스케줄 알림 기본값 불일치 · Medium: Sailing 폭 1 전송 · Medium: wake 후 스케줄 2회 실행 · 구조 #1(설정 조립 36곳) · Pass-through(`BatteryIntentBridge`, 설정 뷰 `.onChange→apply`) | 없음 |
| 4 | `2026-09-08-04-ac-state-and-smc-core.md` | High: 프레임마다 IOPS 호출 · Medium: SMC `Int()` 트랩 · Medium: `keyInfo` 재조회 · 구조 #2(SMC 마샬링 복제) · Low: result byte 무시 | 없음 |
| 5 | `2026-09-08-05-daemon-defenses.md` | Medium: XPC 속도 제한/generation 잠금 · Medium: 배터리 정책 deadman 없음 · Low: 정책 디렉터리 소유자 검증 · Low: KeepAlive 크래시 루프 | 2단계(스크립트가 정책 디렉터리를 root로 만든다) |
| 6 | `2026-09-08-06-developer-id-signing.md` | High: XPC 인증이 basename 비교 · 2단계가 남긴 "설치 전 교체" 창 · README "서명됨" 불일치 · quarantine 제거 | 1·2단계 + 유료 Apple Developer 계정 |

1~5는 서로 파일이 겹치지 않으므로 병렬 워크트리로 진행해도 된다. 단, 3단계와 5단계는 둘 다 `BatteryControlClient`의 XPC 요청 흐름을 바꾸므로 같은 브랜치에서 순서대로 병합하고 그때마다 전체 테스트를 돌린다.

## 모든 계획의 공통 제약

- Swift 6 언어 모드(strict concurrency complete). `nonisolated(unsafe)`·`@unchecked Sendable` 추가는 기존 파일이 이미 쓰는 근거(액터 격리 안에서만 접근)와 같은 주석을 달 때만 허용.
- macOS 14.0 배포 타깃, arm64 전용.
- 테스트는 Swift Testing(`import Testing`, `@Suite`, `@Test`, `#expect`). XCTest 신규 사용 금지.
- 사용자에게 보이는 문자열은 한국어 원문을 `String(localized:)`/`Text("…")`로 쓴다. 새 문자열은 `Wattly/Resources/Localizable.xcstrings`에 키가 추가돼야 `LocalizationTests`가 통과한다(30개 로케일 전부). 번역이 아직 없으면 한국어 값을 30개 로케일에 복사해 넣고 TODO 대신 `scripts/generate_full_catalog.py`가 잡도록 둔다.
- 데몬 타깃(`WattlyFanDaemon`)은 테스트 호스트가 없다. 데몬에 넣을 로직은 `FanControlShared`의 순수 타입으로 먼저 만들고 그 테스트로 검증한 뒤 데몬은 배선만 한다.
- 커밋 메시지는 기존 컨벤션: `feat(scope):`, `fix(scope):`, `refactor(scope):`, `test(scope):`, `docs(scope):`.

## 테스트 실행 명령

전체:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -20
```

특정 스위트만(Swift Testing은 `WattlyTests/<Suite 타입 이름>` 형식):

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS,arch=arm64' test -only-testing:WattlyTests/UpdateVerifierTests 2>&1 | grep -E "Test .* (passed|failed)|error:|\*\* TEST" | tail -20
```

빌드만(데몬 포함):

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error:|warning: unused|\*\* BUILD" | tail -20
```

`project.yml`을 바꾼 계획(6단계)은 `xcodegen generate` 후에 빌드한다.
