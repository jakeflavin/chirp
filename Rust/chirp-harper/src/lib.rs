//! A small C interface over harper-core (Apache-2.0) so Swift can run grammar and spelling checks.
//! All offsets returned are UTF-16 code unit offsets, matching NSString / Accessibility ranges.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

use harper_core::linting::{LintGroup, Suggestion};
use harper_core::spell::{FstDictionary, MergedDictionary, MutableDictionary};
use harper_core::{Dialect, DictWordMetadata, Document};
use serde_json::json;

pub mod agreement;

/// One checker: Harper's rules plus the dictionary they were built with. Building the rules is the slow
/// part, so Swift makes one and keeps it until the user's words or spelling variant change.
/// It must not be used from two threads at once.
pub struct Checker {
    /// Harper's own words plus the user's. Kept because every text is parsed against it.
    dictionary: Arc<MergedDictionary>,
    linter: LintGroup,
    /// British spelling, not American. Kept so the rules can be built again after a failure.
    british: bool,
}

/// Copies a C string into a Rust one. A null pointer reads as empty text, and bytes that are not valid
/// UTF-8 are replaced, so neither can crash the check.
fn read(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

/// Harper's full set of rules for one spelling variant.
fn new_linter(dictionary: &Arc<MergedDictionary>, british: bool) -> LintGroup {
    let dialect = if british { Dialect::British } else { Dialect::American };
    LintGroup::new_curated(dictionary.clone(), dialect)
}

/// Builds a checker. `words` are the user's own words, one per line.
fn build(british: bool, words: &str) -> Checker {
    let mut user = MutableDictionary::new();
    for w in words.lines() {
        let w = w.trim();
        if !w.is_empty() {
            user.append_word_str(w, DictWordMetadata::default());
            // Accept the lowercase form too, so "Kubernetes" also allows "kubernetes".
            let lower = w.to_lowercase();
            if lower != w {
                user.append_word_str(&lower, DictWordMetadata::default());
            }
        }
    }
    let mut merged = MergedDictionary::new();
    merged.add_dictionary(FstDictionary::curated());
    merged.add_dictionary(Arc::new(user));
    let dictionary = Arc::new(merged);
    let linter = new_linter(&dictionary, british);
    Checker { dictionary, linter, british }
}

/// One suggested fix, as Swift reads it.
fn suggestion_json(suggestion: &Suggestion) -> serde_json::Value {
    match suggestion {
        Suggestion::ReplaceWith(c) => json!({"kind": "replace", "text": c.iter().collect::<String>()}),
        Suggestion::InsertAfter(c) => json!({"kind": "insert", "text": c.iter().collect::<String>()}),
        Suggestion::Remove => json!({"kind": "remove", "text": ""}),
    }
}

/// Lints `text` with Harper's rules and Chirp's own, and returns the JSON array described on
/// `chirp_checker_lint`.
fn lint_json(checker: &mut Checker, text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    // Prefix sums of UTF-16 lengths, so char indices map to UTF-16 offsets.
    let mut utf16 = Vec::with_capacity(chars.len() + 1);
    let mut acc = 0usize;
    utf16.push(0);
    for c in &chars {
        acc += c.len_utf16();
        utf16.push(acc);
    }

    let document = Document::new_plain_english(text, checker.dictionary.as_ref());
    let mut out = Vec::new();
    // The span of every Harper finding, in UTF-16 offsets.
    let mut taken: Vec<(usize, usize)> = Vec::new();
    for (rule, lints) in checker.linter.organized_lints(&document) {
        for lint in lints {
            let start = utf16[lint.span.start.min(chars.len())];
            let end = utf16[lint.span.end.min(chars.len())];
            let suggestions: Vec<_> = lint.suggestions.iter().map(suggestion_json).collect();
            taken.push((start, end));
            out.push(json!({
                "start": start,
                "end": end,
                "rule": rule,
                "kind": format!("{:?}", lint.lint_kind),
                "message": lint.message,
                "priority": lint.priority,
                "suggestions": suggestions,
            }));
        }
    }
    // Chirp's own agreement checks, for what Harper has no rule for. Where Harper flags exactly the same
    // words, its finding is the one kept. Findings that only overlap are both sent: Swift decides between
    // them after it has dropped the ones the user dismissed, so a dropped Harper finding cannot hide ours.
    for found in agreement::check(&document, checker.dictionary.as_ref()) {
        let start = utf16[found.lint.span.start.min(chars.len())];
        let end = utf16[found.lint.span.end.min(chars.len())];
        if taken.contains(&(start, end)) {
            continue;
        }
        let suggestions: Vec<_> = found.lint.suggestions.iter().map(suggestion_json).collect();
        out.push(json!({
            "start": start,
            "end": end,
            "rule": found.rule,
            "kind": "Agreement",
            "message": found.lint.message,
            "priority": found.lint.priority,
            "suggestions": suggestions,
        }));
    }
    serde_json::to_string(&out).unwrap_or_else(|_| "[]".into())
}

/// Creates a checker. `dialect`: 0 American, 1 British. `words`: newline-separated words to accept.
/// Returns null if the checker could not be built.
#[no_mangle]
pub extern "C" fn chirp_checker_new(dialect: u8, words: *const c_char) -> *mut Checker {
    let words = read(words);
    // A failure inside Harper must not cross into Swift, where it would end the app.
    let built = catch_unwind(AssertUnwindSafe(|| Box::into_raw(Box::new(build(dialect == 1, &words)))));
    built.unwrap_or(std::ptr::null_mut())
}

/// Frees a checker made by `chirp_checker_new`. Null is ignored. The pointer must not be used again.
#[no_mangle]
pub extern "C" fn chirp_checker_free(ptr: *mut Checker) {
    if !ptr.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(ptr) })));
    }
}

