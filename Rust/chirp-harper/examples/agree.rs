//! Runs Chirp's agreement checks over a file, for tuning them. Usage: `agree <mode> <file>`.
//! `agree set <file>`: lines of "W<tab>sentence" (wrong) or "R<tab>sentence" (right); prints the score,
//! and how many of the wrong ones Harper's own rules catch.
//! `agree text <file>` (or any other mode name): prose that is assumed correct; prints everything our
//! rules flag in it.
//! `agree harper <file>`: what Harper's own rules flag, line by line.
//! `agree tags <file>`: each line's words with the part-of-speech tag Harper gave them.
//! `agree words <file>`: each word with what the dictionary says about it.
use chirp_harper::agreement;
use harper_core::linting::{LintGroup, Linter};
use harper_core::spell::FstDictionary;
use harper_core::{Dialect, Document};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: agree <set|text|harper|tags|words> <file>");
        std::process::exit(2);
    }
    let dict = FstDictionary::curated();
    let text = std::fs::read_to_string(&args[2]).unwrap();
    if args[1] == "harper" {
        let mut harper = LintGroup::new_curated(dict.clone(), Dialect::American);
        for line in text.lines() {
            let doc = Document::new_plain_english(line, dict.as_ref());
            for (rule, lints) in harper.organized_lints(&doc) {
                for l in lints {
                    println!("{line} => [{rule}] “{}” {:?} :: {}", doc.get_span_content_str(&l.span), l.suggestions.iter().take(6).map(|s| s.to_string()).collect::<Vec<_>>(), l.message);
                }
            }
        }
        return;
    }
    if args[1] == "tags" {
        for line in text.lines() {
            let doc = Document::new_plain_english(line, dict.as_ref());
            let mut parts = vec![];
            for t in doc.get_tokens() {
                if let harper_core::TokenKind::Word(Some(m)) = &t.kind {
                    let tag = m.pos_tag.map(|p| format!("{p:?}")).unwrap_or("-".into());
                    parts.push(format!("{}/{}{}", doc.get_span_content_str(&t.span), tag, if m.np_member == Some(true) { "*" } else { "" }));
                }
            }
            println!("{}", parts.join(" "));
        }
        return;
    }
    if args[1] == "words" {
        let doc = Document::new_plain_english(&text, dict.as_ref());
        for t in doc.get_tokens() {
            let k = &t.kind;
            if !k.is_word() { continue; }
            let mut f = vec![];
            if k.is_noun() { f.push("noun") } if k.is_singular_noun() { f.push("sg") } if k.is_plural_noun() { f.push("pl") }
            if k.is_proper_noun() { f.push("proper") } if k.is_possessive_nominal() { f.push("poss") } if k.is_pronoun() { f.push("pron") }
            if k.is_adjective() { f.push("adj") } if k.is_adverb() { f.push("adv") } if k.is_determiner() { f.push("det") }
            if k.is_preposition() { f.push("prep") } if k.is_conjunction() { f.push("conj") } if k.is_auxiliary_verb() { f.push("aux") }
            if k.is_verb_lemma() { f.push("lemma") } if k.is_verb_third_person_singular_present_form() { f.push("3ps") }
            if k.is_verb_past_form() { f.push("past") } if k.is_verb_progressive_form() { f.push("ing") }
            println!("{:14} {}", doc.get_span_content_str(&t.span), f.join(" "));
        }
        return;
    }
    if args[1] == "open" || args[1] == "prefixes" {
        // "open": the text with lines that have no full stop counted as finished too; prints what that adds.
        // "prefixes": every sentence of the file cut off after 3, 4, 5… words, as it is while being typed;
        // prints how many of those unfinished pieces get a flag that the whole sentence does not.
        if args[1] == "open" {
            let doc = Document::new_plain_english(&text, dict.as_ref());
            let closed: std::collections::BTreeSet<(usize, usize)> = agreement::check_lines(&doc, dict.as_ref(), false).iter().map(|f| (f.lint.span.start, f.lint.span.end)).collect();
            let all = agreement::check_lines(&doc, dict.as_ref(), true);
            let src = doc.get_source();
            let mut added = 0;
            for f in &all {
                if closed.contains(&(f.lint.span.start, f.lint.span.end)) { continue; }
                added += 1;
                let a = f.lint.span.start.saturating_sub(50);
                let b = (f.lint.span.end + 40).min(src.len());
                println!("[{}] {} :: …{}…", f.rule, doc.get_span_content_str(&f.lint.span), src[a..b].iter().collect::<String>().replace('\n', "⏎"));
            }
            println!("{} flags with full stops only, {} more on lines without one, in {} words", closed.len(), added, text.split_whitespace().count());
        } else {
            let (mut pieces, mut flagged) = (0, 0);
            for sentence in text.split(|c| c == '.' || c == '!' || c == '?' || c == '\n') {
                let words: Vec<&str> = sentence.split_whitespace().collect();
                if words.len() < 4 { continue; }
                let whole = format!("{}.", words.join(" "));
                let doc = Document::new_plain_english(&whole, dict.as_ref());
                let right: Vec<String> = agreement::check(&doc, dict.as_ref()).iter().map(|f| doc.get_span_content_str(&f.lint.span)).collect();
                for n in 3..words.len() {
                    let piece = words[..n].join(" ");
                    let doc = Document::new_plain_english(&piece, dict.as_ref());
                    pieces += 1;
                    let found: Vec<String> = agreement::check_lines(&doc, dict.as_ref(), true).iter().map(|f| doc.get_span_content_str(&f.lint.span)).filter(|w| !right.contains(w)).collect();
                    if !found.is_empty() {
                        flagged += 1;
                        if flagged <= 40 { println!("{piece} => {found:?}"); }
                    }
                }
            }
            println!("{flagged} of {pieces} unfinished pieces flagged where the whole sentence is not");
        }
        return;
    }
    if args[1] == "set" {
        let mut harper = LintGroup::new_curated(dict.clone(), Dialect::American);
        let (mut ours, mut theirs, mut either, mut wrong, mut alarms, mut right) = (0, 0, 0, 0, 0, 0);
        for line in text.lines() {
            let Some((kind, s)) = line.split_once('\t') else { continue };
            let doc = Document::new_plain_english(s, dict.as_ref());
            let found = agreement::check(&doc, dict.as_ref());
            let h = harper.lint(&doc).len();
            let desc: Vec<String> = found
                .iter()
                .map(|f| format!("{}: {} -> {:?}", f.rule, doc.get_span_content_str(&f.lint.span), f.lint.suggestions.first().map(|s| s.to_string())))
                .collect();
            if kind == "W" {
                wrong += 1;
                ours += usize::from(!found.is_empty());
                theirs += usize::from(h > 0);
                either += usize::from(h > 0 || !found.is_empty());
                println!("{} {} => {}", if !found.is_empty() { "OURS  " } else if h > 0 { "harper" } else { "MISS  " }, s, desc.join(" | "));
            } else {
                right += 1;
                if !found.is_empty() {
                    alarms += 1;
                    println!("FALSE ALARM {} => {}", s, desc.join(" | "));
                }
            }
        }
        println!("ours {ours}, harper {theirs}, together {either} of {wrong}; our false alarms {alarms} of {right}");
    } else {
        let doc = Document::new_plain_english(&text, dict.as_ref());
        let found = agreement::check(&doc, dict.as_ref());
        let src = doc.get_source();
        for f in &found {
            let a = f.lint.span.start.saturating_sub(60);
            let b = (f.lint.span.end + 40).min(src.len());
            let ctx: String = src[a..b].iter().collect::<String>().replace('\n', " ");
            println!("[{}] {} -> {:?} :: …{}…", f.rule, doc.get_span_content_str(&f.lint.span), f.lint.suggestions.first().map(|s| s.to_string()), ctx);
        }
        let words = text.split_whitespace().count();
        println!("{} flags in {} words", found.len(), words);
    }
}
