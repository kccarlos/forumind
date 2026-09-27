"""Tests for scripts/adblock/build_rules.py (stdlib unittest).

Run: python3 -m unittest discover -s scripts/adblock/tests
"""

import datetime as dt
import hashlib
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import build_rules as br  # noqa: E402

HOST = r"^[^:]+:(//)?([^/]+\.)?"


def block(url, **trigger):
    return {"action": {"type": "block"}, "trigger": {"url-filter": url, **trigger}}


def exc(url, **trigger):
    return {"action": {"type": "ignore-previous-rules"}, "trigger": {"url-filter": url, **trigger}}


def hide(sel, **trigger):
    return {"action": {"type": "css-display-none", "selector": sel}, "trigger": {"url-filter": ".*", **trigger}}


def read_dir(path):
    out = {}
    for name in os.listdir(path):
        with open(os.path.join(path, name), "rb") as f:
            out[name] = f.read()
    return out


FP_DOC = exc(".*", **{"resource-type": ["document"], "load-type": ["first-party"]})


class UrlFilterSubsetTests(unittest.TestCase):
    def test_accepts_converter_patterns(self):
        for p in [
            HOST + r"ads\.example\.com",
            r"^https://x\.com/ads",
            r"ads.*\.js$",
            "/banner/.*/img",
            ".*",
            r"/addyn\|.*\|adtech;",
            "[^a-z0-9]ad[-_]?",
            "(abc)+x",
            r"a[\]]b",
        ]:
            br.validate_url_filter(p)

    def test_rejects_outside_webkit_subset(self):
        for p in [
            "",
            "a|b",
            "ab{2}",
            r"\d+",
            r"\bad",
            "(?=x)",
            "(?:x)",
            "a^b",
            "a$b",
            "*a",
            "a**",
            "a+?",
            "(a",
            "a)",
            "[abc",
            "ünï",
            "[[:alpha:]]",
            "a[]b]",
            "ab\\",
        ]:
            with self.subTest(p=p), self.assertRaises(br.RuleError):
                br.validate_url_filter(p)


class ValidateRuleTests(unittest.TestCase):
    def test_valid_rules(self):
        br.validate_rule(block("x", **{"resource-type": ["script"], "load-type": ["third-party"]}))
        br.validate_rule(hide(".ad", **{"unless-domain": ["*a.com"]}))
        br.validate_rule(exc("x", **{"if-domain": ["*b.com"]}))

    def test_invalid_rules(self):
        bad = [
            {"action": {"type": "block"}},
            {"action": {"type": "nuke"}, "trigger": {"url-filter": "x"}},
            {"action": {"type": "block"}, "trigger": {}},
            {"action": {"type": "block"}, "trigger": {"url-filter": ""}},
            {"action": {"type": "css-display-none"}, "trigger": {"url-filter": ".*"}},
            {"action": {"type": "css-display-none", "selector": " "}, "trigger": {"url-filter": ".*"}},
            block("x", **{"resource-type": []}),
            block("x", **{"resource-type": ["xmlhttprequest"]}),
            block("x", **{"load-type": ["same-site"]}),
            block("x", **{"if-domain": ["*a.com"], "unless-domain": ["*b.com"]}),
            block("x", **{"if-domain": ["*Wayfair.com"]}),
            block("x", **{"if-domain": ["*wayfair.*"]}),
            block("x", **{"if-domain": ["*[::1]"]}),
            block("x", **{"if-domain": []}),
            block("x", **{"bogus": 1}),
            block("a|b"),
        ]
        for rule in bad:
            with self.subTest(rule=rule), self.assertRaises(br.RuleError):
                br.validate_rule(rule)


