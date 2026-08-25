#!/usr/bin/env python3
"""
Generates full 30-language localizations for all missing/incomplete keys
and merges them into Wattly/Resources/Localizable.xcstrings.
"""

import json
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from scripts.translations.chunk1 import CHUNK1
from scripts.translations.chunk2 import CHUNK2
from scripts.translations.chunk3 import CHUNK3
from scripts.translations.chunk4 import CHUNK4
from scripts.translations.chunk5 import CHUNK5
CATALOG_PATH = REPO_ROOT / "Wattly/Resources/Localizable.xcstrings"

ALL_LANGS = [
    "ar", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he",
    "hi", "hu", "id", "it", "ja", "ko", "nb", "nl", "pl", "pt-BR",
    "pt-PT", "ro", "ru", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"
]

FMT_PATTERN = re.compile(r"%(?:%|(?:\d+\$)?(?:\d+)?(?:\.\d+)?[0-9]*(?:lld|llu|ld|lu|0\d+d|\.\d+f|[diuoxXfFeEgGaAcsp@]))")


def normalize_tokens(token_list: list) -> list:
    return sorted(re.sub(r"^%\d+\$", "%", t) for t in token_list)


def load_catalog() -> dict:
    with open(CATALOG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def save_catalog(data: dict) -> None:
    with open(CATALOG_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")


def get_all_translations() -> dict:
    combined = {}
    for chunk in [CHUNK1, CHUNK2, CHUNK3, CHUNK4, CHUNK5]:
        for key, trans in chunk.items():
            if key in combined:
                raise ValueError(f"Duplicate key across chunks: {key}")
            combined[key] = trans
    return combined


def validate_translations(translations: dict) -> None:
    print(f"Validating {len(translations)} translation entries...")
    errors = []
    for key, lang_map in translations.items():
        key_tokens = normalize_tokens(FMT_PATTERN.findall(key))
        missing_langs = set(ALL_LANGS) - set(lang_map.keys())
        if missing_langs:
            errors.append(f"Key {key!r} missing languages: {missing_langs}")
        extra_langs = set(lang_map.keys()) - set(ALL_LANGS)
        if extra_langs:
            errors.append(f"Key {key!r} has extra languages: {extra_langs}")
        for lang, val in lang_map.items():
            if not val:
                errors.append(f"Empty value for key {key!r} in {lang}")
            val_tokens = normalize_tokens(FMT_PATTERN.findall(val))
            if key_tokens != val_tokens:
                errors.append(
                    f"Format token mismatch in {lang} for key {key!r}: "
                    f"key tokens {key_tokens} vs val tokens {val_tokens} in {val!r}"
                )

    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        raise ValueError(f"Validation failed with {len(errors)} errors")
    print("All translation dictionaries passed format and language validation.")


def merge_translations(catalog: dict, translations: dict) -> None:
    strings = catalog.setdefault("strings", {})
    for key, lang_map in translations.items():
        entry = strings.setdefault(key, {})
        entry["extractionState"] = "manual"
        locs = entry.setdefault("localizations", {})
        for lang in ALL_LANGS:
            val = lang_map[lang]
            locs[lang] = {
                "stringUnit": {
                    "state": "translated",
                    "value": val
                }
            }


def verify_catalog(catalog: dict) -> None:
    strings = catalog.get("strings", {})
    print(f"\n--- Catalog Verification ---")
    print(f"Total keys in catalog: {len(strings)}")
    
    missing_count = 0
    untranslated_count = 0
    token_mismatch_count = 0

    for key, entry in strings.items():
        key_tokens = normalize_tokens(FMT_PATTERN.findall(key))
        locs = entry.get("localizations", {})
        for lang in ALL_LANGS:
            if lang not in locs:
                missing_count += 1
                print(f"MISSING: Key {key!r} missing language {lang}")
            else:
                unit = locs[lang].get("stringUnit", {})
                state = unit.get("state")
                val = unit.get("value", "")
                if state != "translated" or not val:
                    untranslated_count += 1
                    print(f"UNTRANSLATED: Key {key!r} in {lang} has state={state!r}")
                val_tokens = normalize_tokens(FMT_PATTERN.findall(val))
                if key_tokens != val_tokens:
                    token_mismatch_count += 1
                    print(f"FORMAT MISMATCH in catalog: Key {key!r} ({key_tokens}) vs {lang} ({val_tokens}): {val!r}")

    print(f"Missing language entries: {missing_count}")
    print(f"Untranslated entries: {untranslated_count}")
    print(f"Token format mismatches: {token_mismatch_count}")
    
    if missing_count == 0 and untranslated_count == 0 and token_mismatch_count == 0:
        print(f"100% of keys in Localizable.xcstrings have 'state': 'translated' across all {len(ALL_LANGS)} languages with 0 missing translations!")
    else:
        raise ValueError("Catalog verification failed!")


def main():
    translations = get_all_translations()
    validate_translations(translations)
    
    catalog = load_catalog()
    initial_count = len(catalog.get("strings", {}))
    print(f"Initial catalog keys: {initial_count}")
    
    merge_translations(catalog, translations)
    save_catalog(catalog)
    
    # Reload and verify
    reloaded_catalog = load_catalog()
    verify_catalog(reloaded_catalog)
    print(f"Catalog updated and saved to {CATALOG_PATH}")


if __name__ == "__main__":
    main()