/// Lints `text` and returns a JSON array. Free the result with `chirp_string_free`.
/// Each entry has `start` and `end` (UTF-16 offsets into `text`), `rule`, `kind`, `message`, `priority`
/// and `suggestions` (each a `kind` of "replace", "insert" or "remove", and its `text`).
/// `ptr` must be a live checker from `chirp_checker_new`, or null, which gives an empty array.
/// If Harper fails on a text, the result is an empty array and the rules are built afresh for the next call.
#[no_mangle]
pub extern "C" fn chirp_checker_lint(ptr: *mut Checker, text: *const c_char) -> *mut c_char {
    let json = if ptr.is_null() {
        "[]".to_string()
    } else {
        let checker = unsafe { &mut *ptr };
        let text = read(text);
        // A failure inside Harper must not cross into Swift, where it would end the app.
        let result = catch_unwind(AssertUnwindSafe(|| lint_json(checker, &text)));
        match result {
            Ok(json) => json,
            Err(_) => {
                // The rules may have been left half-updated: replace them.
                let _ = catch_unwind(AssertUnwindSafe(|| {
                    checker.linter = new_linter(&checker.dictionary, checker.british);
                }));
                "[]".to_string()
            }
        }
    };
    CString::new(json).unwrap_or_default().into_raw()
}

