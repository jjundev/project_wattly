# Wanted Design System

A design system folder distilled from Wanted Lab's open-source **Wanted Design System** (Figma file, "Wanted Design System (Community)").  
Source attribution: Wanted Lab — released **CC BY 4.0**.

This system describes the visual + interaction language used across Wanted's product family:

- **Wanted** — the flagship Korean job-search marketplace.
- **Wanted Space** — hybrid coworking / office service.
- **Wanted Gigs** — freelance / side-job marketplace.
- **Wanted Agent** — career-AI / agent product.
- **Wanted OneID** — unified login.
- **LaaS / Recruitment SaaS** — recruiter-side suite.

The design language is unified: a single grayscale spine (Cool Neutral), one signature blue (`#0066FF`), Pretendard JP for UI, Wanted Sans for brand expression.

---

## Sources

- **Figma file (mounted):** *Wanted Design System (Community)* — 25 pages, 36 frames, 1310 local components.  
  Pages of record:  
  `/Color---Atomic`, `/Color---Semantic`, `/Typography`, `/Spacing`, `/Theme`, `/Logo`, `/Icon`, `/Foundation`, `/3-Component`, `/2-Element`, `/Makers-Principle`, `/Updates`.
- **Open-source typefaces** (linked, not bundled):
  - [Pretendard / Pretendard JP](https://github.com/orioncactus/pretendard) — SIL OFL 1.1
  - [Wanted Sans](https://github.com/wanteddev/wanted-sans) — SIL OFL 1.1

> No application codebase was attached. UI kits are recreated from the Figma source of truth (JSX pseudocode + token values), so component-level fidelity is governed by what the Figma file expresses.

---

## Index — what's in this folder

| Path | What it is |
|---|---|
| `README.md` | This file. The brand brief, content + visual fundamentals, iconography. |
| `SKILL.md` | Agent Skill manifest (loadable by Claude Code). |
| `colors_and_type.css` | All color, type, spacing, radius, shadow, and motion tokens as CSS vars. |
| `assets/logos/` | Wanted-family logo SVGs (logotype, symbol). |
| `assets/icons/` | Icon library — see "Iconography" below. |
| `preview/` | Tile cards rendered into the project's Design System tab. |
| `ui_kits/wanted/` | High-fidelity recreation of the Wanted job marketplace surface. |

---

## Brand voice — at a glance

> **"일하는 사람의 가능성을 잇다."** — *Connecting the possibilities of working people.*

Wanted is a **Korean career platform**. The product copy is bilingual but Korean-first; English is supportive, plainly translated, never marketing-puffy. Tone is **calm, direct, professionally warm** — not playful, not severe.

---

## CONTENT FUNDAMENTALS

### Voice + tone

- **Helpful, calm, slightly formal.** The Korean register is *합쇼체 / 해요체* mixed — polite-formal. English uses second-person ("you") for the user, present tense, short clauses.
- **No exclamation marks** in product UI (stat banners, marketing landing pages may use one sparingly).
- **Numbers carry weight.** Salary ranges, match scores, application counts are stated factually with units (`만원`, `명`, `건`) rather than dressed up.
- **No emoji** in product UI. The Figma source contains zero emoji on screens — only typography + iconography do communicative work.
- **Positive framing, but not hype.** "추천 포지션", "맞춤 합격률", "지금 채용 중" — useful state, not exclamation.

### Casing + punctuation

- Korean: standard sentence case; trailing periods optional in headings.
- English headings: **sentence case** for body, **Title Case** for navigation labels and product names ("Wanted Space", "Wanted Agent"). Avoid ALL CAPS except in tags/badges.
- Tags/labels: short, noun phrases (`신입`, `경력`, `Remote`, `New`).
- Section dividers in long-form content use a single dot leader or a horizontal rule, not decorative glyphs.

### Specific copy patterns (lifted from the Figma)

- Onboarding / overview lines:  
  *"Looking Forward — 기대하며"*, *"Scope — 범위"*, *"Before Use — 사용하기 전에"*  
  → English label, em-dash (or newline), Korean translation. Always paired.
- Acknowledgements list people by **first-name-last-name in Latin** (Hyungjin Kil, Doeun Kim, …) — Latin for international parity.
- Footer/about text mentions licensing in plain language: *"distributed under CC BY 4.0"*. Honest, no marketing gloss.

### What to avoid

- "We're so excited to…", "Get ready to…", "Game-changing…" — none of this fits.
- Em-dashes used as drama; in this system the em-dash is structural (label — translation).
- Emoji as bullets, sparkles, fire icons. Use a real icon from the icon set.
- Marketing color in body copy (`#0066FF` is for active state and CTAs, not for "look at me" text).

---

## VISUAL FOUNDATIONS

### Color

- **Backgrounds are white** (`#FFFFFF`) on light theme, deep near-black (`#171719`) on dark. Pure black is reserved for static/inverse-on-anything roles (logos, masks).
- **Cool Neutral** is the spine — every gray you see in the product is from this scale (`#F7F7F8 → #0F0F10`). Avoid warm grays.
- **Blue 50 (`#0066FF`)** is the only true brand color — used for primary CTAs, focus rings, links, and active state. Use sparingly; the system is overwhelmingly black/white/gray with blue accents.
- **Red 50 (`#FF4242`)** for negative/error. **Green 50 (`#00BF40`)** for positive. **Yellow 50 (`#FF9200`)** for cautionary. **Red Orange 50 (`#FF5E00`)** is reserved as a high-energy accent (used by Wanted Gigs subbrand).
- Tokens are **semantic-first**: `--color-label-normal` not `--w-coolneutral-5`. Atomic palette is for system-level decisions only.

### Typography

- **Pretendard JP** for everything UI: 11 → 64px scale, weights 500 / 600 / 700.
- **Wanted Sans** for brand expression — wordmark, decorative numerals, large hero type. Variable, full-color sets exist.
- Tracking is **negative for headings** (-2.3% to -2.7%) and **slightly positive for body** (+0.6%). Do not use 0 tracking — it reads bland in Korean.
- Line height by role: 1.20 (display), 1.33 (titles), 1.42–1.50 (body). Korean glyphs need the looser body LH.
- Mono is **SF Mono** (Apple system) for code; substitute with `ui-monospace` stack. No Roboto Mono / JetBrains.

### Spacing + grid

- Base unit **4px**. The visible scale is `4 · 8 · 12 · 16 · 20 · 24 · 32 · 40 · 48 · 64 · 80 · 96 · 128`.
- Section padding for marketing surfaces: `64–128px` vertical, `64px` side gutter on desktop.
- Component padding: chips/buttons use `12–16px` horizontal, `8–12px` vertical depending on size.
- Cards have `16px` internal padding small, `24–32px` medium, `64px` for full editorial cards.

### Radii

- The radius scale is `2 · 4 · 6 · 8 · 10 · 12 · 16 · 20 · 24 · 32 · pill · circle`.
- **Default rounding: 8–16px** for buttons, inputs, list rows.
- **Cards: 16–24px**. **Hero/editorial blocks: 32px**. **Avatars + tag pills: full pill**.
- The largest radius (`60px`) is reserved for top-level marketing canvases in the Figma — not used for in-product components.

### Backgrounds + texture

- Surfaces are **flat**. No gradients on UI chrome. The hero/marketing surfaces sometimes use a single image at 100% width with no overlay other than a black bottom-fade for legibility.
- The brand uses **photographic imagery, neutral / cool / candid** — coworking shots, portraits, hands-at-keyboard. No 3D, no abstract gradients, no AI-illustration.
- Decorative blocks use **flat color fills** + **typography**. No noise textures applied at the system level.

### Borders + dividers

- 1px hairlines using `--color-line-normal` (`rgba(112,115,124,0.22)`). Always 1px regardless of context.
- Dividers between long-form content use a **4px solid black** rule (a single bold horizontal line) — distinctive Wanted move.
- Inset borders inside dark cards switch to `rgba(174,176,182,0.22)`.

### Shadows / elevation

- 5-step elevation scale. Each step is **two-shadow stacked**: a tight inner shadow (depth) + a wider, softer drop (lift). Tinted near-black `rgba(23,23,23,…)` rather than pure black — keeps things calm.
- Pop-overs and modals use `--shadow-emphasize-large` (12/24). Cards use `--shadow-emphasize-small` (1/3) or none — flat-with-border is the more common style in this system.

### Layout rules

- Top-nav is **fixed**, sticky on scroll. Side rails are scroll-locked.
- Marketing pages run at **1280–1440px max** with auto margins; component grid is 12-column with 24px gutters at desktop.
- Mobile: single column, `16–20px` side gutters.
- Buttons in CTA banners are **always full-width on mobile**, content-width-with-padding on desktop.

### Hover / press states

- **Hover:** add `rgba(0,0,0,0.04)` overlay (light) / `rgba(255,255,255,0.06)` (dark). Primary buttons darken one step (`Blue-50 → Blue-45`).
- **Press / active:** stronger overlay (`0.08` / `0.10`). Subtle scale (`scale(0.98)`) is acceptable on mobile only — desktop press uses color shift only.
- **Focus:** **2px ring** in `--color-primary-normal`, offset by 2px from the surface. Always visible.

### Transparency + blur

- Used sparingly. The system uses **alpha-on-grays** (the `coolneutral-50 @ 22%` line color is the most distinctive token) rather than blur.
- A single `backdrop-filter: blur(20px)` is used for sticky sub-headers on long marketing pages and for iOS-style sheet headers — nowhere else.

### Motion

- **200ms standard, `cubic-bezier(0.2, 0, 0, 1)`** is the default ease — quick to start, settled on land. Use `--duration-normal` for most transitions.
- 120ms for hover/press color changes. 320ms only for layout shifts (sheet open, drawer slide).
- **No bounces, no springs.** Wanted's motion vocabulary is calm and decelerated.
- Page transitions: 8–12px upward slide + opacity fade, 320ms.

---

## ICONOGRAPHY

The Figma file ships an **in-house "Wanted Icon" set** — 24×24 base size, two stroke weights (`Thick=true/false`) and a `Tight=true/false` density variant.

Naming examples seen in the source:
- `chevronRightTightSmall` (the most common icon — 85+ instances)
- `check`, `chevronRight`, `arrowRight`, `magnifier`, `bell`, `user`, `home`, `gear`, `bookmark`, `share`, `more`, `heart`, `image`, `add`, `close`, `info`

Style:
- **Single stroke, 1.5–2px**, rounded line caps, rounded joins.
- **24×24** canvas with 2px optical padding.
- **No fills** by default. A second variant fills the icon for active/selected states.
- Color always inherits `currentColor` — never hardcoded.

In this folder we **substitute Lucide Icons** for the Wanted set: stroke-based, 24×24, the closest CDN match. **This is a substitution** — a one-to-one Wanted icon export was not present as raw SVG in the Figma file. Flag for the user: if Wanted's exported SVG kit is provided, drop them into `assets/icons/` and update the `<Icon>` component to use them.

```html
<!-- Lucide CDN, used by all UI kits in this folder -->
<script src="https://unpkg.com/lucide@latest/dist/umd/lucide.js"></script>
```

- **Emoji:** never used as iconography in this system.
- **Unicode glyphs:** `·` (middot) is used as a separator in metadata rows. `→` (arrow) appears in some marketing CTAs. Otherwise no glyph fonts.
- **Logos:** the Wanted family logos sit in `assets/logos/`. Use them at scale; never recolor outside black / white / `#14191E` (the official deep navy-black background).
