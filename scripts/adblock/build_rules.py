#!/usr/bin/env python3
"""Post-process converted filter lists into the app's bundled rule chunks.

Input (``--input-dir``), produced by update_rules.sh:
    easylist.txt / easyprivacy.txt     the downloaded ABP lists (for headers)
    easylist.json / easyprivacy.json   adblock-rust content-blocking output

Output (``--output-dir``, normally Forumind/ContentBlocking):
    ads-N.json, privacy-N.json         WebKit content rule lists (JSON arrays)
    manifest.json                      see docs/AD_BLOCKING.md ("Output contract")
    ATTRIBUTION.md                     CC BY-SA 3.0 attribution for the lists

Steps: sanitize (drop rules WebKit can't express faithfully), validate every
rule against WebKit's content-blocker schema and url-filter regex subset,
de-duplicate, split into chunks (each chunk carries every exception it needs),
hash, and write. If the chunk contents are byte-identical to what is already
committed, nothing is rewritten (so the weekly job opens no PR).

Python 3 standard library only.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import gzip
import hashlib
import json
import math
import os
import re
import sys
from dataclasses import dataclass, field

MAX_RULES_PER_CHUNK = 50_000
WEBKIT_HARD_LIMIT = 150_000
SHORT_SHA_LEN = 12
CONVERTER_SOURCE_URL = (
    "https://github.com/kccarlos/forumind/tree/main/scripts/adblock"
)


@dataclass(frozen=True)
class Source:
    name: str
    url: str
    category: str
    stem: str  # basename of the .txt / .json files in the input dir
    license: str = "CC BY-SA 3.0"


SOURCES = (
    Source("EasyList", "https://easylist.to/easylist/easylist.txt", "ads", "easylist"),
    Source(
        "EasyPrivacy",
        "https://easylist.to/easylist/easyprivacy.txt",
        "privacy",
        "easyprivacy",
    ),
)

ACTION_TYPES = {
    "block",
    "block-cookies",
    "css-display-none",
    "ignore-previous-rules",
    "make-https",
}
RESOURCE_TYPES = {
    "document",
    "image",
    "style-sheet",
    "script",
    "font",
    "raw",
    "svg-document",
    "media",
    "popup",
}  # the set every iOS 17+ WebKit accepts; newer names would fail compilation
LOAD_TYPES = {"first-party", "third-party"}
TRIGGER_KEYS = {
    "url-filter",
    "url-filter-is-case-sensitive",
    "resource-type",
    "load-type",
    "if-domain",
    "unless-domain",
    "if-top-url",
    "unless-top-url",
}
# ABP `^` separator: any char except letters, digits and `_ - . %`.
SEPARATOR_CLASS = "[^a-zA-Z0-9_.%-]"
SEPARATOR_ESCAPE_RE = re.compile(r"(?<!\\)\\\^")
DOMAIN_RE = re.compile(r"^\*?[a-z0-9_-]+(\.[a-z0-9_-]+)*\.?$")


class RuleError(ValueError):
    """A rule WebKit would reject (or that we refuse to ship)."""


# --------------------------------------------------------------------------
# WebKit url-filter regex subset
# --------------------------------------------------------------------------


def validate_url_filter(pattern: str) -> None:
    """Raise RuleError unless ``pattern`` is inside WebKit's regex subset.

    WebKit's content-extension compiler accepts: literal ASCII characters,
    escaped metacharacters (``\\.``), ``.``, character classes ``[...]``
    (ranges and leading ``^`` allowed), groups ``(...)`` without alternation,
    the quantifiers ``*``, ``+``, ``?`` and the anchors ``^`` (only at the very
    start) and ``$`` (only at the very end). Everything else — ``|``, ``{n}``,
    ``\\d``/``\\w``/``\\b``-style escapes, back-references, ``(?...)`` — fails
    compilation of the *whole* list, so it must never reach the app.
    """
    if not pattern:
        raise RuleError("empty url-filter")
    if not pattern.isascii():
        raise RuleError("non-ASCII url-filter")
    i, n = 0, len(pattern)
    depth = 0
    can_quantify = False
    while i < n:
        c = pattern[i]
        if c == "\\":
            if i + 1 >= n:
                raise RuleError("trailing backslash")
            nxt = pattern[i + 1]
            if nxt.isalnum():
                raise RuleError(f"unsupported escape \\{nxt}")
            i += 2
            can_quantify = True
            continue
        if c == "[":
            j = i + 1
            if j < n and pattern[j] == "^":
                j += 1
            if j < n and pattern[j] == "]":
                # JS/YARR semantics: `[]` is an empty class, not a literal `]`.
                raise RuleError("empty character class")
            while j < n and pattern[j] != "]":
                if pattern[j] == "\\":
                    if j + 1 >= n or pattern[j + 1].isalnum():
                        raise RuleError("unsupported escape in class")
                    j += 1
                elif pattern[j] == "[":
                    raise RuleError("nested/POSIX character class")
                j += 1
            if j >= n:
                raise RuleError("unterminated character class")
            i = j + 1
            can_quantify = True
            continue
        if c == "(":
            if pattern.startswith("(?", i):
                raise RuleError("(?...) groups are unsupported")
            depth += 1
            can_quantify = False
        elif c == ")":
            depth -= 1
            if depth < 0:
                raise RuleError("unbalanced ')'")
            can_quantify = True
        elif c in "*+?":
            if not can_quantify:
                raise RuleError(f"quantifier '{c}' without an atom")
            can_quantify = False  # no stacked/lazy quantifiers (a*? / a**)
        elif c in "{}":
            raise RuleError("{n,m} quantifiers are unsupported")
        elif c == "|":
            raise RuleError("alternation is unsupported")
        elif c == "^":
            if i != 0:
                raise RuleError("'^' anchor not at start")
            can_quantify = False
        elif c == "$":
            if i != n - 1:
                raise RuleError("'$' anchor not at end")
            can_quantify = False
        else:
            can_quantify = True
        i += 1
    if depth != 0:
        raise RuleError("unbalanced '('")


def validate_rule(rule: object) -> None:
    """Schema-ish check of one WebKit content-blocker rule."""
    if not isinstance(rule, dict) or set(rule) != {"action", "trigger"}:
        raise RuleError("rule must be {action, trigger}")
    action, trigger = rule["action"], rule["trigger"]
    if not isinstance(action, dict) or not isinstance(trigger, dict):
        raise RuleError("action/trigger must be objects")
    typ = action.get("type")
    if typ not in ACTION_TYPES:
        raise RuleError(f"unknown action type {typ!r}")
    if typ == "css-display-none":
        sel = action.get("selector")
        if not isinstance(sel, str) or not sel.strip():
            raise RuleError("css-display-none without selector")
        if set(action) != {"type", "selector"}:
            raise RuleError("unexpected action keys")
    elif set(action) != {"type"}:
        raise RuleError("unexpected action keys")

    unknown = set(trigger) - TRIGGER_KEYS
    if unknown:
        raise RuleError(f"unknown trigger keys {sorted(unknown)}")
    url_filter = trigger.get("url-filter")
    if not isinstance(url_filter, str):
        raise RuleError("missing url-filter")
    validate_url_filter(url_filter)
    for key, allowed in (("resource-type", RESOURCE_TYPES), ("load-type", LOAD_TYPES)):
        if key in trigger:
            vals = trigger[key]
            if not isinstance(vals, list) or not vals:
                raise RuleError(f"empty {key}")
            bad = [v for v in vals if v not in allowed]
            if bad:
                raise RuleError(f"invalid {key} {bad}")
    if "if-domain" in trigger and "unless-domain" in trigger:
        raise RuleError("if-domain and unless-domain together")
    for key in ("if-domain", "unless-domain"):
        if key in trigger:
            vals = trigger[key]
            if not isinstance(vals, list) or not vals:
                raise RuleError(f"empty {key}")
            for d in vals:
                if not isinstance(d, str) or not DOMAIN_RE.match(d):
                    raise RuleError(f"invalid domain {d!r} (must be lowercase ASCII)")
    if "url-filter-is-case-sensitive" in trigger and not isinstance(
        trigger["url-filter-is-case-sensitive"], bool
    ):
        raise RuleError("url-filter-is-case-sensitive must be a bool")


# --------------------------------------------------------------------------
# Sanitize / classify
# --------------------------------------------------------------------------


def _idna(domain: str) -> str:
    star = domain.startswith("*")
    host = domain[1:] if star else domain
    host = host.lower()
    if not host.isascii():
        host = host.encode("idna").decode("ascii")
    # ABP domain options (and `example.com##sel`) include subdomains; in
    # WebKit that requires the leading '*'.
    return "*" + host


def canonicalize(rule: dict) -> dict:
    """Stable key/array ordering so identical input -> identical bytes."""
    trigger = dict(rule["trigger"])
    for key in ("resource-type", "load-type"):
        if key in trigger:
            trigger[key] = sorted(set(trigger[key]))
    for key in ("if-domain", "unless-domain"):
        if key in trigger:
            trigger[key] = sorted({_idna(d) for d in trigger[key]})
    return {"action": dict(rule["action"]), "trigger": trigger}


@dataclass
class Stats:
    input_rules: int = 0
    dropped: dict = field(default_factory=dict)
    fixed: dict = field(default_factory=dict)

    def drop(self, reason: str) -> None:
        self.dropped[reason] = self.dropped.get(reason, 0) + 1


def sanitize(rule: dict, stats: Stats, include_site_cosmetics: bool) -> dict | None:
    """Return a shippable canonical rule, or None (with the reason counted)."""
    trigger = rule.get("trigger", {})
    action = rule.get("action", {})
    # adblock-rust 0.13 has no mapping for the `$document` option and emits
    # `"resource-type": []` for filters whose only types are `$document`
    # (e.g. `.com/smartpop/$document`, `@@||site^$document`). WebKit reads an
    # empty list as "every resource type", which would turn a rule meant for
    # page loads into a blanket one. Restore the intended type.
    if trigger.get("resource-type") == []:
        rule = {"action": action, "trigger": {**trigger, "resource-type": ["document"]}}
        trigger = rule["trigger"]
        stats.fixed["empty resource-type -> document ($document)"] = (
            stats.fixed.get("empty resource-type -> document ($document)", 0) + 1
        )
    # adblock-rust escapes a mid-pattern ABP separator `^` as a literal `\^`,
    # which never matches a URL (a real caret is always %5E), so those rules
    # were dead. Turn it into the separator class. (A trailing `^` is already
    # dropped by adblock-rust; "or end of URL" needs alternation WebKit lacks.)
    url_filter = trigger.get("url-filter")
    if isinstance(url_filter, str) and "\\^" in url_filter:
        fixed = SEPARATOR_ESCAPE_RE.sub(SEPARATOR_CLASS, url_filter)
        fixed = fixed[: -len(SEPARATOR_CLASS)] if fixed.endswith(SEPARATOR_CLASS) else fixed
        if fixed != url_filter:
            rule = {"action": action, "trigger": {**trigger, "url-filter": fixed}}
            trigger = rule["trigger"]
            stats.fixed["literal \\^ -> separator class"] = (
                stats.fixed.get("literal \\^ -> separator class", 0) + 1
            )
    if (
        not include_site_cosmetics
        and action.get("type") == "css-display-none"
        and "if-domain" in trigger
    ):
        stats.drop("site-specific cosmetic (excluded by default)")
        return None
    try:
        canon = canonicalize(rule)
        validate_rule(canon)
    except (RuleError, KeyError, TypeError, UnicodeError) as exc:
        stats.drop(f"invalid: {exc}")
        return None
    return canon


def rule_key(rule: dict) -> str:
    return json.dumps(rule, sort_keys=True, separators=(",", ":"))


def dedupe(rules: list[dict], stats: Stats) -> list[dict]:
    seen: set[str] = set()
    out = []
    for r in rules:
        k = rule_key(r)
        if k in seen:
            stats.drop("duplicate")
            continue
        seen.add(k)
        out.append(r)
    return out


# --------------------------------------------------------------------------
# Chunking
# --------------------------------------------------------------------------


def split_even(items: list, n: int) -> list[list]:
    size, extra = divmod(len(items), n)
    out, start = [], 0
    for i in range(n):
        end = start + size + (1 if i < extra else 0)
        out.append(items[start:end])
        start = end
    return out


def build_chunks(rules: list[dict], max_rules: int = MAX_RULES_PER_CHUNK) -> list[list[dict]]:
    """Split one category's converted rules into independent rule lists.

    WebKit evaluates every compiled rule list on its own: an
    ``ignore-previous-rules`` exception only cancels earlier rules *of the
    same list*. So:

    * network block rules are sliced evenly, and every slice gets the full
      exception tail (all ignore-previous-rules, in source order, including
      the catch-all first-party-document exception) appended;
    * cosmetic (css-display-none) rules go in their own chunk(s) with no
      ignore-previous-rules at all, so a network exception (notably the
      ``.*``/document one, which matches every top-level page load) can never
      cancel element hiding.
    """
    blocks = [r for r in rules if r["action"]["type"] not in ("css-display-none", "ignore-previous-rules")]
    exceptions = [r for r in rules if r["action"]["type"] == "ignore-previous-rules"]
    cosmetics = [r for r in rules if r["action"]["type"] == "css-display-none"]

    chunks: list[list[dict]] = []
    if blocks:
        room = max_rules - len(exceptions)
        if room <= 0:
            raise SystemExit(f"{len(exceptions)} exceptions leave no room in a {max_rules}-rule chunk")
        for part in split_even(blocks, math.ceil(len(blocks) / room)):
            chunks.append(part + exceptions)
    if cosmetics:
        chunks.extend(split_even(cosmetics, math.ceil(len(cosmetics) / max_rules)))
    for c in chunks:
        assert 0 < len(c) <= min(max_rules, WEBKIT_HARD_LIMIT)
    return chunks


def encode_chunk(rules: list[dict]) -> bytes:
    """One rule per line: compact, deterministic and diff-friendly."""
    lines = [json.dumps(r, sort_keys=True, separators=(",", ":"), ensure_ascii=True) for r in rules]
    return ("[\n" + ",\n".join(lines) + "\n]\n").encode("ascii")


# --------------------------------------------------------------------------
# List headers, manifest, attribution
# --------------------------------------------------------------------------


def parse_header(text: str) -> dict:
    meta = {}
    for line in text.splitlines()[:60]:
        m = re.match(r"^!\s*(Version|Last modified|Commit|Title|Homepage):\s*(.+?)\s*$", line)
        if m:
            meta.setdefault(m.group(1), m.group(2))
    return meta


def content_sha(encoded: list[bytes]) -> str:
    h = hashlib.sha256()
    for data in encoded:
        h.update(data)
    return h.hexdigest()


def attribution_text(sources: list[dict]) -> str:
    rows = "\n".join(
        f"- **{s['name']}** — <{s['url']}> (list version {s['listVersion']}"
        + (f", last modified {s['lastModified']}" if s.get("lastModified") else "")
        + ")"
        for s in sources
    )
    return f"""# Content blocking rules — attribution

