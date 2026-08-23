#!/usr/bin/env python3
"""Merge translations into Wattly/Resources/Localizable.xcstrings.

Usage:  python3 scripts/add_localizations.py <additions.json>

<additions.json> maps each Korean catalog key to a {language: translation} dict.
Every key must supply a translation for every language already present in the
catalog; a partially-translated key builds fine and then shows Korean to the
users it forgot, so it is rejected here instead.

The catalog round-trips byte-identically through json.loads/json.dumps with
these settings, so the diff shows only the keys that were actually added.
"""
import json
import pathlib
import sys

CATALOG = pathlib.Path(__file__).resolve().parent.parent / "Wattly/Resources/Localizable.xcstrings"


def main(additions_path: str) -> None:
    catalog = json.loads(CATALOG.read_text())
    additions = json.loads(pathlib.Path(additions_path).read_text())

    known = {lang
             for entry in catalog["strings"].values()
             for lang in entry.get("localizations", {})}
    if not known:
        sys.exit("catalog has no languages to match against")

    for key, translations in additions.items():
        missing = known - set(translations)
        if missing:
            sys.exit(f"key {key!r} is missing languages: {sorted(missing)}")
        extra = set(translations) - known
        if extra:
            sys.exit(f"key {key!r} has languages the catalog does not use: {sorted(extra)}")

    for key, translations in additions.items():
        entry = catalog["strings"].setdefault(key, {})
        entry["extractionState"] = "manual"
        localizations = entry.setdefault("localizations", {})
        for lang, value in translations.items():
            localizations[lang] = {"stringUnit": {"state": "translated", "value": value}}

    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"merged {len(additions)} keys; catalog now has {len(catalog['strings'])} keys")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
