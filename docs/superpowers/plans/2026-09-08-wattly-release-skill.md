# Wattly Release Automation Skill (`wattly-release`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the repository-level custom skill `.agents/skills/wattly-release/SKILL.md` to automate Wattly's release pipeline (preflight testing, version bump, DMG/ZIP packaging, daemon integrity checks, bilingual notes generation, human approval gate, and GitHub release publication).

**Architecture:** A self-contained, project-specific custom skill runbook placed in `.agents/skills/wattly-release/SKILL.md`. Uses existing repository packaging scripts (`scripts/make-dmg.sh`, `scripts/build_release.sh`), invokes `xcodegen`, checks daemon binary permissions, synthesizes bilingual notes from git logs, enforces a hard human approval stop, and safely navigates multi-worktree environments.

**Tech Stack:** Antigravity / AgentSkills format (YAML frontmatter + Markdown runbook), Zsh/Bash, Xcodebuild, xcodegen, GitHub CLI (`gh`), hdiutil.

**Spec:** [docs/superpowers/specs/2026-09-08-wattly-release-design.md](file:///Users/hyunjun_macbook_pro/.gemini/antigravity/worktrees/project_wattly/bright_sol_phases_00h42/docs/superpowers/specs/2026-09-08-wattly-release-design.md)

## Global Constraints

- Scope: Author `.agents/skills/wattly-release/SKILL.md` and commit the skill and plan. Do not touch project source code or modify current version in `project.yml`.
- Skill Format: Standard YAML frontmatter (`name`, `description` with rich triggering conditions starting with "Use when...", third-person).
- Pipeline Fidelity: Match the validated 7-step pipeline established in design spec and v1.1.0 release.
- Safety & Gates: Hard human approval gate before pushing git tags or publishing GitHub release.
- Worktree Awareness: Include explicit handling for secondary git worktrees to prevent branch collisions.

---

### Task 1: Author `.agents/skills/wattly-release/SKILL.md`

**Files:**
- Create: `.agents/skills/wattly-release/SKILL.md`

**Interfaces:**
- Consumes: Design spec [docs/superpowers/specs/2026-09-08-wattly-release-design.md](file:///Users/hyunjun_macbook_pro/.gemini/antigravity/worktrees/project_wattly/bright_sol_phases_00h42/docs/superpowers/specs/2026-09-08-wattly-release-design.md)
- Produces: Complete, executable skill runbook `.agents/skills/wattly-release/SKILL.md`

- [ ] **Step 1: Write `.agents/skills/wattly-release/SKILL.md`**
  - Create directory `.agents/skills/wattly-release/`.
  - Write `SKILL.md` containing:
    1. YAML frontmatter (`name: wattly-release`, SDO description).
    2. Overview and invocation modes (explicit version vs intelligent commit analysis).
    3. Step-by-step execution guide (Steps 1 to 7) with exact copy-pasteable commands:
       - Step 1: Preflight Audit (`git status`, `xcodebuild test`, tool checks).
       - Step 2: Version bump in `project.yml` and `/Users/hyunjun_macbook_pro/bin/xcodegen generate`.
       - Step 3: Distribution packaging (`make-dmg.sh`, `build_release.sh`).
       - Step 4: Asset & `WattlyFanDaemon` integrity check (DMG mount test, ZIP listing, size sanity).
       - Step 5: Bilingual release notes generation template (Korean overview + collapsible English details).
       - Step 6: Human Approval Gate (explicit STOP and user prompt).
       - Step 7: Tagging (`git tag -a vX.Y.Z`), remote push, GitHub release creation (`gh release create`), and worktree primary repo sync.
    4. Multi-worktree safety protocol.
    5. Error handling and rollback cheat-sheet.
    6. Quick reference summary table.

- [ ] **Step 2: Commit `.agents/skills/wattly-release/SKILL.md`**
  ```bash
  git add .agents/skills/wattly-release/SKILL.md
  git commit -m "feat(skills): add wattly-release custom skill"
  ```

---

### Task 2: Validate Skill File and Verify Operational Pre-requisites

**Files:**
- Verify: `.agents/skills/wattly-release/SKILL.md`
- Track: `docs/superpowers/plans/2026-09-08-wattly-release-skill.md`

**Interfaces:**
- Consumes: `.agents/skills/wattly-release/SKILL.md`
- Produces: Validated, committed release skill and tracked plan.

- [ ] **Step 1: Verify Skill YAML Frontmatter and Markdown Rendering**
  - Run python one-liner to parse YAML frontmatter and ensure `name` and `description` are valid.
  - Verify all internal references to scripts (`scripts/make-dmg.sh`, `scripts/build_release.sh`) point to existing executable files.

- [ ] **Step 2: Dry-run Verification of Referenced Tools**
  - Verify `scripts/make-dmg.sh` and `scripts/build_release.sh` exist and have execute permissions.
  - Verify `xcodegen` and `gh` availability.

- [ ] **Step 3: Commit Implementation Plan**
  ```bash
  git add docs/superpowers/plans/2026-09-08-wattly-release-skill.md
  git commit -m "docs: add wattly-release skill implementation plan"
  ```
