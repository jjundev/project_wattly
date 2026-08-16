# Wattly README Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create clean, comprehensive, and visual `README.md` (English) and `README.ko.md` (Korean) documentation for the Wattly repository, incorporating all 16 generated @2x Retina screenshot assets and dynamic motion animations.

**Architecture:** Dual-language markdown documentation with synchronized structure, relative asset references (`docs/assets/...`), zero-privilege security disclosures, 3-tier installation instructions, hardware telemetry breakdowns, and Apple Silicon compatibility tables. No badges or decorative fluff.

**Tech Stack:** GitHub Flavored Markdown (GFM), SVG/PNG/GIF visual embedding, Xcode build commands, Homebrew Cask specs.

## Global Constraints

- No project badges / Shields.io badges.
- Relative image paths must resolve from repo root: `docs/assets/<filename>.png` / `docs/assets/<filename>.gif`.
- Exact dual-language parity between `README.md` (English) and `README.ko.md` (Korean).
- All Apple Silicon SoC generations (M1, M2, M3, M4 across Base, Pro, Max, Ultra) accurately documented.
- Zero-privilege architecture & SMCPowermetrics read-only pipeline clearly explained.

---

### Task 1: Create `README.md` (English)

**Files:**
- Create: `README.md`
- Assets referenced: `docs/assets/app-icon.png`, `docs/assets/menubar-icon-motion.gif`, `docs/assets/popover-mode-a-stacked.png`, `docs/assets/popover-mode-b-grid.png`, `docs/assets/popover-mode-c-hero.png`, `docs/assets/expand-power.png`, `docs/assets/expand-cpu.png`, `docs/assets/expand-gpu.png`, `docs/assets/expand-memory.png`, `docs/assets/expand-battery.png`, `docs/assets/expand-thermals.png`, `docs/assets/settings-fan-curve.png`, `docs/assets/settings-menubar.png`, `docs/assets/settings-thresholds.png`, `docs/assets/settings-display.png`, `docs/assets/menubar-styles-preview.png`

**Interfaces:**
- Produces: Root `README.md` for English repository visitors.

- [x] **Step 1: Write `README.md`**

Create `README.md` with:
1. Language switch: `[English](README.md) | [한국어](README.ko.md)`
2. Header with centered 128px App Icon, title "Wattly", and tagline: "Pure Swift Apple Silicon telemetry & smart thermal control designed exclusively for macOS."
3. Live Menu Bar kinetic motion showcase (`docs/assets/menubar-icon-motion.gif`).
4. 3 Popover Modes showcase (Stacked, Compact Grid, Hero + List).
5. 6 Hardware Deep-Dive Breakdown cards (Power SoC W, CPU P/E cores & active GHz, GPU 3D/Tiler/VRAM, Unified Memory Footprint, Battery Telemetry, Thermals & Hotspots).
6. Smart Fan Curve Editor & Zero-RPM Hold range walkthrough (`docs/assets/settings-fan-curve.png`).
7. 3-Tier Installation guide (Homebrew Cask, DMG release, Build from source with XcodeGen).
8. Architecture & Zero-Privilege Security Model (Reader vs Helper Daemon isolation).
9. Apple Silicon Compatibility Matrix (M1–M4, macOS 14.0+ Sonoma / macOS 15.0+ Sequoia).
10. Settings & Customization Guide (`docs/assets/settings-menubar.png`, `docs/assets/settings-thresholds.png`, `docs/assets/settings-display.png`).
11. License (MIT) & Contributing Guidelines.

- [x] **Step 2: Verify relative links and image references in `README.md`**

Run: `python3 -c 'import re, os; txt = open("README.md").read(); imgs = re.findall(r"\((docs/assets/[^)]+)\)", txt); [print("OK:", img) if os.path.exists(img) else print("MISSING:", img) for img in imgs]'`
Expected: All referenced assets print `OK`.

- [x] **Step 3: Commit `README.md`**

```bash
git add README.md
git commit -m "docs: add comprehensive English README.md with Retina screenshots"
```

---

### Task 2: Create `README.ko.md` (Korean)

**Files:**
- Create: `README.ko.md`

**Interfaces:**
- Produces: Root `README.ko.md` for Korean repository visitors.

- [x] **Step 1: Write `README.ko.md`**

Create `README.ko.md` with the full Korean translation:
1. Language switch: `[English](README.md) | [한국어](README.ko.md)`
2. Centered App Icon, "Wattly", "Apple Silicon Mac을 위한 초경량 고성능 시스템 텔레메트리 & 스마트 팬 컨트롤러".
3. 실시간 키네틱 메뉴바 모션 (`docs/assets/menubar-icon-motion.gif`).
4. 3대 팝오버 레이아웃 모드 (스택형 모드 A, 컴팩트 그리드 모드 B, 히어로 모드 C).
5. 6대 하드웨어 정밀 분해 카드 (SoC 엔진별 W 분해, CPU P/E 클러스터 및 실시간 클럭, GPU 렌더러/타일러/VRAM, 통합 메모리 풋프린트, 배터리 순방전 및 헬스, 핫스팟 발열 감시).
6. 스마트 팬 커브 에디터 및 상태 유지 구간 안내.
7. 3단계 설치 가이드 (Homebrew Cask, DMG 다운로드, 소스 빌드).
8. 무권한 읽기 아키텍처 & 안전한 도우미 데몬 격리 설계.
9. Apple Silicon 호환성 표 (M1 ~ M4 전 라인업).
10. 설정 화면 및 메뉴바 커스텀 가이드.
11. 라이선스 및 기여 안내.

- [x] **Step 2: Verify relative links and image references in `README.ko.md`**

Run: `python3 -c 'import re, os; txt = open("README.ko.md").read(); imgs = re.findall(r"\((docs/assets/[^)]+)\)", txt); [print("OK:", img) if os.path.exists(img) else print("MISSING:", img) for img in imgs]'`
Expected: All referenced assets print `OK`.

- [x] **Step 3: Commit `README.ko.md`**

```bash
git add README.ko.md
git commit -m "docs: add Korean README.ko.md with Retina screenshots and deep dive docs"
```

---

### Task 3: Documentation Quality Audit & Cross-Link Verification

**Files:**
- Modify: `README.md`, `README.ko.md` (if any broken anchor or path is found)

- [ ] **Step 1: Run comprehensive markdown link and asset check script**

Verify:
- Every relative link `[text](path)` points to an existing file.
- Every anchor link `[text](#anchor)` matches an existing heading.
- Image syntax uses `![alt](docs/assets/...)`.

- [ ] **Step 2: Commit final link adjustments (if any)**

```bash
git add README.md README.ko.md
git commit -m "docs: finalize README links and asset references"
```