/// Frees a string returned by `chirp_checker_lint`. Null is ignored. Swift must not free it any other
/// way: the memory belongs to Rust's allocator.
#[no_mangle]
pub extern "C" fn chirp_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(unsafe { CString::from_raw(ptr) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The findings for `text`, parsed back from the JSON Swift would get.
    fn lint(checker: &mut Checker, text: &str) -> Vec<serde_json::Value> {
        serde_json::from_str(&lint_json(checker, text)).expect("the result is a JSON array")
    }

    /// Whether any finding covers exactly these UTF-16 offsets.
    fn has_span(found: &[serde_json::Value], start: u64, end: u64) -> bool {
        found.iter().any(|f| f["start"].as_u64() == Some(start) && f["end"].as_u64() == Some(end))
    }

    /// Whether any finding of this kind ("Spelling", "Agreement"…) covers exactly these UTF-16 offsets.
    fn has_kind_at(found: &[serde_json::Value], kind: &str, start: u64, end: u64) -> bool {
        found.iter().any(|f| f["kind"] == kind && f["start"].as_u64() == Some(start) && f["end"].as_u64() == Some(end))
    }

    #[test]
    fn empty_text_gives_an_empty_array() {
        let mut checker = build(false, "");
        assert_eq!(lint_json(&mut checker, ""), "[]");
    }

    #[test]
    fn null_pointers_are_safe() {
        let raw = chirp_checker_lint(std::ptr::null_mut(), std::ptr::null());
        assert_eq!(unsafe { CStr::from_ptr(raw) }.to_str(), Ok("[]"));
        chirp_string_free(raw);
        chirp_string_free(std::ptr::null_mut());
        chirp_checker_free(std::ptr::null_mut());
    }

    #[test]
    fn the_c_interface_round_trips() {
        let checker = chirp_checker_new(0, std::ptr::null());
        assert!(!checker.is_null());
        let text = CString::new("We was late.").unwrap();
        let raw = chirp_checker_lint(checker, text.as_ptr());
        let json = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_string();
        chirp_string_free(raw);
        chirp_checker_free(checker);
        let found: Vec<serde_json::Value> = serde_json::from_str(&json).unwrap();
        // "was" is at 3..6, whichever of Harper's rules or ours reports it.
        assert!(has_span(&found, 3, 6), "{json}");
    }

    #[test]
    fn suggestions_keep_their_kind() {
        assert_eq!(suggestion_json(&Suggestion::ReplaceWith(vec!['a', 'b'])), json!({"kind": "replace", "text": "ab"}));
        assert_eq!(suggestion_json(&Suggestion::InsertAfter(vec![','])), json!({"kind": "insert", "text": ","}));
        assert_eq!(suggestion_json(&Suggestion::Remove), json!({"kind": "remove", "text": ""}));
    }

    /// An emoji is one character but two UTF-16 units, so everything after it is one further along for
    /// Swift than for Harper. "was" is characters 14..17 and UTF-16 offsets 15..18.
    #[test]
    fn offsets_count_utf16_units_after_an_emoji() {
        let mut checker = build(false, "");
        let found = lint(&mut checker, "Café 🙂 ok. We was late.");
        assert!(has_span(&found, 15, 18), "{found:?}");
        assert!(!has_span(&found, 14, 17), "{found:?}");
    }

    /// Depends on Harper flagging "teh" as a misspelling.
    #[test]
    fn offsets_of_a_misspelling_after_an_emoji() {
        let mut checker = build(false, "");
        let found = lint(&mut checker, "🙂 teh cat sat.");
        assert!(has_kind_at(&found, "Spelling", 3, 6), "{found:?}");
    }

    /// Depends on Harper flagging an unknown name as a misspelling.
    #[test]
    fn an_unknown_word_is_flagged_without_the_users_dictionary() {
        let mut checker = build(false, "");
        let found = lint(&mut checker, "Ask Zorblax tomorrow.");
        assert!(has_kind_at(&found, "Spelling", 4, 11), "{found:?}");
    }

    #[test]
    fn the_users_words_are_accepted() {
        let mut checker = build(false, "Zorblax\n\n  Qwyzzle  \n");
        let found = lint(&mut checker, "Ask Zorblax and Qwyzzle tomorrow.");
        assert!(!found.iter().any(|f| f["kind"] == "Spelling"), "{found:?}");
    }

    #[test]
    fn the_lowercase_form_of_a_users_word_is_accepted() {
        let mut checker = build(false, "Zorblax");
        let found = lint(&mut checker, "We use zorblax every day.");
        assert!(!has_kind_at(&found, "Spelling", 7, 14), "{found:?}");
    }

    #[test]
    fn british_spelling_is_accepted_when_asked_for() {
        let mut checker = build(true, "");
        let found = lint(&mut checker, "The colour is nice.");
        assert!(!has_kind_at(&found, "Spelling", 4, 10), "{found:?}");
    }

    /// Depends on Harper flagging British spelling under the American setting.
    #[test]
    fn british_spelling_is_flagged_in_american() {
        let mut checker = build(false, "");
        let found = lint(&mut checker, "The colour is nice.");
        assert!(has_span(&found, 4, 10), "{found:?}");
    }

    /// Chirp's own finding reaches the output with a fix. If Harper ever flags the same word itself, its
    /// finding takes the place of ours and offers the same fix, so this still holds.
    #[test]
    fn chirps_own_findings_are_included() {
        let mut checker = build(false, "");
        let found = lint(&mut checker, "We was late.");
        assert!(has_span(&found, 3, 6), "{found:?}");
        assert!(
            found.iter().any(|f| f["start"].as_u64() == Some(3)
                && f["suggestions"].as_array().is_some_and(|s| s.iter().any(|x| x["text"] == "were"))),
            "{found:?}"
        );
    }
}
