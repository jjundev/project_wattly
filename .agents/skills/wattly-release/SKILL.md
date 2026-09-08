---
name: wattly-release
description: Use when the user wants to prepare, package, tag, or publish a new release of Wattly — e.g. "릴리즈 진행해줘", "v1.2.0 배포해줘", "버전 올려서 릴리즈하자", "새 버전 출시해줘", "/wattly-release", or "cut a new Wattly release". Guides version bumping, xcodegen, test verification, DMG/ZIP packaging, daemon integrity checks, bilingual release notes generation, and GitHub release publishing.
---

# Wattly Release Automation Skill (`wattly-release`)

## Overview

Project Wattly is a native macOS menu bar utility for battery charge limits, discharging, and fan control. Because it interacts directly with Apple Silicon SMC registers and battery management systems, releasing a new version requires strict verification:
1. Full preflight unit & integration test passing.
2. Ad-hoc signed distribution packaging (`Wattly.app`, DMG, and ZIP).
3. Verification of the embedded privileged helper daemon (`Contents/Helpers/WattlyFanDaemon`).
4. Bilingual release notes generation (Korean primary with collapsible English translation).
5. Explicit human-in-the-loop approval gate before modifying remote tags or publishing.
6. Safe multi-worktree git operations.

---

## Invocation Modes & Version Resolution

When triggered, determine the target marketing version (`X.Y.Z`) and build number (`N`):

### Mode A: Explicit Version Given
User specifies the version (e.g., `/wattly-release 1.2.0` or `"1.2.0으로 릴리즈해줘"`):
- `MARKETING_VERSION`: Target version string (e.g., `"1.2.0"`).
- `CURRENT_PROJECT_VERSION`: Read current build number from `project.yml:65` and increment by 1.

### Mode B: Implicit / Intelligent Recommendation
User initiates release without specifying version (e.g., `/wattly-release` or `"릴리즈 진행하자"`):
1. Find previous release tag:
   ```bash
   PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v1.0.0")
   ```
2. Inspect commits since previous tag:
   ```bash
   git log ${PREV_TAG}..HEAD --oneline
   ```
3. Recommend version bump:
   - If commits contain `feat:` or breaking changes (`!:`): Recommend **Minor bump** (e.g., `1.1.0` -> `1.2.0`).
   - If commits contain only `fix:`, `docs:`, `chore:`, or `perf:`: Recommend **Patch bump** (e.g., `1.1.0` -> `1.1.1`).
   - Increment `CURRENT_PROJECT_VERSION` by 1.
4. Prompt the user for one-line confirmation before making any changes:
   > "최근 커밋 분석 결과 **vX.Y.Z (build N)** 릴리즈를 제안합니다. 이 버전으로 진행할까요?"

---

## Execution Pipeline (Steps 1 to 7)

```
[Step 1: Preflight Audit]
        │
[Step 2: Version Bump & xcodegen]
        │
[Step 3: Packaging (DMG & ZIP)]
        │
[Step 4: Helper & Asset Verification]
        │
[Step 5: Bilingual Release Notes]
        │
[Step 6: Human Approval Gate (STOP)] ──(Revise)──> [Step 5]
        │ (Approved)
[Step 7: Tag, Push, Publish & Sync]
```

---

### Step 1: Preflight Audit

Verify repository cleanliness, required tools, and test suite health before touching any files.

1. **Verify working directory is clean**:
   ```bash
   git status --porcelain
   ```
   *Exit criterion: Output must be empty. If dirty, STOP immediately and ask user to stash or commit changes.*

2. **Verify required CLI tools**:
   ```bash
   xcodebuild -version
   /Users/hyunjun_macbook_pro/bin/xcodegen --version || xcodegen --version
   gh auth status
   ```
   *Exit criterion: All tools must exit with code 0 and gh must show logged in.*

3. **Run complete test suite**:
   ```bash
   xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
   ```
   *Exit criterion: `** TEST SUCCEEDED **`. Abort immediately if any test fails.*

---

### Step 2: Version Bump & Xcode Project Regeneration

1. **Update `project.yml`**:
   Modify `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` under `Wattly` target settings (lines 64-65 in `project.yml`):
   ```yaml
           MARKETING_VERSION: "X.Y.Z"
           CURRENT_PROJECT_VERSION: "N"
   ```

2. **Regenerate Xcode project**:
   ```bash
   /Users/hyunjun_macbook_pro/bin/xcodegen generate || xcodegen generate
   ```

3. **Verify build settings in regenerated project**:
   ```bash
   xcodebuild -project Wattly.xcodeproj -scheme Wattly -showBuildSettings | grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION"
   ```
   *Exit criterion: Values match target `X.Y.Z` and `N`.*

4. **Commit the bump**:
   ```bash
   git commit -am "chore(release): bump version to X.Y.Z (build N)"
   ```

---

### Step 3: Distribution Packaging

Generate both distribution assets (`.dmg` and `.zip`).

