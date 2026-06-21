# Fonts — Pretendard Variable (A17 resolved = bundle)

`PretendardVariable.ttf` is the UI face. It's registered at launch in code
(`FontRegistration.register()` → `CTFontManagerRegisterFontsForURL`, process scope),
so no `Info.plist` / `ATSApplicationFontsPath` key is needed. `WattlyFont.family`
references the family name **`Pretendard Variable`**.

- Source: github.com/orioncactus/pretendard release **v1.3.9** (the version the
  prototype pins). The variable TTF (not the CDN woff2 — macOS can't register woff2).
- Note: the prototype's CSS stack lists "Pretendard JP" first but only loads regular
  `Pretendard Variable`, so this is the pixel-faithful choice; JP would only add
  Japanese glyphs the Korean UI doesn't use.
- License: SIL Open Font License 1.1 — see `OFL.txt` (bundled for compliance).
