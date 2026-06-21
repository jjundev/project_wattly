/* @ds-bundle: {"format":3,"namespace":"WantedDesignSystem_019dde","components":[],"sourceHashes":{"ui_kits/wanted/components.jsx":"3be3d782af05","ui_kits/wanted/screens.jsx":"0359d1d70fa3"},"inlinedExternals":[],"unexposedExports":[]} */

(() => {

const __ds_ns = (window.WantedDesignSystem_019dde = window.WantedDesignSystem_019dde || {});

const __ds_scope = {};

(__ds_ns.__errors = __ds_ns.__errors || []);

// ui_kits/wanted/components.jsx
try { (() => {
/* Wanted UI kit — components.
 * Loaded as <script type="text/babel" src="components.jsx">.
 * Exposes pieces via window so the index can compose them.
 */

const Icon = ({
  name,
  size = 20,
  color = "currentColor",
  strokeWidth = 1.75
}) => {
  // Lucide stand-in. We use a hidden <i data-lucide=...> that's upgraded on mount.
  const ref = React.useRef(null);
  React.useEffect(() => {
    if (window.lucide) window.lucide.createIcons({
      icons: window.lucide.icons
    });
  }, [name]);
  return /*#__PURE__*/React.createElement("i", {
    ref: ref,
    "data-lucide": name,
    style: {
      width: size,
      height: size,
      color,
      strokeWidth,
      display: "inline-flex"
    }
  });
};
const Logo = ({
  inverse
}) => /*#__PURE__*/React.createElement("div", {
  style: {
    display: "flex",
    alignItems: "center",
    gap: 8
  }
}, /*#__PURE__*/React.createElement("div", {
  style: {
    width: 24,
    height: 24,
    borderRadius: 6,
    background: inverse ? "#fff" : "#14191E",
    color: inverse ? "#14191E" : "#fff",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    font: '800 14px "Wanted Sans Variable", sans-serif'
  }
}, "w"), /*#__PURE__*/React.createElement("div", {
  style: {
    font: '700 22px "Wanted Sans Variable", sans-serif',
    letterSpacing: "-0.04em",
    color: inverse ? "#fff" : "#14191E"
  }
}, "wanted"));
const TopNav = ({
  active = "home",
  onNavigate
}) => {
  const items = [{
    id: "home",
    label: "홈"
  }, {
    id: "jobs",
    label: "채용"
  }, {
    id: "match",
    label: "매칭"
  }, {
    id: "events",
    label: "이벤트"
  }, {
    id: "soha",
    label: "소셜"
  }, {
    id: "gigs",
    label: "Gigs"
  }];
  return /*#__PURE__*/React.createElement("nav", {
    style: {
      position: "sticky",
      top: 0,
      zIndex: 50,
      background: "rgba(255,255,255,0.92)",
      backdropFilter: "blur(20px)",
      WebkitBackdropFilter: "blur(20px)",
      borderBottom: "1px solid var(--color-line-normal)"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: 1280,
      margin: "0 auto",
      padding: "0 24px",
      display: "flex",
      alignItems: "center",
      gap: 32,
      height: 64
    }
  }, /*#__PURE__*/React.createElement("button", {
    onClick: () => onNavigate?.("home"),
    style: {
      background: "none",
      border: 0,
      cursor: "pointer",
      padding: 0
    }
  }, /*#__PURE__*/React.createElement(Logo, null)), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 4,
      flex: 1
    }
  }, items.map(it => /*#__PURE__*/React.createElement("button", {
    key: it.id,
    onClick: () => onNavigate?.(it.id),
    style: {
      font: "var(--type-headline-2)",
      color: active === it.id ? "var(--color-label-strong)" : "var(--color-label-alternative)",
      background: "transparent",
      border: 0,
      cursor: "pointer",
      padding: "8px 12px",
      borderRadius: 8,
      position: "relative"
    }
  }, it.label, active === it.id && /*#__PURE__*/React.createElement("span", {
    style: {
      position: "absolute",
      left: 12,
      right: 12,
      bottom: -16,
      height: 2,
      background: "var(--w-blue-50)"
    }
  })))), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 8
    }
  }, /*#__PURE__*/React.createElement("button", {
    style: iconBtn
  }, /*#__PURE__*/React.createElement(Icon, {
    name: "search"
  })), /*#__PURE__*/React.createElement("button", {
    style: iconBtn
  }, /*#__PURE__*/React.createElement(Icon, {
    name: "bell"
  })), /*#__PURE__*/React.createElement("button", {
    style: iconBtn
  }, /*#__PURE__*/React.createElement(Icon, {
    name: "bookmark"
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      width: 32,
      height: 32,
      borderRadius: "50%",
      background: "rgba(0,102,255,0.12)",
      color: "#0054D1",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      font: '600 13px "Pretendard JP Variable", sans-serif'
    }
  }, "JD"))));
};
const iconBtn = {
  width: 36,
  height: 36,
  borderRadius: 8,
  background: "transparent",
  border: 0,
  cursor: "pointer",
  display: "inline-flex",
  alignItems: "center",
  justifyContent: "center",
  color: "var(--color-label-neutral)"
};
const Pill = ({
  children,
  tone = "neutral",
  size = "sm"
}) => {
  const tones = {
    neutral: {
      bg: "rgba(112,115,124,0.10)",
      fg: "#37383C"
    },
    blue: {
      bg: "rgba(0,102,255,0.10)",
      fg: "#0054D1"
    },
    orange: {
      bg: "rgba(255,94,0,0.10)",
      fg: "#CC4B00"
    },
    green: {
      bg: "rgba(0,191,64,0.12)",
      fg: "#009632"
    },
    solid: {
      bg: "#171719",
      fg: "#fff"
    }
  }[tone] || {
    bg: "rgba(112,115,124,0.10)",
    fg: "#37383C"
  };
  const pad = size === "sm" ? "3px 9px" : "5px 12px";
  const fz = size === "sm" ? "var(--type-caption-2)" : "var(--type-caption-1)";
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 4,
      font: fz,
      padding: pad,
      borderRadius: 999,
      background: tones.bg,
      color: tones.fg,
      whiteSpace: "nowrap"
    }
  }, children);
};
const Button = ({
  children,
  variant = "primary",
  size = "md",
  icon,
  onClick,
  full,
  type
}) => {
  const variants = {
    primary: {
      bg: "#0066FF",
      fg: "#fff",
      bd: "transparent"
    },
    solid: {
      bg: "#171719",
      fg: "#fff",
      bd: "transparent"
    },
    outline: {
      bg: "#fff",
      fg: "#171719",
      bd: "rgba(112,115,124,0.22)"
    },
    tonal: {
      bg: "rgba(112,115,124,0.08)",
      fg: "#171719",
      bd: "transparent"
    },
    text: {
      bg: "transparent",
      fg: "#0066FF",
      bd: "transparent"
    },
    danger: {
      bg: "#FF4242",
      fg: "#fff",
      bd: "transparent"
    }
  }[variant];
  const sizes = {
    sm: {
      pad: "6px 12px",
      fz: "var(--type-caption-1)",
      r: 6,
      ic: 14
    },
    md: {
      pad: "10px 16px",
      fz: "var(--type-label-1)",
      r: 8,
      ic: 16
    },
    lg: {
      pad: "14px 22px",
      fz: "var(--type-headline-2)",
      r: 10,
      ic: 18
    }
  }[size];
  return /*#__PURE__*/React.createElement("button", {
    type: type,
    onClick: onClick,
    style: {
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      gap: 6,
      width: full ? "100%" : "auto",
      padding: sizes.pad,
      font: sizes.fz,
      borderRadius: sizes.r,
      background: variants.bg,
      color: variants.fg,
      border: `1px solid ${variants.bd}`,
      cursor: "pointer",
      transition: "background var(--duration-fast) var(--ease-standard), transform var(--duration-fast) var(--ease-standard)"
    },
    onMouseDown: e => e.currentTarget.style.transform = "scale(0.98)",
    onMouseUp: e => e.currentTarget.style.transform = "scale(1)",
    onMouseLeave: e => e.currentTarget.style.transform = "scale(1)"
  }, icon && /*#__PURE__*/React.createElement(Icon, {
    name: icon,
    size: sizes.ic
  }), children);
};
const Avatar = ({
  initials,
  color = "#0066FF",
  size = 40
}) => /*#__PURE__*/React.createElement("div", {
  style: {
    width: size,
    height: size,
    borderRadius: "50%",
    background: `${color}1A`,
    color,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    font: `600 ${Math.round(size * 0.36)}px "Pretendard JP Variable", sans-serif`,
    flex: "none"
  }
}, initials);
const JobCard = ({
  company,
  title,
  location,
  salary,
  tags = [],
  saved,
  onSave,
  image
}) => /*#__PURE__*/React.createElement("article", {
  style: {
    background: "#fff",
    border: "1px solid rgba(112,115,124,0.12)",
    borderRadius: 16,
    overflow: "hidden",
    transition: "transform var(--duration-normal) var(--ease-standard), box-shadow var(--duration-normal) var(--ease-standard)",
    cursor: "pointer"
  },
  onMouseEnter: e => {
    e.currentTarget.style.transform = "translateY(-2px)";
    e.currentTarget.style.boxShadow = "var(--shadow-emphasize-medium)";
  },
  onMouseLeave: e => {
    e.currentTarget.style.transform = "translateY(0)";
    e.currentTarget.style.boxShadow = "none";
  }
}, /*#__PURE__*/React.createElement("div", {
  style: {
    aspectRatio: "16 / 10",
    background: image || "linear-gradient(135deg,#1B1C1E,#37383C)",
    backgroundSize: "cover",
    backgroundPosition: "center",
    position: "relative"
  }
}, /*#__PURE__*/React.createElement("button", {
  onClick: e => {
    e.stopPropagation();
    onSave?.();
  },
  style: {
    position: "absolute",
    top: 12,
    right: 12,
    width: 36,
    height: 36,
    borderRadius: "50%",
    background: "rgba(255,255,255,0.92)",
    border: 0,
    cursor: "pointer",
    display: "flex",
    alignItems: "center",
    justifyContent: "center"
  }
}, /*#__PURE__*/React.createElement(Icon, {
  name: saved ? "bookmark-check" : "bookmark",
  size: 18,
  color: saved ? "#0066FF" : "#171719"
}))), /*#__PURE__*/React.createElement("div", {
  style: {
    padding: "14px 16px 16px"
  }
}, /*#__PURE__*/React.createElement("div", {
  style: {
    font: "var(--type-caption-1)",
    color: "var(--color-label-alternative)"
  }
}, company), /*#__PURE__*/React.createElement("div", {
  style: {
    font: "var(--type-headline-2)",
    color: "var(--color-label-strong)",
    marginTop: 2,
    letterSpacing: "-0.018em",
    display: "-webkit-box",
    WebkitLineClamp: 2,
    WebkitBoxOrient: "vertical",
    overflow: "hidden"
  }
}, title), /*#__PURE__*/React.createElement("div", {
  style: {
    display: "flex",
    gap: 4,
    alignItems: "center",
    marginTop: 8,
    font: "var(--type-caption-1)",
    color: "var(--color-label-neutral)"
  }
}, /*#__PURE__*/React.createElement(Icon, {
  name: "map-pin",
  size: 13
}), " ", location, salary && /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("span", null, "\xB7"), /*#__PURE__*/React.createElement("span", null, salary))), tags.length > 0 && /*#__PURE__*/React.createElement("div", {
  style: {
    display: "flex",
    gap: 6,
    marginTop: 10,
    flexWrap: "wrap"
  }
}, tags.map((t, i) => /*#__PURE__*/React.createElement(Pill, {
  key: i,
  tone: t.tone
}, t.label)))));
const FilterChip = ({
  active,
  onClick,
  children,
  count
}) => /*#__PURE__*/React.createElement("button", {
  onClick: onClick,
  style: {
    display: "inline-flex",
    alignItems: "center",
    gap: 6,
    font: "var(--type-label-2)",
    padding: "8px 14px",
    borderRadius: 999,
    background: active ? "#171719" : "#fff",
    color: active ? "#fff" : "var(--color-label-normal)",
    border: `1px solid ${active ? "#171719" : "rgba(112,115,124,0.22)"}`,
    cursor: "pointer",
    whiteSpace: "nowrap",
    transition: "all var(--duration-fast) var(--ease-standard)"
  }
}, children, count != null && /*#__PURE__*/React.createElement("span", {
  style: {
    font: "var(--type-caption-2)",
    color: active ? "rgba(255,255,255,0.7)" : "var(--color-label-alternative)"
  }
}, count));
const SearchBar = ({
  value,
  onChange,
  onSubmit
}) => /*#__PURE__*/React.createElement("form", {
  onSubmit: e => {
    e.preventDefault();
    onSubmit?.();
  },
  style: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    background: "#fff",
    border: "1px solid rgba(112,115,124,0.22)",
    borderRadius: 12,
    padding: "6px 6px 6px 16px",
    boxShadow: "var(--shadow-emphasize-small)"
  }
}, /*#__PURE__*/React.createElement(Icon, {
  name: "search",
  size: 18,
  color: "rgba(46,47,51,0.61)"
}), /*#__PURE__*/React.createElement("input", {
  value: value || "",
  onChange: e => onChange?.(e.target.value),
  placeholder: "\uC9C1\uBB34, \uD68C\uC0AC, \uC9C0\uC5ED\uC73C\uB85C \uAC80\uC0C9",
  style: {
    flex: 1,
    border: 0,
    outline: "none",
    font: "var(--type-body-1-r)",
    padding: "10px 0",
    background: "transparent",
    color: "var(--color-label-normal)"
  }
}), /*#__PURE__*/React.createElement(Button, {
  type: "submit",
  size: "md"
}, "\uAC80\uC0C9"));
const SectionHeader = ({
  title,
  sub,
  action
}) => /*#__PURE__*/React.createElement("div", {
  style: {
    display: "flex",
    alignItems: "flex-end",
    justifyContent: "space-between",
    marginBottom: 20,
    gap: 16
  }
}, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("h2", {
  style: {
    font: "var(--type-title-3)",
    letterSpacing: "-0.024em",
    color: "var(--color-label-strong)",
    margin: 0
  }
}, title), sub && /*#__PURE__*/React.createElement("div", {
  style: {
    font: "var(--type-body-2-r)",
    color: "var(--color-label-alternative)",
    marginTop: 4
  }
}, sub)), action);
const Hero = ({
  onSearch
}) => {
  const [q, setQ] = React.useState("");
  const phrases = ["Senior Product Designer", "Frontend Engineer", "AI Researcher", "프로덕트 매니저"];
  return /*#__PURE__*/React.createElement("section", {
    style: {
      background: "linear-gradient(180deg,#F7F7F8 0%, #FFFFFF 100%)",
      padding: "72px 0 56px",
      borderBottom: "1px solid var(--color-line-alternative)"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: 960,
      margin: "0 auto",
      padding: "0 24px",
      textAlign: "center"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--type-caption-2)",
      color: "#0066FF",
      textTransform: "uppercase",
      letterSpacing: "0.08em"
    }
  }, "\uC77C\uD558\uB294 \uC0AC\uB78C\uC758 \uAC00\uB2A5\uC131\uC744 \uC787\uB2E4"), /*#__PURE__*/React.createElement("h1", {
    style: {
      font: '700 56px "Wanted Sans Variable", sans-serif',
      letterSpacing: "-0.04em",
      lineHeight: 1.1,
      margin: "16px 0 0",
      color: "var(--color-label-strong)"
    }
  }, "\uB098\uC5D0\uAC8C \uAF2D \uB9DE\uB294", /*#__PURE__*/React.createElement("br", null), "\uCEE4\uB9AC\uC5B4 \uAE30\uD68C\uB97C \uCC3E\uB294 \uACF3."), /*#__PURE__*/React.createElement("p", {
    style: {
      font: "var(--type-body-1-r)",
      color: "var(--color-label-alternative)",
      marginTop: 16,
      lineHeight: 1.6
    }
  }, "Connecting the possibilities of working people. ", /*#__PURE__*/React.createElement("br", null), "235,124\uAC1C \uD3EC\uC9C0\uC158 \xB7 12,847\uAC1C \uD68C\uC0AC \xB7 \uD65C\uB3D9 \uC911\uC778 \uB3D9\uB8CC 198\uB9CC \uBA85"), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 28
    }
  }, /*#__PURE__*/React.createElement(SearchBar, {
    value: q,
    onChange: setQ,
    onSubmit: () => onSearch?.(q)
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 6,
      justifyContent: "center",
      flexWrap: "wrap",
      marginTop: 14
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--type-caption-1)",
      color: "var(--color-label-alternative)"
    }
  }, "\uC778\uAE30 \uAC80\uC0C9"), phrases.map(p => /*#__PURE__*/React.createElement("button", {
    key: p,
    onClick: () => {
      setQ(p);
      onSearch?.(p);
    },
    style: {
      font: "var(--type-caption-1)",
      background: "transparent",
      border: 0,
      cursor: "pointer",
      color: "var(--color-label-neutral)",
      padding: 0,
      textDecoration: "underline",
      textUnderlineOffset: 3
    }
  }, p))))));
};
const StatBar = () => {
  const stats = [{
    k: "235,124",
    l: "현재 채용 중인 포지션"
  }, {
    k: "12,847",
    l: "함께하는 회사"
  }, {
    k: "1.98M",
    l: "활동 중인 사용자"
  }, {
    k: "₩500만",
    l: "평균 합격축하금"
  }];
  return /*#__PURE__*/React.createElement("section", {
    style: {
      borderBottom: "4px solid #14191E",
      borderTop: "4px solid #14191E",
      padding: "40px 0",
      background: "#fff"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: 1280,
      margin: "0 auto",
      padding: "0 24px",
      display: "grid",
      gridTemplateColumns: "repeat(4,1fr)",
      gap: 24
    }
  }, stats.map(s => /*#__PURE__*/React.createElement("div", {
    key: s.l
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: '700 40px "Wanted Sans Variable", sans-serif',
      letterSpacing: "-0.03em",
      color: "var(--color-label-strong)"
    }
  }, s.k), /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--type-body-2-r)",
      color: "var(--color-label-alternative)",
      marginTop: 4
    }
  }, s.l)))));
};
const Footer = () => /*#__PURE__*/React.createElement("footer", {
  style: {
    background: "#171719",
    color: "rgba(247,247,248,0.61)",
    padding: "56px 0 40px",
    marginTop: 64
  }
}, /*#__PURE__*/React.createElement("div", {
  style: {
    maxWidth: 1280,
    margin: "0 auto",
    padding: "0 24px",
    display: "grid",
    gridTemplateColumns: "1.5fr 1fr 1fr 1fr",
    gap: 40
  }
}, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement(Logo, {
  inverse: true
}), /*#__PURE__*/React.createElement("p", {
  style: {
    marginTop: 16,
    font: "var(--type-caption-1)",
    lineHeight: 1.7
  }
}, "\u321C\uC6D0\uD2F0\uB4DC\uB7A9 \xB7 \uB300\uD45C \uC774\uBCF5\uAE30 \xB7 \uC11C\uC6B8\uD2B9\uBCC4\uC2DC \uAC15\uB0A8\uAD6C \uD14C\uD5E4\uB780\uB85C", /*#__PURE__*/React.createElement("br", null), "\uC0AC\uC5C5\uC790\uB4F1\uB85D 211-88-90264 \xB7 \uD1B5\uC2E0\uD310\uB9E4\uC5C5 2018-\uC11C\uC6B8\uAC15\uB0A8-04085")), [{
  h: "Wanted",
  l: ["채용", "이벤트", "AI 매칭", "커리어 콘텐츠"]
}, {
  h: "회사",
  l: ["회사 소개", "채용 정보", "Press", "투자자 정보"]
}, {
  h: "고객지원",
  l: ["공지사항", "도움말", "1:1 문의", "피드백"]
}].map(col => /*#__PURE__*/React.createElement("div", {
  key: col.h
}, /*#__PURE__*/React.createElement("div", {
  style: {
    font: "var(--type-label-1)",
    color: "#fff",
    marginBottom: 12
  }
}, col.h), col.l.map(li => /*#__PURE__*/React.createElement("div", {
  key: li,
  style: {
    font: "var(--type-caption-1)",
    padding: "5px 0",
    cursor: "pointer"
  }
}, li))))));
Object.assign(window, {
  Icon,
  Logo,
  TopNav,
  Pill,
  Button,
  Avatar,
  JobCard,
  FilterChip,
  SearchBar,
  SectionHeader,
  Hero,
  StatBar,
  Footer
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/wanted/components.jsx", error: String((e && e.message) || e) }); }

// ui_kits/wanted/screens.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/* Wanted UI kit — high-level screen compositions. */

const HomeScreen = ({
  onOpenJob,
  savedIds,
  onToggleSave,
  onSearch
}) => {
  const featured = [{
    id: "j1",
    company: "원티드랩",
    title: "Senior Product Designer (DesignOps)",
    location: "서울 · 강남구",
    salary: "5,000–8,000만원",
    tags: [{
      label: "채용 중",
      tone: "blue"
    }, {
      label: "정규직",
      tone: "neutral"
    }, {
      label: "합격축하금 500만원",
      tone: "orange"
    }],
    image: "linear-gradient(135deg,#0066FF 0%,#0054D1 100%)"
  }, {
    id: "j2",
    company: "토스 · Toss",
    title: "Frontend Engineer, Growth (Toss Pay)",
    location: "서울 · 역삼동",
    salary: "협의",
    tags: [{
      label: "경력 3년+",
      tone: "neutral"
    }, {
      label: "Remote 가능",
      tone: "green"
    }],
    image: "linear-gradient(135deg,#1B1C1E 0%,#37383C 100%)"
  }, {
    id: "j3",
    company: "당근 · Karrot",
    title: "AI Research Scientist — Recommendation",
    location: "서울 · 서초구",
    salary: "스톡옵션 포함",
    tags: [{
      label: "AI/ML",
      tone: "blue"
    }, {
      label: "PhD 우대",
      tone: "neutral"
    }],
    image: "linear-gradient(135deg,#FF5E00 0%,#CC4B00 100%)"
  }, {
    id: "j4",
    company: "쿠팡 · Coupang",
    title: "Engineering Manager, Logistics Platform",
    location: "서울 · 송파구",
    salary: "8,000–12,000만원",
    tags: [{
      label: "관리자",
      tone: "neutral"
    }, {
      label: "글로벌",
      tone: "blue"
    }],
    image: "linear-gradient(135deg,#00BF40 0%,#009632 100%)"
  }];
  const matches = [{
    id: "m1",
    title: "Product Designer",
    co: "Linear-style 스타트업",
    score: 94
  }, {
    id: "m2",
    title: "Senior PM, Platform",
    co: "리디 RIDI",
    score: 91
  }, {
    id: "m3",
    title: "Brand Designer",
    co: "마켓컬리",
    score: 88
  }];
  const filters = ["전체", "신입", "경력 3년+", "Remote", "스타트업", "외국계", "디자인", "엔지니어링", "AI/ML"];
  const [activeFilter, setFilter] = React.useState("전체");
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(Hero, {
    onSearch: onSearch
  }), /*#__PURE__*/React.createElement(StatBar, null), /*#__PURE__*/React.createElement("main", {
    style: {
      maxWidth: 1280,
      margin: "0 auto",
      padding: "56px 24px 0"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 8,
      overflowX: "auto",
      paddingBottom: 24,
      marginBottom: 8,
      scrollbarWidth: "none"
    }
  }, filters.map(f => /*#__PURE__*/React.createElement(FilterChip, {
    key: f,
    active: activeFilter === f,
    onClick: () => setFilter(f)
  }, f))), /*#__PURE__*/React.createElement(SectionHeader, {
    title: "\uC9C0\uAE08 \uC8FC\uBAA9\uD560 \uCC44\uC6A9",
    sub: "\uC774\uBC88 \uC8FC \uD65C\uBC1C\uD788 \uCC44\uC6A9 \uC911\uC778 \uD3EC\uC9C0\uC158",
    action: /*#__PURE__*/React.createElement(Button, {
      variant: "text",
      icon: "arrow-right"
    }, "\uC804\uCCB4 \uBCF4\uAE30")
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "grid",
      gridTemplateColumns: "repeat(4,1fr)",
      gap: 20
    }
  }, featured.map(j => /*#__PURE__*/React.createElement(JobCard, _extends({
    key: j.id
  }, j, {
    saved: savedIds.has(j.id),
    onSave: () => onToggleSave(j.id)
  })))), /*#__PURE__*/React.createElement("section", {
    style: {
      marginTop: 64
    }
  }, /*#__PURE__*/React.createElement(SectionHeader, {
    title: "AI \uB9E4\uCE6D \xB7 \uB2F9\uC2E0\uC744 \uC704\uD55C \uCD94\uCC9C",
    sub: "\uC774\uB825\uC11C\uB97C \uAE30\uBC18\uC73C\uB85C \uBD84\uC11D\uD55C \uD569\uACA9 \uAC00\uB2A5\uC131 \uB192\uC740 \uD3EC\uC9C0\uC158",
    action: /*#__PURE__*/React.createElement(Button, {
      variant: "outline",
      size: "md",
      icon: "sparkles"
    }, "\uB9E4\uCE6D \uB2E4\uC2DC \uBC1B\uAE30")
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      background: "#171719",
      color: "#fff",
      borderRadius: 24,
      padding: 32,
      display: "grid",
      gridTemplateColumns: "repeat(3,1fr)",
      gap: 16
    }
  }, matches.map(m => /*#__PURE__*/React.createElement("div", {
    key: m.id,
    style: {
      background: "rgba(255,255,255,0.06)",
      border: "1px solid rgba(174,176,182,0.22)",
      borderRadius: 16,
      padding: "20px 22px"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      justifyContent: "space-between"
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--type-caption-1)",
      color: "rgba(247,247,248,0.61)"
    }
  }, m.co), /*#__PURE__*/React.createElement("span", {
    style: {
      font: '700 14px "Pretendard JP Variable", sans-serif',
      color: "#69A5FF"
    }
  }, "\uB9E4\uCE6D ", m.score, "%")), /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--type-headline-2)",
      marginTop: 8
    }
  }, m.title), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 14,
      display: "flex",
      gap: 6
    }
  }, /*#__PURE__*/React.createElement(Pill, {
    tone: "blue"
  }, "\uC0C8 \uD3EC\uC9C0\uC158"), /*#__PURE__*/React.createElement(Pill, {
    tone: "neutral"
  }, "3\uC77C \uB0B4 \uC751\uB2F5")))))), /*#__PURE__*/React.createElement("section", {
    style: {
      marginTop: 80
    }
  }, /*#__PURE__*/React.createElement(SectionHeader, {
    title: "\uC6D0\uD2F0\uB4DC \uD328\uBC00\uB9AC",
    sub: "\uC77C\uACFC \uC77C\uC0C1\uC744 \uC787\uB294 \uC11C\uBE44\uC2A4\uB4E4"
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "grid",
      gridTemplateColumns: "repeat(3,1fr)",
      gap: 16
    }
  }, [{
    name: "Wanted Space",
    sub: "유연한 사무실, 지점 47곳",
    color: "#0066FF"
  }, {
    name: "Wanted Gigs",
    sub: "프리랜서·사이드 프로젝트",
    color: "#FF5E00"
  }, {
    name: "Wanted Agent",
    sub: "AI 커리어 에이전트",
    color: "#171719"
  }].map(b => /*#__PURE__*/React.createElement("div", {
    key: b.name,
    style: {
      background: "#fff",
      border: "1px solid rgba(112,115,124,0.16)",
      borderRadius: 20,
      padding: 28,
      cursor: "pointer",
      transition: "transform var(--duration-normal) var(--ease-standard)"
    },
    onMouseEnter: e => e.currentTarget.style.transform = "translateY(-3px)",
    onMouseLeave: e => e.currentTarget.style.transform = "translateY(0)"
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 44,
      height: 44,
      borderRadius: 10,
      background: b.color,
      color: "#fff",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      font: '800 22px "Wanted Sans Variable", sans-serif'
    }
  }, "w"), /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--type-heading-2)",
      letterSpacing: "-0.018em",
      color: "var(--color-label-strong)",
      marginTop: 16
    }
  }, b.name), /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--type-body-2-r)",
      color: "var(--color-label-alternative)",
      marginTop: 4
    }
  }, b.sub), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 18,
      display: "flex",
      alignItems: "center",
      gap: 4,
      font: "var(--type-label-2)",
      color: b.color
    }
  }, "\uBC14\uB85C\uAC00\uAE30 ", /*#__PURE__*/React.createElement(Icon, {
    name: "arrow-right",
    size: 14
  }))))))));
};
const JobsScreen = ({
  savedIds,
  onToggleSave
}) => {
  const jobs = Array.from({
    length: 8
  }, (_, i) => ({
    id: `jx${i}`,
    company: ["배달의민족", "라인", "네이버", "Spotify Korea", "AB180", "Channel.io", "리디", "Wadiz"][i],
    title: ["Product Designer — Restaurant App", "Tech Lead, Messaging Infrastructure", "Senior UX Researcher", "Backend Engineer, Music Recommendation", "Growth Marketer (B2B SaaS)", "iOS Developer, Customer Messaging", "Editorial Designer", "Frontend Engineer (React)"][i],
    location: ["서울 · 송파", "성남 · 분당", "성남 · 분당", "서울 · 강남", "서울 · 마포", "서울 · 강남", "서울 · 강남", "서울 · 성동"][i],
    salary: ["6,000~9,000만원", "협의", "5,500~8,000만원", "협의 (글로벌)", "4,500~6,500만원", "스톡옵션", "협의", "5,000~7,000만원"][i],
    tags: [[{
      label: "채용 중",
      tone: "blue"
    }], [{
      label: "경력 7년+",
      tone: "neutral"
    }], [{
      label: "리서치",
      tone: "neutral"
    }], [{
      label: "Remote 가능",
      tone: "green"
    }], [{
      label: "B2B",
      tone: "neutral"
    }, {
      label: "신입 가능",
      tone: "blue"
    }], [{
      label: "iOS",
      tone: "neutral"
    }], [{
      label: "출판",
      tone: "neutral"
    }], [{
      label: "React",
      tone: "blue"
    }]][i],
    image: ["linear-gradient(135deg,#FFD45A,#FFA938)", "linear-gradient(135deg,#00C300,#009E00)", "linear-gradient(135deg,#03C75A,#019D40)", "linear-gradient(135deg,#1DB954,#0E8C3E)", "linear-gradient(135deg,#0066FF,#0054D1)", "linear-gradient(135deg,#5639CC,#3E27A8)", "linear-gradient(135deg,#171719,#37383C)", "linear-gradient(135deg,#00B5DB,#0089A8)"][i]
  }));
  return /*#__PURE__*/React.createElement("main", {
    style: {
      maxWidth: 1280,
      margin: "0 auto",
      padding: "32px 24px 0"
    }
  }, /*#__PURE__*/React.createElement(SectionHeader, {
    title: "\uCC44\uC6A9 \uD3EC\uC9C0\uC158",
    sub: `총 ${jobs.length.toLocaleString()}개 결과 · 최신순`,
    action: /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        gap: 8
      }
    }, /*#__PURE__*/React.createElement(Button, {
      variant: "outline",
      size: "md",
      icon: "sliders"
    }, "\uD544\uD130"), /*#__PURE__*/React.createElement(Button, {
      variant: "outline",
      size: "md",
      icon: "arrow-up-down"
    }, "\uC815\uB82C"))
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 8,
      marginBottom: 24,
      flexWrap: "wrap"
    }
  }, ["서울", "경력 3년+", "디자인", "정규직", "재택근무"].map(t => /*#__PURE__*/React.createElement(Pill, {
    key: t,
    tone: "solid"
  }, t, " \u2715")), /*#__PURE__*/React.createElement("button", {
    style: {
      font: "var(--type-caption-1)",
      background: "transparent",
      border: 0,
      cursor: "pointer",
      color: "var(--color-label-alternative)"
    }
  }, "\uC804\uCCB4 \uCD08\uAE30\uD654")), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "grid",
      gridTemplateColumns: "repeat(4,1fr)",
      gap: 20
    }
  }, jobs.map(j => /*#__PURE__*/React.createElement(JobCard, _extends({
    key: j.id
  }, j, {
    saved: savedIds.has(j.id),
    onSave: () => onToggleSave(j.id)
  })))), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: "center",
      marginTop: 40
    }
  }, /*#__PURE__*/React.createElement(Button, {
    variant: "outline",
    size: "lg"
  }, "\uB354 \uBCF4\uAE30")));
};
const SavedScreen = ({
  savedIds,
  onToggleSave
}) => /*#__PURE__*/React.createElement("main", {
  style: {
    maxWidth: 1280,
    margin: "0 auto",
    padding: "32px 24px 0"
  }
}, /*#__PURE__*/React.createElement(SectionHeader, {
  title: "\uBD81\uB9C8\uD06C",
  sub: `${savedIds.size}개의 포지션을 저장했어요`
}), savedIds.size === 0 ? /*#__PURE__*/React.createElement("div", {
  style: {
    padding: "80px 0",
    textAlign: "center",
    color: "var(--color-label-alternative)",
    font: "var(--type-body-1-r)"
  }
}, /*#__PURE__*/React.createElement("div", {
  style: {
    width: 64,
    height: 64,
    margin: "0 auto",
    background: "var(--color-fill-normal)",
    borderRadius: "50%",
    display: "flex",
    alignItems: "center",
    justifyContent: "center"
  }
}, /*#__PURE__*/React.createElement(Icon, {
  name: "bookmark",
  size: 28
})), /*#__PURE__*/React.createElement("div", {
  style: {
    marginTop: 14
  }
}, "\uC544\uC9C1 \uC800\uC7A5\uD55C \uD3EC\uC9C0\uC158\uC774 \uC5C6\uC5B4\uC694. \uD648\uC5D0\uC11C \uB9C8\uC74C\uC5D0 \uB4DC\uB294 \uD3EC\uC9C0\uC158\uC744 \uBD81\uB9C8\uD06C\uD558\uC138\uC694.")) : /*#__PURE__*/React.createElement("div", {
  style: {
    display: "grid",
    gridTemplateColumns: "repeat(3,1fr)",
    gap: 20
  }
}, [...savedIds].map(id => /*#__PURE__*/React.createElement(JobCard, {
  key: id,
  id: id,
  company: "\uC800\uC7A5\uB41C \uD3EC\uC9C0\uC158",
  title: `Bookmarked: ${id}`,
  location: "\u2014",
  salary: "",
  tags: [{
    label: "저장됨",
    tone: "blue"
  }],
  saved: true,
  onSave: () => onToggleSave(id)
}))));
const ProfileScreen = () => /*#__PURE__*/React.createElement("main", {
  style: {
    maxWidth: 960,
    margin: "0 auto",
    padding: "32px 24px 0"
  }
}, /*#__PURE__*/React.createElement("div", {
  style: {
    background: "#fff",
    borderRadius: 24,
    border: "1px solid rgba(112,115,124,0.16)",
    padding: 32,
    display: "flex",
    gap: 24,
    alignItems: "center"
  }
}, /*#__PURE__*/React.createElement(Avatar, {
  initials: "JD",
  size: 88
}), /*#__PURE__*/React.createElement("div", {
  style: {
    flex: 1
  }
}, /*#__PURE__*/React.createElement("div", {
  style: {
    font: "var(--type-caption-1)",
    color: "var(--color-label-alternative)"
  }
}, "since 2021 \xB7 Wanted ID"), /*#__PURE__*/React.createElement("div", {
  style: {
    font: "var(--type-title-2)",
    letterSpacing: "-0.025em",
    color: "var(--color-label-strong)",
    marginTop: 4
  }
}, "\uAE40\uB514\uC790\uC778"), /*#__PURE__*/React.createElement("div", {
  style: {
    font: "var(--type-body-1-r)",
    color: "var(--color-label-neutral)",
    marginTop: 4
  }
}, "Senior Product Designer \xB7 7\uB144 \uACBD\uB825 \xB7 \uC11C\uC6B8")), /*#__PURE__*/React.createElement(Button, {
  variant: "outline",
  size: "md",
  icon: "pen"
}, "\uD504\uB85C\uD544 \uD3B8\uC9D1")), /*#__PURE__*/React.createElement(SectionHeader, {
  title: "\uD65C\uB3D9 \uC694\uC57D"
}), /*#__PURE__*/React.createElement("div", {
  style: {
    display: "grid",
    gridTemplateColumns: "repeat(4,1fr)",
    gap: 12
  }
}, [{
  k: "지원",
  v: 12
}, {
  k: "북마크",
  v: 38
}, {
  k: "메시지",
  v: 4
}, {
  k: "프로필 조회",
  v: 87
}].map(x => /*#__PURE__*/React.createElement("div", {
  key: x.k,
  style: {
    background: "#fff",
    border: "1px solid rgba(112,115,124,0.16)",
    borderRadius: 16,
    padding: "18px 20px"
  }
}, /*#__PURE__*/React.createElement("div", {
  style: {
    font: "var(--type-caption-1)",
    color: "var(--color-label-alternative)"
  }
}, x.k), /*#__PURE__*/React.createElement("div", {
  style: {
    font: '700 28px "Wanted Sans Variable", sans-serif',
    letterSpacing: "-0.025em",
    marginTop: 4
  }
}, x.v)))), /*#__PURE__*/React.createElement(SectionHeader, {
  title: "\uC774\uB825\uC11C",
  sub: "3\uAC1C\uC758 \uC774\uB825\uC11C\uB97C \uAD00\uB9AC\uD558\uACE0 \uC788\uC5B4\uC694"
}), /*#__PURE__*/React.createElement("div", {
  style: {
    display: "flex",
    flexDirection: "column",
    gap: 8
  }
}, [{
  name: "한국어 이력서 (메인)",
  date: "2026.04.21 수정",
  default: true
}, {
  name: "English Resume — Product Design",
  date: "2026.03.10 수정"
}, {
  name: "포트폴리오 PDF",
  date: "2025.12.02 업로드"
}].map(r => /*#__PURE__*/React.createElement("div", {
  key: r.name,
  style: {
    display: "flex",
    alignItems: "center",
    gap: 14,
    background: "#fff",
    border: "1px solid rgba(112,115,124,0.16)",
    borderRadius: 12,
    padding: "14px 16px"
  }
}, /*#__PURE__*/React.createElement("div", {
  style: {
    width: 40,
    height: 40,
    borderRadius: 10,
    background: "rgba(0,102,255,0.10)",
    color: "#0066FF",
    display: "flex",
    alignItems: "center",
    justifyContent: "center"
  }
}, /*#__PURE__*/React.createElement(Icon, {
  name: "file-text",
  size: 20
})), /*#__PURE__*/React.createElement("div", {
  style: {
    flex: 1
  }
}, /*#__PURE__*/React.createElement("div", {
  style: {
    font: "var(--type-body-1-b)",
    display: "flex",
    alignItems: "center",
    gap: 8
  }
}, r.name, " ", r.default && /*#__PURE__*/React.createElement(Pill, {
  tone: "blue"
}, "\uAE30\uBCF8")), /*#__PURE__*/React.createElement("div", {
  style: {
    font: "var(--type-caption-1)",
    color: "var(--color-label-alternative)"
  }
}, r.date)), /*#__PURE__*/React.createElement(Button, {
  variant: "text",
  size: "sm",
  icon: "more-horizontal"
}, "\uAD00\uB9AC")))));
Object.assign(window, {
  HomeScreen,
  JobsScreen,
  SavedScreen,
  ProfileScreen
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/wanted/screens.jsx", error: String((e && e.message) || e) }); }

})();
