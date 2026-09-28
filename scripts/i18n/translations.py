#!/usr/bin/env python3
"""Move translations in and out of a String Catalog as plain JSON.

    # Keys that still need a translation in any language, with their comments:
    scripts/i18n/translations.py export Forumind/Localizable.xcstrings > todo.json

    # Write translations back (state "translated"):
    scripts/i18n/translations.py import Forumind/Localizable.xcstrings done.json

    # Delete keys the code no longer uses (marked "stale" by the sync):
    scripts/i18n/translations.py prune Forumind/Localizable.xcstrings

The JSON maps each key to its translations. A value is a string, or an object
of plural cases for a count ("one"/"other" in English; Chinese uses only
"other"). "en" is only needed for plurals and for keys whose English text
differs from the key. `"shouldTranslate": false` marks brand names and
format-only keys.

    {
      "Summary": {"zh-Hans": "摘要", "zh-Hant": "摘要"},
      "%lld posts": {
        "en": {"one": "%lld post", "other": "%lld posts"},
        "zh-Hans": {"other": "%lld 个帖子"},
        "zh-Hant": {"other": "%lld 則貼文"}
      },
      "Forumind": {"shouldTranslate": false}
    }

Import fails for keys that aren't in the catalog: run
scripts/i18n/sync-catalogs.sh first so the catalog knows the code's keys.
"""
import json
import sys
from pathlib import Path

LANGUAGES = ["zh-Hans", "zh-Hant"]


def load(path):
    return json.loads(Path(path).read_text())


def save(path, catalog):
    # Xcode's own layout ("key" : value, sorted keys), so a later sync or an
    # Xcode build doesn't rewrite the whole file.
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    Path(path).write_text(text + "\n")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def localization(value):
    if isinstance(value, str):
        return unit(value)
    return {"variations": {"plural": {case: unit(text) for case, text in value.items()}}}


def is_translated(entry, language):
    loc = entry.get("localizations", {}).get(language)
    if not loc:
        return False
    units = [loc["stringUnit"]] if "stringUnit" in loc else [
        case["stringUnit"] for cases in loc.get("variations", {}).values() for case in cases.values()
    ]
    return bool(units) and all(u.get("state") == "translated" for u in units)


def export(path):
    catalog = load(path)
    todo = {}
    for key, entry in sorted(catalog["strings"].items()):
        if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
            continue
        if all(is_translated(entry, language) for language in LANGUAGES):
            continue
        item = {}
        if entry.get("comment"):
            item["comment"] = entry["comment"]
        for language in ["en"] + LANGUAGES:
            loc = entry.get("localizations", {}).get(language)
            if loc and "stringUnit" in loc:
                item[language] = loc["stringUnit"]["value"]
            elif loc and "plural" in loc.get("variations", {}):
                item[language] = {c: v["stringUnit"]["value"] for c, v in loc["variations"]["plural"].items()}
        todo[key] = item
    json.dump(todo, sys.stdout, ensure_ascii=False, indent=2)
    print()


def import_(path, translations_path):
    catalog = load(path)
    translations = load(translations_path)
    unknown = [key for key in translations if key not in catalog["strings"]]
    if unknown:
        sys.exit("Not in the catalog (sync first, or fix the key):\n" + "\n".join(f"  {k!r}" for k in unknown))
    for key, item in translations.items():
        entry = catalog["strings"][key]
        if item.get("shouldTranslate") is False:
            entry["shouldTranslate"] = False
            entry.pop("localizations", None)
            continue
        entry.pop("shouldTranslate", None)
        localizations = entry.setdefault("localizations", {})
        for language in ["en"] + LANGUAGES:
            if language in item:
                localizations[language] = localization(item[language])
    save(path, catalog)
    print(f"Imported {len(translations)} keys into {path}")


def prune(path):
    catalog = load(path)
    stale = [k for k, e in catalog["strings"].items() if e.get("extractionState") == "stale"]
    for key in stale:
        del catalog["strings"][key]
        print(f"Removed stale {key!r}")
    save(path, catalog)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "export":
        export(sys.argv[2])
    elif len(sys.argv) >= 3 and sys.argv[1] == "prune":
        prune(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "import":
        import_(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