class SanitizeTests(unittest.TestCase):
    def run_one(self, rule, include_site_cosmetics=False):
        stats = br.Stats()
        return br.sanitize(rule, stats, include_site_cosmetics), stats

    def test_domains_get_subdomain_wildcard_lowercase_and_punycode(self):
        out, _ = self.run_one(hide(".x", **{"if-domain": ["Example.com", "*b.org", "bücher.de"]}), True)
        self.assertEqual(out["trigger"]["if-domain"], ["*b.org", "*example.com", "*xn--bcher-kva.de"])

    def test_arrays_sorted_for_determinism(self):
        out, _ = self.run_one(block("x", **{"resource-type": ["script", "image", "raw"]}))
        self.assertEqual(out["trigger"]["resource-type"], ["image", "raw", "script"])

    def test_empty_resource_type_becomes_document(self):
        out, stats = self.run_one(block(r"\.com/smartpop/", **{"resource-type": []}))
        self.assertEqual(out["trigger"]["resource-type"], ["document"])
        self.assertEqual(sum(stats.fixed.values()), 1)

    def test_literal_caret_becomes_separator_class(self):
        out, stats = self.run_one(block(HOST + r"x\.com\^.*/ad"))
        self.assertEqual(out["trigger"]["url-filter"], HOST + r"x\.com[^a-zA-Z0-9_.%-].*/ad")
        br.validate_url_filter(out["trigger"]["url-filter"])
        out, _ = self.run_one(block(r"\^endpoint=track"))
        self.assertEqual(out["trigger"]["url-filter"], "[^a-zA-Z0-9_.%-]endpoint=track")
        out, _ = self.run_one(block(r"/ad\^"))
        self.assertEqual(out["trigger"]["url-filter"], "/ad")
        self.assertEqual(sum(stats.fixed.values()), 1)

    def test_site_specific_cosmetics_excluded_by_default(self):
        rule = hide(".x", **{"if-domain": ["a.com"]})
        self.assertIsNone(self.run_one(rule)[0])
        self.assertIsNotNone(self.run_one(rule, include_site_cosmetics=True)[0])
        # Generic hiding with #@# exceptions (unless-domain) is kept.
        self.assertIsNotNone(self.run_one(hide(".x", **{"unless-domain": ["a.com"]}))[0])
        # Domain-restricted *network* rules are kept.
        self.assertIsNotNone(self.run_one(block("x", **{"if-domain": ["a.com"]}))[0])

    def test_invalid_rule_dropped_with_reason(self):
        out, stats = self.run_one(block("ab{2}"))
        self.assertIsNone(out)
        self.assertTrue(any("invalid" in k for k in stats.dropped))

    def test_dedupe_keeps_first_occurrence(self):
        stats = br.Stats()
        rules = [block("a"), block("b"), block("a"), exc("a")]
        self.assertEqual(br.dedupe(rules, stats), [block("a"), block("b"), exc("a")])
        self.assertEqual(stats.dropped, {"duplicate": 1})


class ChunkTests(unittest.TestCase):
    def test_every_network_chunk_carries_all_exceptions_in_order(self):
        blocks = [block(f"b{i}") for i in range(25)]
        exceptions = [exc("e1"), exc("e2", **{"if-domain": ["*x.com"]}), FP_DOC]
        cosmetics = [hide(f".c{i}") for i in range(7)]
        chunks = br.build_chunks(blocks + cosmetics + exceptions, max_rules=13)
        # 25 blocks with room 10 per chunk -> 3 network chunks, then cosmetics.
        self.assertEqual([len(c) for c in chunks], [12, 11, 11, 7])
        for c in chunks[:3]:
            self.assertEqual(c[-3:], exceptions)
            self.assertTrue(all(r["action"]["type"] == "block" for r in c[:-3]))
        self.assertEqual(sum(len(c) - 3 for c in chunks[:3]), 25)
        self.assertEqual(chunks[3], cosmetics)
        # Cosmetic chunks never contain ignore-previous-rules.
        self.assertTrue(all(r["action"]["type"] == "css-display-none" for r in chunks[3]))

    def test_no_chunk_exceeds_limit(self):
        rules = [block(f"b{i}") for i in range(1000)] + [hide(f".c{i}") for i in range(1000)] + [FP_DOC]
        for c in br.build_chunks(rules, max_rules=300):
            self.assertLessEqual(len(c), 300)

    def test_encode_is_valid_json_one_rule_per_line(self):
        data = br.encode_chunk([block("a"), hide(".b")])
        self.assertEqual(json.loads(data), [block("a"), hide(".b")])
        self.assertEqual(len(data.decode().strip().splitlines()), 4)


