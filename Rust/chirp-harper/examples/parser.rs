//! Compares reading text as plain English (what Chirp does) with reading it as Markdown.
//! Usage: `parser <file>…`. For each file: how many findings each way, by Harper's rules and Chirp's own,
//! and the findings only one of the two ways makes.
use std::collections::BTreeSet;

use chirp_harper::agreement;
use harper_core::linting::LintGroup;
use harper_core::parsers::MarkdownOptions;
use harper_core::spell::FstDictionary;
use harper_core::{Dialect, Document};

fn findings(doc: &Document, harper: &mut LintGroup, dict: &FstDictionary) -> BTreeSet<(usize, usize, String, String)> {
    let mut out = BTreeSet::new();
    for (rule, lints) in harper.organized_lints(doc) {
        for l in lints {
            out.insert((l.span.start, l.span.end, rule.clone(), doc.get_span_content_str(&l.span)));
        }
    }
    for f in agreement::check(doc, dict) {
        out.insert((f.lint.span.start, f.lint.span.end, f.rule.to_string(), doc.get_span_content_str(&f.lint.span)));
    }
    out
}

fn main() {
    let dict = FstDictionary::curated();
    let mut plain_rules = LintGroup::new_curated(dict.clone(), Dialect::American);
    let mut markdown_rules = LintGroup::new_curated(dict.clone(), Dialect::American);
    let show = std::env::var("SHOW").ok().and_then(|s| s.parse::<usize>().ok()).unwrap_or(15);
    let (mut total_plain, mut total_markdown, mut total_words) = (0, 0, 0);
    for path in std::env::args().skip(1) {
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        let chars: Vec<char> = text.chars().collect();
        let plain = findings(&Document::new_plain_english(&text, dict.as_ref()), &mut plain_rules, dict.as_ref());
        let mut options = MarkdownOptions::default();
        options.ignore_link_title = true;
        let markdown = findings(&Document::new_markdown(&text, options, dict.as_ref()), &mut markdown_rules, dict.as_ref());
        let words = text.split_whitespace().count();
        total_plain += plain.len();
        total_markdown += markdown.len();
        total_words += words;
        let only_plain: Vec<_> = plain.difference(&markdown).collect();
        let only_markdown: Vec<_> = markdown.difference(&plain).collect();
        println!("{path}: {words} words; plain {} findings, markdown {}; only plain {}, only markdown {}", plain.len(), markdown.len(), only_plain.len(), only_markdown.len());
        let context = |start: usize, end: usize| -> String {
            let a = start.saturating_sub(30);
            let b = (end + 25).min(chars.len());
            chars[a..b].iter().collect::<String>().replace('\n', "⏎")
        };
        for (start, end, rule, word) in only_plain.iter().take(show) {
            println!("  only plain    [{rule}] “{word}” …{}…", context(*start, *end));
        }
        for (start, end, rule, word) in only_markdown.iter().take(show) {
            println!("  only markdown [{rule}] “{word}” …{}…", context(*start, *end));
        }
    }
    println!("in all: {total_words} words; plain {total_plain} findings, markdown {total_markdown}");
}