1. **Clean previous build artifacts**:
   ```bash
   rm -rf build/ .build/
   ```

2. **Build disk image (DMG)**:
   ```bash
   zsh scripts/make-dmg.sh
   ```
   *Produces `build/Wattly-X.Y.Z.dmg` with embedded helper and `/Applications` symlink.*

3. **Build release archive (ZIP)**:
   ```bash
   bash scripts/build_release.sh
   cp build/Release/Wattly.zip build/Wattly-X.Y.Z.zip
   ```
   *Produces `build/Wattly-X.Y.Z.zip`.*

---

### Step 4: Asset & Helper Daemon Integrity Check

`WattlyFanDaemon` must be embedded in `Wattly.app/Contents/Helpers/` with executable permissions for SMC control.

1. **Verify DMG and embedded daemon**:
   ```bash
   mkdir -p /tmp/wattly_mnt
   hdiutil attach build/Wattly-X.Y.Z.dmg -mountpoint /tmp/wattly_mnt -nobrowse -quiet
   test -x "/tmp/wattly_mnt/Wattly.app/Contents/Helpers/WattlyFanDaemon" && echo "Daemon OK in DMG"
   defaults read "/tmp/wattly_mnt/Wattly.app/Contents/Info.plist" CFBundleShortVersionString
   hdiutil detach /tmp/wattly_mnt -quiet
   rmdir /tmp/wattly_mnt
   ```
   *Exit criterion: Output shows `Daemon OK in DMG` and version matches `X.Y.Z`.*

2. **Verify ZIP and embedded daemon**:
   ```bash
   unzip -l build/Wattly-X.Y.Z.zip | grep "Contents/Helpers/WattlyFanDaemon"
   ```
   *Exit criterion: `WattlyFanDaemon` is listed in archive.*

3. **Verify asset sizes**:
   ```bash
   ls -lh build/Wattly-X.Y.Z.dmg build/Wattly-X.Y.Z.zip
   ```
   *Exit criterion: Both files must be between 5MB and 15MB. (A missing helper or bloated archive will fall outside this range).*

---

### Step 5: Bilingual Release Notes Synthesis

1. **Extract commit logs since previous release**:
   ```bash
   PREV_TAG=$(git describe --tags --abbrev=0 HEAD~1 2>/dev/null || echo "")
   if [ -n "$PREV_TAG" ]; then
     git log ${PREV_TAG}..HEAD --oneline
   else
     git log -n 15 --oneline
   fi
   ```

2. **Compose bilingual release notes and save to `/tmp/wattly_release_notes.md`**:
   Structure the notes according to this template:

   ```markdown
   ## Wattly vX.Y.Z 출시 안내

   Wattly vX.Y.Z 버전이 출시되었습니다. 이번 릴리즈에 포함된 주요 변경 사항은 다음과 같습니다.

   ### 🚀 주요 신규 기능
   - <주요 신규 기능 1>
   - <주요 신규 기능 2>

   ### 🛠 버그 수정 및 성능 최적화
   - <버그 수정 및 개선 사항 1>
   - <버그 수정 및 개선 사항 2>

   ### 📦 다운로드 및 설치
   - 아래 Assets 목록에서 **Wattly-X.Y.Z.dmg** 또는 **Wattly-X.Y.Z.zip** 파일을 다운로드하세요.
   - 처음 실행 시 팬 제어를 위한 백그라운드 헬퍼 도구(`WattlyFanDaemon`) 설치 승인이 필요할 수 있습니다.

   ---

   <details>
   <summary><b>English Release Notes (Click to expand)</b></summary>

   ### Wattly vX.Y.Z Release Notes

   Wattly vX.Y.Z is now available with the following improvements and fixes:

   #### 🚀 New Features
   - <English feature description 1>
   - <English feature description 2>

   #### 🛠 Bug Fixes & Improvements
   - <English fix description 1>
   - <English fix description 2>

   #### 📦 Installation
   - Download **Wattly-X.Y.Z.dmg** or **Wattly-X.Y.Z.zip** from the Assets section below.
   - Project Wattly requires privileged helper authorization on first launch for Apple Silicon fan control.
   </details>
   ```

---

### Step 6: Human Approval Gate [HARD STOP]

Before publishing or creating any remote git tags, the agent MUST present a summary and halt execution.

#### Presentation Format
Present the following information clearly to the user:
1. **Target Release**: `vX.Y.Z` (Build `N`)
2. **Artifact Verification Table**:
   | Artifact | File Size | Helper Verified | Check Status |
   |---|---|---|---|
   | `build/Wattly-X.Y.Z.dmg` | `<size>` | Yes (`Contents/Helpers/WattlyFanDaemon`) | Pass |
   | `build/Wattly-X.Y.Z.zip` | `<size>` | Yes (`Contents/Helpers/WattlyFanDaemon`) | Pass |
3. **Draft Release Notes Preview**: Render the entire markdown draft generated in Step 5.