LIST_HEADER = """[Adblock Plus 2.0]
! Version: 202609260449
! Title: {title}
! Last modified: 26 Sep 2026 04:49 UTC
! Commit: abc123
||x.com^
"""


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.inp = os.path.join(self.tmp.name, "in")
        self.out = os.path.join(self.tmp.name, "out")
        os.makedirs(self.inp)
        ads = [block(f"ad{i}", **{"resource-type": ["script", "image"]}) for i in range(30)]
        ads += [hide(f".ad{i}") for i in range(5)] + [hide(".site", **{"if-domain": ["a.com"]})]
        ads += [block("ad0", **{"resource-type": ["image", "script"]})]  # duplicate once canonical
        ads += [exc("ok"), FP_DOC]
        privacy = [block(f"t{i}") for i in range(12)] + [block("bad{2}"), FP_DOC]
        for stem, title, rules in (("easylist", "EasyList", ads), ("easyprivacy", "EasyPrivacy", privacy)):
            with open(os.path.join(self.inp, f"{stem}.txt"), "w") as f:
                f.write(LIST_HEADER.format(title=title))
            with open(os.path.join(self.inp, f"{stem}.json"), "w") as f:
                json.dump(rules, f)
        self.now = dt.datetime(2026, 9, 26, 5, 0, 0, tzinfo=dt.timezone.utc)

    def build(self, **kw):
        return br.build(self.inp, self.out, max_rules=20, now=kw.pop("now", self.now), log=lambda *_: None, **kw)

    def test_output_contract(self):
        m = self.build()
        self.assertRegex(m["version"], r"^2026-09-26-[0-9a-f]{12}$")
        self.assertEqual(m["generatedAt"], "2026-09-26T05:00:00Z")
        self.assertEqual(
            [(s["name"], s["listVersion"], s["license"]) for s in m["sources"]],
            [("EasyList", "202609260449", "CC BY-SA 3.0"), ("EasyPrivacy", "202609260449", "CC BY-SA 3.0")],
        )
        self.assertEqual(
            [(e["identifier"], e["category"], e["file"]) for e in m["lists"]],
            [
                ("ads-1", "ads", "ads-1.json"),
                ("ads-2", "ads", "ads-2.json"),
                ("ads-3", "ads", "ads-3.json"),
                ("privacy-1", "privacy", "privacy-1.json"),
            ],
        )
        shas = hashlib.sha256()
        for e in m["lists"]:
            with open(os.path.join(self.out, e["file"]), "rb") as f:
                data = f.read()
            shas.update(data)
            self.assertEqual(hashlib.sha256(data).hexdigest(), e["sha256"])
            rules = json.loads(data)
            self.assertEqual(len(rules), e["ruleCount"])
            for r in rules:
                br.validate_rule(r)
        self.assertTrue(m["version"].endswith(shas.hexdigest()[:12]))
        # Duplicate, invalid and site-specific cosmetic rules are gone.
        self.assertEqual(sum(e["ruleCount"] for e in m["lists"] if e["category"] == "privacy"), 13)
        self.assertEqual(sum(e["ruleCount"] for e in m["lists"] if e["identifier"] == "ads-3"), 5)
        with open(os.path.join(self.out, "manifest.json")) as f:
            self.assertEqual(json.load(f), m)
        with open(os.path.join(self.out, "ATTRIBUTION.md")) as f:
            text = f.read()
        self.assertIn("CC BY-SA 3.0", text)
        self.assertIn("https://creativecommons.org/licenses/by-sa/3.0/", text)
        self.assertIn("EasyPrivacy", text)
        self.assertIn(br.CONVERTER_SOURCE_URL, text)

    def test_deterministic_and_unchanged_output_is_not_rewritten(self):
        first = self.build()
        snapshot = read_dir(self.out)
        later = self.now + dt.timedelta(days=7)
        second = self.build(now=later)
        self.assertEqual(first, second)  # same version + generatedAt: no PR churn
        self.assertEqual(snapshot, read_dir(self.out))
        forced = self.build(now=later, force=True)
        self.assertEqual(forced["version"].split("-")[-1], first["version"].split("-")[-1])
        self.assertTrue(forced["version"].startswith("2026-10-03"))

    def test_changed_rules_rewrite_and_remove_stale_chunks(self):
        self.build()
        with open(os.path.join(self.inp, "easylist.json"), "w") as f:
            json.dump([block("only"), FP_DOC], f)
        m = self.build()
        self.assertEqual([e["file"] for e in m["lists"]], ["ads-1.json", "privacy-1.json"])
        self.assertEqual(
            sorted(os.listdir(self.out)), ["ATTRIBUTION.md", "ads-1.json", "manifest.json", "privacy-1.json"]
        )

    def test_header_parsing(self):
        meta = br.parse_header(LIST_HEADER.format(title="EasyList"))
        self.assertEqual(meta["Version"], "202609260449")
        self.assertEqual(meta["Last modified"], "26 Sep 2026 04:49 UTC")
        self.assertEqual(meta["Commit"], "abc123")


if __name__ == "__main__":
    unittest.main()
