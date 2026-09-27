//! Converts one Adblock Plus-syntax filter list into a WebKit content rule
//! list (Safari content-blocker JSON) using adblock-rust's `content-blocking`
//! feature.
//!
//! Usage: dc-adblock-converter <list.txt> [<more.txt> ...] > rules.json
//!
//! Writes the JSON array to stdout (rule order is significant: all
//! `ignore-previous-rules` exceptions come after blocking/hiding rules) and a
//! one-line summary to stderr. Post-processing (validation, chunking,
//! manifest) lives in ../build_rules.py.

use adblock::lists::{FilterSet, ParseOptions};
use std::io::Write;

fn convert(lists: &[String]) -> (Vec<serde_json::Value>, usize, usize) {
    let mut set = FilterSet::new(true); // debug mode is required for conversion
    let mut input_filters = 0usize;
    for text in lists {
        input_filters += text
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('!') && !l.starts_with('['))
            .count();
        set.add_filter_list(text.clone(), ParseOptions::default());
    }
    let (rules, used) = set
        .into_content_blocking()
        .expect("FilterSet was created in debug mode");
    let json = rules
        .into_iter()
        .map(|r| serde_json::to_value(r).expect("CbRule serializes"))
        .collect();
    (json, used.len(), input_filters)
}

fn main() {
    let paths: Vec<String> = std::env::args().skip(1).collect();
    if paths.is_empty() {
        eprintln!("usage: dc-adblock-converter <list.txt> [...] > rules.json");
        std::process::exit(2);
    }
    let lists: Vec<String> = paths
        .iter()
        .map(|p| std::fs::read_to_string(p).unwrap_or_else(|e| panic!("read {p}: {e}")))
        .collect();
    let (rules, used, input) = convert(&lists);
    eprintln!(
        "converted {used} of {input} filters into {} content-blocking rules",
        rules.len()
    );
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    serde_json::to_writer(&mut out, &rules).expect("write JSON");
    out.write_all(b"\n").expect("write newline");
}

#[cfg(test)]
mod tests;