#### User Confirmation Prompt
Prompt the user with the exact question:
> **"이상의 릴리즈 노트와 아티팩트로 vX.Y.Z 태그를 푸시하고 GitHub Release를 발행하시겠습니까? (Yes / No / 수정 요청)"**

**STRICT RULE**:
- If user responds **Yes**: Proceed directly to Step 7.
- If user responds **수정 요청** (Revision): Edit `/tmp/wattly_release_notes.md` according to feedback and repeat Step 6.
- If user responds **No** or cancels: STOP and do NOT tag or publish.

---

### Step 7: Tag, Publish & Worktree Sync

Run this step ONLY after receiving explicit user approval from Step 6.

1. **Create annotated git tag**:
   ```bash
   git tag -a vX.Y.Z -m "Wattly vX.Y.Z"
   ```

2. **Push branch and tag to remote**:
   - In secondary worktree:
     ```bash
     git push origin HEAD:main && git push origin vX.Y.Z
     ```
   - On main branch:
     ```bash
     git push origin main && git push origin vX.Y.Z
     ```

3. **Publish GitHub Release**:
   ```bash
   gh release create vX.Y.Z \
     build/Wattly-X.Y.Z.dmg \
     build/Wattly-X.Y.Z.zip \
     --title "Wattly vX.Y.Z" \
     --notes-file /tmp/wattly_release_notes.md
   ```

4. **Synchronize primary repository worktree**:
   ```bash
   PRIMARY_REPO="/Users/hyunjun_macbook_pro/Documents/Project/project_wattly"
   if [ -d "$PRIMARY_REPO/.git" ]; then
     git -C "$PRIMARY_REPO" pull origin main
   fi
   ```

---

## Multi-Worktree Safety Protocol

When operating inside an Antigravity isolated git worktree:
1. **Branch Collision Avoidance**: Never execute `git checkout main` within a secondary worktree if `main` is already checked out in the primary worktree. Git will fail with `fatal: 'main' is already checked out at...`.
2. **Push HEAD Directly**: Always use `git push origin HEAD:main` to update the remote main branch without switching local branches.
3. **Primary Sync**: Synchronize the primary worktree using `git -C <PRIMARY_REPO> pull origin main`. This avoids dirty working tree conflicts while keeping local files current.

---

## Error Handling & Rollback Matrix

| Failure Stage | Error Scenario | Immediate Resolution / Rollback Command |
|---|---|---|
| **Step 1 (Preflight)** | Tests fail or dirty working tree | Abort immediately. Zero files touched. `git status` to diagnose. |
| **Step 2 (Bump)** | `xcodegen` failure | Revert `project.yml` and project files:<br>`git checkout -- project.yml Wattly.xcodeproj` |
| **Step 3 (Packaging)** | `make-dmg.sh` or `build_release.sh` error | Clean build artifacts: `rm -rf build/ .build/`. Investigate compile error. |
| **Step 4 (Verification)** | `WattlyFanDaemon` missing or size abnormal | Verify `project.yml` copy-files phase for `WattlyFanDaemon`. Rebuild. |
| **Step 6 (Gate)** | User cancels release | Revert bump commit if desired:<br>`git reset --soft HEAD~1 && git checkout -- project.yml Wattly.xcodeproj` |
| **Step 7 (Publish)** | `gh release create` timeout or network error | Idempotent retry (no rebuild needed):<br>`gh release create vX.Y.Z build/Wattly-X.Y.Z.dmg build/Wattly-X.Y.Z.zip --title "Wattly vX.Y.Z" --notes-file /tmp/wattly_release_notes.md` |
| **Step 7 (Tag)** | Tag created locally but push fails | Delete local tag if needed:<br>`git tag -d vX.Y.Z` |

---

## Quick Reference Summary Table

| Step | Action | Key Command | Exit / Validation Criteria |
|---|---|---|---|
| **1. Preflight** | Clean tree & tests | `xcodebuild -project Wattly.xcodeproj -scheme Wattly test` | `** TEST SUCCEEDED **`, clean git status |
| **2. Bump** | Version bump & xcodegen | `/Users/hyunjun_macbook_pro/bin/xcodegen generate` | Build settings match target version |
| **3. Package** | Build DMG & ZIP | `zsh scripts/make-dmg.sh && bash scripts/build_release.sh` | Assets created under `build/` |
| **4. Verify** | Check helper daemon | `test -x /tmp/wattly_mnt/.../WattlyFanDaemon` | Executable helper confirmed in DMG and ZIP |
| **5. Notes** | Synthesize release notes | `git log ${PREV_TAG}..HEAD --oneline` | Bilingual template saved to `/tmp/wattly_release_notes.md` |
| **6. Gate** | Human Approval Gate | Explicit Stop Prompt | User responds "Yes" |
| **7. Publish** | Tag, Push, GH Release, Sync | `gh release create vX.Y.Z build/...` | GitHub Release URL generated, primary repo synced |