The `ads-*.json` and `privacy-*.json` files in this directory are **derived
from** the following filter lists, written by **The EasyList authors**
(<https://easylist.to/>):

{rows}

EasyList and EasyPrivacy are dual-licensed under GPLv3 and the Creative Commons
Attribution-ShareAlike 3.0 Unported license; this app uses them under
**CC BY-SA 3.0** (<https://creativecommons.org/licenses/by-sa/3.0/>). See
<https://easylist.to/pages/licence.html>.

**Changes made:** the filters were mechanically converted from Adblock Plus
syntax to WebKit content-blocker JSON, filters WebKit cannot express were
omitted, and the result was split into several files. These converted files are
a derivative work and are shared under the same license, **CC BY-SA 3.0**.

The conversion tooling (source) is at <{CONVERTER_SOURCE_URL}>; it uses
Brave's adblock-rust (MPL-2.0) at build time only.
"""


def load_existing_manifest(out_dir: str) -> dict | None:
    try:
        with open(os.path.join(out_dir, "manifest.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


CHUNK_FILE_RE = re.compile(r"^(ads|privacy)-\d+\.json$")


def build(
    input_dir: str,
    output_dir: str,
    *,
    include_site_cosmetics: bool = False,
    max_rules: int = MAX_RULES_PER_CHUNK,
    force: bool = False,
    now: _dt.datetime | None = None,
    log=print,
) -> dict:
    now = now or _dt.datetime.now(_dt.timezone.utc)
    sources_meta = []
    planned = []  # (identifier, category, filename, rules, bytes)
    total_stats = []
    for src in SOURCES:
        with open(os.path.join(input_dir, f"{src.stem}.txt"), encoding="utf-8") as f:
            header = parse_header(f.read())
        with open(os.path.join(input_dir, f"{src.stem}.json"), encoding="utf-8") as f:
            converted = json.load(f)
        if not isinstance(converted, list):
            raise SystemExit(f"{src.stem}.json is not a JSON array")
        stats = Stats(input_rules=len(converted))
        cleaned = [r for r in (sanitize(r, stats, include_site_cosmetics) for r in converted) if r]
        cleaned = dedupe(cleaned, stats)
        if not cleaned:
            raise SystemExit(f"{src.name}: no rules survived conversion")
        chunks = build_chunks(cleaned, max_rules)
        for i, rules in enumerate(chunks, 1):
            ident = f"{src.category}-{i}"
            planned.append((ident, src.category, f"{ident}.json", rules, encode_chunk(rules)))
        total_stats.append((src, stats, len(cleaned)))
        meta = {
            "name": src.name,
            "url": src.url,
            "listVersion": header.get("Version", "unknown"),
            "license": src.license,
        }
        if "Last modified" in header:
            meta["lastModified"] = header["Last modified"]
        if "Commit" in header:
            meta["commit"] = header["Commit"]
        sources_meta.append(meta)

    sha = content_sha([p[4] for p in planned])
    version = f"{now:%Y-%m-%d}-{sha[:SHORT_SHA_LEN]}"
    lists = [
        {
            "identifier": ident,
            "category": cat,
            "file": fname,
            "ruleCount": len(rules),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
        for ident, cat, fname, rules, data in planned
    ]

    for src, stats, kept in total_stats:
        log(f"{src.name}: {stats.input_rules} converted rules -> {kept} unique shippable rules")
        for reason, count in sorted(stats.dropped.items(), key=lambda kv: -kv[1]):
            log(f"    dropped {count:6d}  {reason}")
        for reason, count in sorted(stats.fixed.items()):
            log(f"    fixed   {count:6d}  {reason}")
    raw = sum(len(p[4]) for p in planned)
    gz = sum(len(gzip.compress(p[4], 9, mtime=0)) for p in planned)
    for entry in lists:
        size = len(next(p[4] for p in planned if p[0] == entry["identifier"]))
        log(f"  {entry['file']:<16} {entry['ruleCount']:6d} rules  {size / 1e6:6.2f} MB")
    log(f"  total: {sum(e['ruleCount'] for e in lists)} rules, {raw / 1e6:.2f} MB raw, {gz / 1e6:.2f} MB gzip")

    existing = load_existing_manifest(output_dir)
    if (
        not force
        and existing
        and existing.get("version", "").endswith("-" + sha[:SHORT_SHA_LEN])
        and [(e.get("file"), e.get("sha256")) for e in existing.get("lists", [])]
        == [(e["file"], e["sha256"]) for e in lists]
        and all(
            os.path.exists(os.path.join(output_dir, e["file"])) for e in lists
        )
    ):
        log(f"rules unchanged ({existing['version']}); nothing written")
        return existing

    manifest = {
        "version": version,
        "generatedAt": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "sources": sources_meta,
        "lists": lists,
    }
    os.makedirs(output_dir, exist_ok=True)
    for name in os.listdir(output_dir):
        if CHUNK_FILE_RE.match(name):
            os.remove(os.path.join(output_dir, name))
    for _, _, fname, _, data in planned:
        with open(os.path.join(output_dir, fname), "wb") as f:
            f.write(data)
    with open(os.path.join(output_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=False)
        f.write("\n")
    with open(os.path.join(output_dir, "ATTRIBUTION.md"), "w", encoding="utf-8") as f:
        f.write(attribution_text(sources_meta))
    log(f"wrote {len(lists)} rule lists, version {version}")
    return manifest


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input-dir", required=True)
    p.add_argument("--output-dir", required=True)
    p.add_argument("--max-rules", type=int, default=MAX_RULES_PER_CHUNK)
    p.add_argument(
        "--include-site-cosmetics",
        action="store_true",
        help="also ship domain-specific element-hiding rules (example.com##sel)",
    )
    p.add_argument("--force", action="store_true", help="rewrite outputs even if unchanged")
    args = p.parse_args(argv)
    build(
        args.input_dir,
        args.output_dir,
        include_site_cosmetics=args.include_site_cosmetics,
        max_rules=args.max_rules,
        force=args.force,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
