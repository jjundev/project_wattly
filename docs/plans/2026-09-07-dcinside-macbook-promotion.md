# DCInside MacBook Gallery Promotion Implementation Plan (Option 2 + Video GIF)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compose, verify, and semi-automatically inject a high-converting, community-authentic promotional post for Wattly into DCInside MacBook Gallery (`ibook`) via OpenCLI, featuring high-quality video GIF and comprehensive hardware visual proofs (Option 2).

**Architecture:** Convert GitHub demo video to a lightweight, high-fidelity GIF (`demo-overview.gif`), prepare verified text and image payload according to DCInside culture guidelines including detailed SoC/CPU cards, package all 7 visual assets, invoke `opencli dcinside write` in semi-automatic mode (`--no-submit`), and guide user through manual attachment insertion and submission.

**Tech Stack:** OpenCLI (`opencli dcinside write`), ffmpeg, Node.js, Markdown/Plain Text, macOS CLI.

## Global Constraints

- Never submit directly without explicit user consent; enforce `--no-submit` flag at all times.
- Target Gallery: DCInside MacBook Minor Gallery (`ibook` with `--mgallery` flag).
- Head/Category: `정보` (Information) via `--head "정보"`. Title string must NOT duplicate the `[정보]` tag prefix.
- Anonymity/Auth: Default anonymous credentials (`ㅇㅇ`, `1234`) or authenticated session without exposing PII.
- Tone and Manner: Native DC '음슴체', 3-line summary at top, honest developer narrative (college junior semester project), anti-AI-slop native Swift 6 positioning, 100% free/open-source.
- Visual Assets (Option 2 + Video, 7 items):
  1. `demo-overview.gif` (전체 구동 시연 고화질 움짤)
  2. `menubar-live.gif` (메뉴바 키네틱 모션)
  3. `popover-mode-a-stacked.png` (팝오버 3단 레이아웃)
  4. `expand-power.png` (SoC mW 단위 전력 분해)
  5. `expand-cpu.png` (코어 클러스터 주파수 게이지)
  6. `settings-fan-curve.png` (스마트 팬 커브 설정)
  7. `settings-battery.png` (배터리 관리 및 충전 제한 설정)

---

### Task 1: Generate Visual Assets & Prepare Final Draft

**Files:**
- Create: `docs/assets/demo-overview.gif` (Converted from demo-video.mp4)
- Create: `docs/promotions/2026-09-07-dcinside-macbook-post.txt`
- Reference: `docs/assets/demo-video.mp4`
- Reference: `docs/assets/menubar-live.gif`
- Reference: `docs/assets/popover-mode-a-stacked.png`
- Reference: `docs/assets/expand-power.png`
- Reference: `docs/assets/expand-cpu.png`
- Reference: `docs/assets/settings-fan-curve.png`
- Reference: `docs/assets/settings-battery.png`

**Interfaces:**
- Consumes: Video download `docs/assets/demo-video.mp4` and existing asset screenshots.
- Produces: `docs/assets/demo-overview.gif` (<10MB) and `docs/promotions/2026-09-07-dcinside-macbook-post.txt`.

- [ ] **Step 1: Convert demo-video.mp4 to high quality GIF under 10MB**

Ensure `docs/assets/demo-overview.gif` is generated with palettegen:
```bash
/opt/homebrew/bin/ffmpeg -i docs/assets/demo-video.mp4 -vf "fps=12,scale=640:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer" -y docs/assets/demo-overview.gif
```

- [ ] **Step 2: Write final post draft with Option 2 image placeholders**

Write `docs/promotions/2026-09-07-dcinside-macbook-post.txt`:

```text
<세줄요약>
1. 컴공 대3 학기중에 기존 툴들(AlDente, 팬컨트롤, 무거운 모니터링) 맘에 안 들어서 직접 만듦
2. AI로 대충 웹뷰 싼 슬롭 앱 극혐해서 순수 Swift 6 + SwiftUI로 네이티브 룩 맞춰 깎음
3. 완전 무료 오픈소스고 깃허브에 릴리즈 올려둠. 버그나 피드백 환영함

맥북 쓰면서 이것저것 툴 많이 깔아봤는데,
AlDente는 기능 좀 쓰려니까 유료 결제하라고 하고, 팬 컨트롤 앱은 UI가 너무 구식이고,
모니터링 툴들은 일렉트론 덩어리라 지가 배터리를 더 처먹는 꼬라지가 보기 싫었음.
특히 요즘 AI 코딩 유행하면서 껍데기만 번지르르한 웹뷰 슬롭 앱들 쏟아져 나오는 게 꼴보기 싫어서
그냥 학기중에 공부할 겸 순수 Swift 6랑 SwiftUI로 네이티브 감성 살려서 처음부터 끝까지 깎았음.

[이미지 1: 전체 UI 구동 시연 (demo-overview.gif)]
[이미지 2: 메뉴바 라이브 모션 (menubar-live.gif)]

앱 이름은 Wattly고, 딱 필요한 3대 기능 위주로 구성함:

1. 모니터링 (시스템 텔레메트리)
- 일반적인 단순 CPU 점유율 말고 M1~M5 실리콘 엔진별 전력 측정함
- CPU, GPU, ANE(뉴럴엔진) 개별 소모 전력(mW) 실시간 분해
- P-Core, E-Core 클러스터별 실시간 클럭 주파수(GHz)
- 디스플레이 백라이트, SSD, Wi-Fi까지 다 포함한 진짜 시스템 '순방전(Net Discharge)' 와트(W) 측정
- 백그라운드 유휴 전력 0.05W 미만이라 켜놔도 배터리 영향 거의 없음

[이미지 3: 팝오버 3단 레이아웃 (popover-mode-a-stacked.png)]
[이미지 4: 프로세서 전력 SoC 분해 (expand-power.png)]
[이미지 5: CPU 코어 클러스터 & 주파수 게이지 (expand-cpu.png)]

2. 스마트 팬 조절
- 애플 순정 팬 세팅은 90도 넘어야 뒤늦게 돌아서 팜레스트 뜨거워지는 거 빡쳐서 팬 커브 에디터 넣음
- 마우스로 점 찍어서 온도별 RPM 커스텀 가능
- 48°C~55°C 구간에 제로팬 히스테리시스 걸어둬서 팬 켜졌다 꺼졌다 딸깍거리는 소음 원천 차단함
- 혹시 모를 센서 오류나 앱 다운 대비해서 100°C 넘으면 하드웨어 강제 풀RPM 도는 워치독 안전장치 걸어둠

[이미지 6: 팬 커브 에디터 (settings-fan-curve.png)]

3. 배터리 수명 관리 (AlDente 대체)
- 상시 충전기 꽂아두는 사람들용 80%, 85%, 90% 충전 상한선 제한
- 충전 한도 도달하면 배터리 거치지 않고 순수 어댑터 전력으로만 구동하는 AC 바이패스 지원
- 한도 도달 후 1% 떨어질 때마다 충전되는 미세충전 방지하는 Sailing(자연 방전) 모드
- 외출하기 전에 한 번만 100% 채우고 나가면 자동으로 80% 복귀하는 Top-Up 기능 (12시간 자동 만료 안전장치 포함)
- 충전 상한 오래 걸어두면 BMS 틀어져서 배터리 튀는 현상 잡는 6단계 전자동 캘리브레이션 지원

[이미지 7: 배터리 관리 설정 (settings-battery.png)]

상업적 의도 1도 없고 혼자 쓰려고 만들었다가 맥북 유저들한테 도움 될까 싶어서 깃허브에 무료로 배포함.
디자인도 애플 HIG 최대한 지켜서 OS 기본 앱처럼 어색하지 않게 다듬으려고 신경 많이 썼음.

아직 학부생이라 부족한 점이나 예외 케이스 버그가 있을 수 있으니,
써보고 맘에 안 드는 점이나 까고 싶은 점, 추가됐으면 하는 기능 댓글로 편하게 달아주면 적극 반영하겠음.

- 다운로드 (GitHub Releases): https://github.com/jjundev/project_wattly/releases
(혹시 게이트키퍼 경고 뜨면 우클릭 > '열기' 누르면 실행됨)
```

- [ ] **Step 3: Verify all 7 image paths exist**

- [ ] **Step 4: Commit prepared draft and asset package**

---

### Task 2: Execute OpenCLI Semi-Auto Injection (`--no-submit`)

**Files:**
- Read: `docs/promotions/2026-09-07-dcinside-macbook-post.txt`

**Interfaces:**
- Consumes: Final text content from Task 1.
- Produces: Live browser session with title, category, and content pre-filled.

- [ ] **Step 1: Execute write command with semi-auto safety flag**

```bash
opencli dcinside write ibook \
  --mgallery \
  --head "정보" \
  --title "대3이 학기중에 빡쳐서 깎은 맥북 시스템/팬/배터리 올인원 툴 (무료)" \
  --content "$(cat docs/promotions/2026-09-07-dcinside-macbook-post.txt)" \
  --no-submit \
  -f yaml
```

---

### Task 3: Image Attachment Guidance & Final Submission Handoff

**Files:**
- Reference: `docs/promotions/2026-09-07-dcinside-macbook-post.txt`

**Interfaces:**
- Consumes: Running browser session.
- Produces: Published DCInside post link.

- [ ] **Step 1: Provide ordered image paths and instructions for drag-and-drop in editor**
- [ ] **Step 2: Guide user to verify Captcha and submit**
- [ ] **Step 3: Provide `/ask-dc` post-launch monitoring guide**
