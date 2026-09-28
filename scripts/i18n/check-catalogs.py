#!/usr/bin/env python3
"""Report the translation state of Forumind's String Catalogs.

    scripts/i18n/check-catalogs.py            # all catalogs
    scripts/i18n/check-catalogs.py --list     # also list each problem key

Exits 1 when any key (other than ones marked "Don't translate") is missing a
zh-Hans or zh-Hant translation, is in a state other than "translated", is
stale (no longer in the code), or has format specifiers that differ from
English. ForumindTests/LocalizationCatalogTests.swift checks the same rules.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOGS = [
    "Forumind/Localizable.xcstrings",
    "Forumind/InfoPlist.xcstrings",
    "ForumindShare/Localizable.xcstrings",
    "ForumindShare/InfoPlist.xcstrings",
]
LANGUAGES = ["zh-Hans", "zh-Hant"]
SPECIFIER = re.compile(r"%(?:\d+\$)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSaAp]")


def specifiers(text):
    """Format specifiers without positional indices, sorted (a translation may
    reorder them with %1$@ / %2$@)."""
    return sorted(re.sub(r"\d+\$", "", s) for s in SPECIFIER.findall(text.replace("%%", "")))


def values(localization):
    """Every string a localization can produce (plain or per plural/device)."""
    if localization is None:
        return []
    out = []
    unit = localization.get("stringUnit")
    if unit:
        out.append(unit)
    for variation in localization.get("variations", {}).values():
        for case in variation.values():
            out.extend(values(case))
    return out


def main():
    show = "--list" in sys.argv
    failed = False
    for relative in CATALOGS:
        catalog = json.loads((ROOT / relative).read_text())
        strings = catalog["strings"]
        problems = []
        translatable = 0
        for key, entry in strings.items():
            if entry.get("extractionState") == "stale":
                problems.append((key, "stale (no longer in the code)"))
                continue
            if entry.get("shouldTranslate") is False:
                continue
            translatable += 1
            english = entry.get("localizations", {}).get("en")
            english_texts = [u["value"] for u in values(english)] or [key]
            expected = specifiers(english_texts[-1])
            for language in LANGUAGES:
                units = values(entry.get("localizations", {}).get(language))
                if not units:
                    problems.append((key, f"{language}: missing"))
                    continue
                for unit in units:
                    if unit.get("state") != "translated":
                        problems.append((key, f"{language}: state {unit.get('state')}"))
                    if specifiers(unit["value"]) != expected:
                        problems.append((key, f"{language}: format specifiers differ: {unit['value']!r}"))
        print(f"{relative}: {len(strings)} keys, {translatable} translatable, {len(problems)} problems")
        if problems:
            failed = True
            if show:
                for key, problem in problems:
                    print(f"  {key!r}: {problem}")
    if failed and not show:
        print("Run with --list to see each problem.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
