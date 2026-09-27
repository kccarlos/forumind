//! Syntax-case tests: tiny ABP snippets -> expected content-blocking shape.
//! These pin down adblock-rust's behaviour for the syntax we rely on, so a
//! crate bump that changes it fails CI instead of silently changing the app.

use super::convert;
use serde_json::{json, Value};

fn rules(lines: &[&str]) -> Vec<Value> {
    convert(&[lines.join("\n")]).0
}

/// All rules except the trailing catch-all first-party-document exception.
fn body(lines: &[&str]) -> Vec<Value> {
    let mut r = rules(lines);
    if r.last() == Some(&fp_document_exception()) {
        r.pop();
    }
    r
}

fn fp_document_exception() -> Value {
    json!({"action": {"type": "ignore-previous-rules"},
           "trigger": {"url-filter": ".*", "resource-type": ["document"], "load-type": ["first-party"]}})
}

fn one(line: &str) -> Value {
    let r = body(&[line]);
    assert_eq!(r.len(), 1, "{line} -> {r:?}");
    r.into_iter().next().unwrap()
}

fn assert_dropped(line: &str) {
    let r = rules(&[line]);
    assert!(r.is_empty(), "{line} should not convert, got {r:?}");
}

const HOST_PREFIX: &str = r"^[^:]+:(//)?([^/]+\.)?";

#[test]
fn domain_anchor() {
    let r = one("||ads.example.com^");
    assert_eq!(r["action"]["type"], "block");
    assert_eq!(r["trigger"]["url-filter"], format!(r"{HOST_PREFIX}ads\.example\.com"));
}

#[test]
fn start_end_anchor_wildcard_separator() {
    assert_eq!(one("|https://x.com/ads")["trigger"]["url-filter"], r"^https://x\.com/ads");
    assert_eq!(one("ads*.js|")["trigger"]["url-filter"], r"ads.*\.js$");
    assert_eq!(one("/banner/*/img^")["trigger"]["url-filter"], "/banner/.*/img");
}

#[test]
fn mid_pattern_separator_is_escaped_literally() {
    // adblock-rust 0.13 emits `\^` (a literal caret that never matches);
    // build_rules.py rewrites it to a separator character class.
    assert_eq!(one("||x.com^*/ad")["trigger"]["url-filter"], format!(r"{HOST_PREFIX}x\.com\^.*/ad"));
}

#[test]
fn third_party_load_type() {
    assert_eq!(one("||t.com^$third-party")["trigger"]["load-type"], json!(["third-party"]));
    assert_eq!(one("||t.com^$~third-party")["trigger"]["load-type"], json!(["first-party"]));
}

#[test]
fn domain_option_if_and_unless() {
    let r = one("||a.com^$domain=b.com|c.org");
    let mut d: Vec<String> = serde_json::from_value(r["trigger"]["if-domain"].clone()).unwrap();
    d.sort();
    assert_eq!(d, vec!["*b.com", "*c.org"]);
    assert_eq!(one("||a.com^$domain=~b.com")["trigger"]["unless-domain"], json!(["*b.com"]));
    // WebKit can't mix if-domain and unless-domain in one rule: dropped.
    assert_dropped("||a.com^$domain=b.com|~sub.b.com");
}

#[test]
fn resource_types() {
    let cases = [
        ("script", "script"),
        ("image", "image"),
        ("stylesheet", "style-sheet"),
        ("xmlhttprequest", "raw"),
        ("media", "media"),
        ("font", "font"),
    ];
    for (abp, cb) in cases {
        let r = one(&format!("||r.com^${abp}"));
        assert_eq!(r["trigger"]["resource-type"], json!([cb]), "{abp}");
    }
    // $subdocument maps to `document` (the trailing first-party-document
    // exception keeps top-level/first-party page loads working).
    let r = one("||r.com^$subdocument");
    assert_eq!(r["trigger"]["resource-type"], json!(["document"]));
    // Negated types: everything else, with documents split out as third-party.
    let r = body(&["||r.com^$~script"]);
    assert_eq!(r.len(), 2, "{r:?}");
    assert!(!r[0]["trigger"]["resource-type"].as_array().unwrap().contains(&json!("script")));
}

#[test]
fn document_option_has_no_resource_type() {
    // adblock-rust emits an empty resource-type list for `$document`;
    // build_rules.py rewrites it to ["document"] (WebKit reads [] as "all").
    assert_eq!(one(".com/smartpop/$document")["trigger"]["resource-type"], json!([]));
    assert_eq!(one("@@||ok.com^$document")["trigger"]["resource-type"], json!([]));
}

#[test]
fn popup_is_dropped() {
    // WKWebView has no popup resource type we can rely on; not converted.
    assert_dropped("/x.php?u=$popup");
    assert_dropped("||p.com^$popup,third-party");
}

#[test]
fn exceptions_come_after_blocks() {
    let r = rules(&["@@||good.com^", "||bad.com^", "##.ad", "||bad2.com^$script"]);
    let types: Vec<&str> = r.iter().map(|x| x["action"]["type"].as_str().unwrap()).collect();
    assert_eq!(
        types,
        vec!["block", "block", "css-display-none", "ignore-previous-rules", "ignore-previous-rules"]
    );
    assert_eq!(r[3]["trigger"]["url-filter"], format!(r"{HOST_PREFIX}good\.com"));
    assert_eq!(r[4], fp_document_exception());
}

#[test]
fn important_and_match_case() {
    // $important converts, but WebKit has no priority: exceptions still win.
    assert_eq!(one("||imp.com^$important")["action"]["type"], "block");
    // $match-case filters are skipped by adblock-rust 0.13 (rare in EasyList).
    assert_dropped("/AdServe/$match-case");
}

#[test]
fn element_hiding() {
    let g = one("##.ad-banner");
    assert_eq!(g, json!({"action": {"type": "css-display-none", "selector": ".ad-banner"},
                         "trigger": {"url-filter": ".*"}}));
    let d = one("example.com##.sidebar-ad");
    assert_eq!(d["trigger"]["if-domain"], json!(["example.com"])); // '*' added in build_rules.py
    let u = one("~example.com##.x");
    assert_eq!(u["trigger"]["unless-domain"], json!(["example.com"]));
    // Generic hide + #@# exception becomes one rule with unless-domain.
    let r = body(&["##.y", "example.com#@#.y"]);
    assert!(r.iter().any(|x| x["trigger"]["unless-domain"] == json!(["example.com"])), "{r:?}");
}

#[test]
fn invalid_css_selector_is_dropped() {
    assert_dropped("##div[[broken");
}

#[test]
fn unsupported_syntax_is_dropped() {
    for line in [
        "example.com##+js(abort-on-property-read, x)",
        "example.com#$#abort-on-property-read x",
        "example.com##.a:-abp-contains(Ad)",
        "||r.com^$redirect=noopjs",
        "||c.com^$csp=script-src 'none'",
        "||rp.com^$removeparam=utm_source",
        "@@||gh.com^$generichide",
        "/ab{2}c/",
        "/foo|bar/",
        "! comment",
        "[Adblock Plus 2.0]",
    ] {
        assert_dropped(line);
    }
}

#[test]
fn non_ascii_hosts_are_punycoded() {
    let r = one("||exämple.com/ad^");
    assert_eq!(r["trigger"]["url-filter"], format!(r"{HOST_PREFIX}xn--exmple-cua\.com/ad"));
}
