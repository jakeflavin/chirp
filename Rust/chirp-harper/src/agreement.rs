//! Subject–verb agreement checks that Harper's own rules do not cover yet.
//!
//! Harper (3.2) catches agreement when the subject is a pronoun ("She don't"). It has no rule for a noun
//! subject ("The results shows", "The list of items are"), which is most of what people get wrong.
//! These checks use Harper's own tokens and dictionary (noun number, verb forms), so they stay as fast
//! as the rest of the instant check. They are deliberately narrow: a subject is only recognised at the
//! start of a clause, in a finished statement, and anything ambiguous is left alone. Missing a mistake
//! is better here than underlining a correct sentence.

use harper_core::linting::{Lint, LintKind, Suggestion};
use harper_core::spell::Dictionary;
use harper_core::{DictWordMetadata, Document, Span, Token, TokenKind};

/// One mistake found by Chirp's own checks.
pub struct Found {
    /// The name of the check, e.g. "NounVerbAgreement". Swift uses it to remember a dismissed suggestion.
    pub rule: &'static str,
    /// Where the mistake is (in characters, like Harper's own findings), the message, and the fix.
    pub lint: Lint,
}

/// A word of the sentence with its text ready for comparing.
struct Word<'a> {
    tok: &'a Token,
    /// As typed, except that a curly apostrophe is made straight so "isn’t" matches the word lists.
    text: String,
    /// `text` in lowercase, for looking up in the word lists and the dictionary.
    lower: String,
    /// Harper's part-of-speech tag for this word where it stands ("NOUN", "VERB", "ADJ"…), if it gave one.
    /// Worked out once, because the checks ask for it many times.
    pos: Option<String>,
    /// What the dictionary says about the word by itself, looked up once. Its noun number is more
    /// reliable than the token's: what the tagger says about a word in context loses the number.
    meta: Option<DictWordMetadata>,
}

impl Word<'_> {
    /// What Harper knows about the word: every part of speech the dictionary allows for it, plus the
    /// one tag it chose for this sentence.
    fn kind(&self) -> &TokenKind {
        &self.tok.kind
    }
    /// Whether the word, in lowercase, is one of `words`.
    fn is(&self, words: &[&str]) -> bool {
        words.contains(&self.lower.as_str())
    }
    /// Harper's part-of-speech tag for this word where it stands, if it gave one.
    fn tag(&self) -> Option<&str> {
        self.pos.as_deref()
    }
    /// Whether Harper tagged the word as `tag` where it stands.
    fn tagged(&self, tag: &str) -> bool {
        self.tag() == Some(tag)
    }
    /// Whether the word starts with a capital, as a name or the first word of a sentence does.
    fn capitalised(&self) -> bool {
        self.text.chars().next().is_some_and(|c| c.is_uppercase())
    }
}

/// Words between two punctuation marks. A clause may begin at its first word when `opens` is set.
struct Run<'a> {
    words: Vec<Word<'a>>,
    /// The run starts the sentence or follows a comma or semicolon, so its first word may be a subject.
    opens: bool,
    /// The run is the very start of the sentence. Some checks only make sense there.
    first: bool,
    /// Ends at a comma or at the end of the sentence, so nothing of the clause is hidden behind a
    /// bracket, quote or dash.
    closed: bool,
}

/// Words that begin a noun group. A subject is only looked for after one of these.
const DETERMINERS: &[&str] = &[
    "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "its", "our", "their", "some",
    "both", "many", "several", "no", "every", "each", "any",
];

/// Words after which a new clause, with its own subject, begins.
const OPENERS: &[&str] = &[
    "but", "because", "if", "when", "while", "although", "though", "unless", "whereas", "that", "whether", "think", "thinks",
    "thought", "believe", "believes", "believed", "guess", "suppose", "said", "says", "say", "hope", "hopes",
];
/// After these the verb may be in the subjunctive ("I insist that he go", "if the cost were lower").
const SUBJUNCTIVE_OPENERS: &[&str] = &["if", "that", "unless", "whether", "though", "although"];

/// Nouns whose number cannot be told from the word, or that take either verb ("the team are").
const UNCLEAR_NUMBER: &[&str] = &[
    "news", "series", "species", "means", "data", "media", "fish", "sheep", "deer", "staff", "police", "people",
    "headquarters", "physics", "politics", "economics", "mathematics", "athletics", "statistics", "ethics",
    "crossroads", "barracks", "offspring", "aircraft", "majority", "minority", "number", "lot", "lots", "couple",
    "handful", "bunch", "variety", "range", "group", "pair", "rest", "half", "part", "percent", "percentage",
    "fraction", "total", "kind", "sort", "type", "plenty", "team", "family", "committee", "government", "audience",
    "crowd", "class", "company", "band", "jury", "board", "council", "public", "press", "faculty", "crew", "army",
    "party", "club", "firm", "department", "management", "community", "cast", "choir", "enemy", "population",
    "youth", "bulk", "remainder", "dozen", "hundred", "thousand", "million", "billion", "one", "ones", "none",
    "all", "most", "more", "any", "some", "who", "which", "what", "there", "here", "works", "thanks", "odds",
    "contents", "goods", "clothes", "earnings", "savings", "surroundings", "premises", "whereabouts", "united",
    "plurality", "multitude", "host", "plethora", "myriad", "abundance", "array", "load", "loads", "ton", "tons", "heap",
    "heaps", "mass", "scores", "wealth", "set", "collection", "selection", "mix", "combination", "string", "wave", "stream",
    // Plurals the dictionary lists as plain nouns, which would otherwise read as singular.
    "phenomena", "nuclei", "antennae", "proceeds", "kudos", "jeans",
];

/// Adjectives that stand for a group of people ("the poor need help").
const PEOPLE_ADJECTIVES: &[&str] = &[
    "poor", "rich", "elderly", "young", "old", "sick", "dead", "living", "wealthy", "homeless", "unemployed", "blind",
    "deaf", "disabled", "french", "british", "english", "dutch", "irish", "welsh", "spanish", "chinese", "japanese",
    "injured", "wounded", "accused", "faithful", "brave", "few", "many", "latter", "former", "following", "above",
    "other", "others", "same", "best", "worst", "least", "most", "rest", "majority",
];

/// Words that can follow a subject and add to it: "the list OF items", "the students IN my class".
/// ("After", "before" and "since" are left out: they also begin a clause, as in "the day after the results were in".)
const AFTER_SUBJECT: &[&str] = &[
    "of", "in", "on", "at", "for", "with", "from", "by", "about", "under", "between", "among", "behind", "near", "across",
    "through", "during", "inside", "outside", "into",
];

/// Forms of "be", "have" and "do" and the modal verbs. One of these ends a noun group, and shows that
/// a clause already has its verb.
const FINITE: &[&str] = &[
    "is", "are", "was", "were", "has", "have", "had", "will", "would", "can", "could", "should", "must", "may", "might",
    "does", "do", "did", "isn't", "aren't", "wasn't", "weren't", "won't", "can't", "doesn't", "don't", "didn't",
    "cannot", "shall", "shouldn't", "couldn't", "wouldn't", "hasn't", "haven't", "hadn't", "mustn't", "am", "be", "been", "being",
];

/// Words that are verbs in the dictionary but, after a subject, are nearly always adverbs or adjectives
/// ("the water still runs", "the door right there").
const MIDDLE_ADVERBS: &[&str] = &[
    "still", "even", "just", "well", "back", "right", "only", "ever", "never", "further", "forward", "away", "down", "up",
    "out", "over", "round", "about", "around", "near", "better", "best", "less", "more", "most", "much", "pretty", "clean",
    "clear", "close", "direct", "double", "fine", "flat", "free", "light", "low", "quiet", "slow", "wrong", "long", "last",
    "first", "second", "next", "home", "to", "so", "too", "very", "quite", "rather", "almost", "also", "always", "often",
    "soon", "then", "now", "here", "there", "like", "as", "than", "not", "please", "though", "yet", "once", "twice", "own",
    "open", "complete", "separate", "present", "past", "wide", "short", "full", "sure", "enough", "abroad", "alone", "apart",
];

/// The verbs whose singular and plural differ by more than an "s": (singular, plural).
const BE_PAIRS: &[(&str, &str)] = &[
    ("is", "are"),
    ("was", "were"),
    ("has", "have"),
    ("does", "do"),
    ("isn't", "aren't"),
    ("wasn't", "weren't"),
    ("hasn't", "haven't"),
    ("doesn't", "don't"),
];

/// The singular partner of a plural form in `BE_PAIRS`: "are" gives "is".
fn be_singular_of(plural: &str) -> Option<&'static str> {
    BE_PAIRS.iter().find(|pair| pair.1 == plural).map(|pair| pair.0)
}

/// The plural partner of a singular form in `BE_PAIRS`: "is" gives "are".
fn be_plural_of(singular: &str) -> Option<&'static str> {
    BE_PAIRS.iter().find(|pair| pair.0 == singular).map(|pair| pair.1)
}

/// Verbs that are followed by a question ("I asked the students who was responsible"). After one of
/// these, "who" asks about someone new and does not refer to the noun before it.
const ASKING_VERBS: &[&str] = &[
    "ask", "asks", "asked", "asking", "tell", "tells", "told", "telling", "matter", "matters", "mattered", "know",
    "knows", "knew", "known", "wonder", "wonders", "wondered", "wondering", "decide", "decides", "decided",
    "guess", "guesses", "guessed", "see", "sees", "saw",
];

/// Units of money, time and measure. An amount is one thing: "There is five dollars on the table".
const UNITS: &[&str] = &[
    "dollars", "cents", "pounds", "euros", "bucks", "percent", "seconds", "minutes", "hours", "days", "weeks",
    "months", "years", "miles", "kilometers", "kilometres", "meters", "metres", "feet", "inches", "kilos", "grams",
    "ounces", "gallons", "liters", "litres", "degrees",
];

/// "Everyone", "nobody" and the like are singular.
const SINGULAR_PRONOUNS: &[&str] = &[
    "everyone", "everybody", "someone", "somebody", "anyone", "anybody", "nobody", "everything", "something", "anything",
    "nothing",
];
/// Verbs of state. Only these are corrected after "everyone", because "Everybody dance!" and
/// "Somebody call a doctor" are orders, not mistakes.
const STATE_VERBS: &[&str] = &[
    "need", "want", "know", "like", "love", "hate", "think", "believe", "agree", "seem", "understand", "deserve", "prefer",
    "hope", "wish", "feel", "mean", "own", "expect", "appear", "belong", "depend", "matter", "care", "wonder",
];

/// Runs every check over the document, one finished sentence at a time. `dict` must be the dictionary
/// the document was parsed with. Spans in the result count characters, as Harper's do.
pub fn check(doc: &Document, dict: &impl Dictionary) -> Vec<Found> {
    check_lines(doc, dict, true)
}

/// As `check`. With `open` set (what `check` does), a last line with no full stop also counts as a
/// finished sentence; without it only a full stop or an exclamation mark ends one, which is kept
/// for measuring the difference.
pub fn check_lines(doc: &Document, dict: &impl Dictionary, open: bool) -> Vec<Found> {
    let src = doc.get_source();
    let toks = doc.get_tokens();
    let mut out = Vec::new();
    let mut start = 0;
    for i in 0..=toks.len() {
        let ends = i == toks.len()
            || toks[i].kind.is_sentence_terminator()
            || toks[i].kind.is_newline()
            || toks[i].kind.is_paragraph_break();
        if !ends {
            continue;
        }
        // Only statements: a question turns the order round ("Are the results in?").
        let stop = i < toks.len() && matches!(toks[i].get_str(src).as_str(), "." | "!");
        // A line with no full stop is a sentence too when nothing follows it (the end of the text, a
        // blank line, or a new line that starts with a capital or a bullet): "The results shows a gain"
        // typed into a message is as wrong without its full stop. A line whose next line starts in lower
        // case is the first half of a sentence wrapped by hand, and is left for its full stop.
        let finished = stop || (open && (i == toks.len() || ((toks[i].kind.is_newline() || toks[i].kind.is_paragraph_break()) && !continues(&toks[i + 1..], src))));
        if finished && i > start {
            sentence(&toks[start..i], src, dict, stop, &mut out);
        }
        start = i + 1;
    }
    out
}

/// Whether the text after a line break carries on the sentence before it. A new sentence or list item
/// starts with a capital, a bullet or a number; anything else (a word in lower case, a bracket, a piece
/// of code) is the rest of a sentence wrapped by hand.
fn continues(rest: &[Token], src: &[char]) -> bool {
    for t in rest {
        return match &t.kind {
            TokenKind::Space(_) => continue,
            TokenKind::Word(_) => !t.get_str(src).chars().next().is_some_and(|c| c.is_uppercase()),
            TokenKind::Number(_) => false,
            other if other.is_newline() || other.is_paragraph_break() => false,
            _ => !matches!(t.get_str(src).as_str(), "-" | "*" | "•" | "–" | "—" | "·"),
        };
    }
    false
}

/// Checks one sentence. It is cut into runs of words at every punctuation mark; each check is then
/// tried at each word, and the subject checks only where a clause can begin.
/// `stopped` says the sentence ended with a full stop or an exclamation mark, not at the end of a line.
fn sentence(toks: &[Token], src: &[char], dict: &impl Dictionary, stopped: bool, out: &mut Vec<Found>) {
    let mut runs: Vec<Run> = Vec::new();
    let mut words: Vec<Word> = Vec::new();
    let mut opens = true;
    let mut first = true;
    for t in toks {
        match &t.kind {
            TokenKind::Word(_) => {
                let text = t.get_str(src).replace('’', "'");
                let lower = text.to_lowercase();
                let pos = match &t.kind {
                    TokenKind::Word(Some(m)) => m.pos_tag.map(|p| format!("{p:?}")),
                    _ => None,
                };
                let meta = dict.get_word_metadata_str(&lower).map(|m| m.into_owned());
                words.push(Word { tok: t, text, lower, pos, meta });
            }
            TokenKind::Space(_) => {}
            other => {
                let comma = other.is_comma() || other.is_semicolon();
                if !words.is_empty() {
                    runs.push(Run { words: std::mem::take(&mut words), opens, first, closed: comma });
                    first = false;
                }
                opens = comma;
                if !opens {
                    first = false;
                }
            }
        }
    }
    if !words.is_empty() {
        runs.push(Run { words, opens, first, closed: true });
    }
    // A line that begins without a capital is the middle of a wrapped sentence, not the start of one.
    if let Some(run) = runs.first_mut() {
        if run.first && !run.words[0].capitalised() {
            run.first = false;
            run.opens = false;
        }
    }

    for run in &runs {
        let ws = &run.words;
        for p in 0..ws.len() {
            let opener = if p > 0 { Some(ws[p - 1].lower.as_str()) } else { None };
            let starts = match opener {
                None => run.opens,
                // "Everyone but the managers is invited": a "but" with words before it in the same run
                // joins on to the subject already there, and does not begin a clause.
                Some("but") => p == 1,
                Some(w) => OPENERS.contains(&w),
            };
            your(ws, p, run.first && p == 0 && ws.len() == 2, out);
            they_was(ws, p, starts, out);
            who_verb(ws, p, dict, out);
            to_too(ws, p, out);
            if !starts {
                continue;
            }
            let subjunctive = opener.is_some_and(|w| SUBJUNCTIVE_OPENERS.contains(&w));
            let at_start = run.first && p == 0;
            if at_start {
                weather(ws, out);
                // Not on a line without a full stop: a heading ("The summer break at school") has the
                // same shape as the mistake this looks for.
                if runs.len() == 1 && stopped {
                    plain_sentence(ws, dict, out);
                }
                pronoun_pair(ws, dict, out);
                names(ws, out);
                this_these(ws, out);
                this_gives(ws, dict, out);
            }
            there(ws, p, dict, out);
            this_shoes(ws, p, at_start, dict, out);
            everyone(ws, p, subjunctive, dict, out);
            seen(ws, p, out);
            noun_subject(ws, p, subjunctive, run.closed, dict, out);
        }
    }
}

// MARK: The subject is a noun

/// "The results shows", "The cost were", "The list of items are", "One of my friends live".
fn noun_subject(ws: &[Word], p: usize, subjunctive: bool, closed: bool, dict: &impl Dictionary, out: &mut Vec<Found>) {
    let n = ws.len();
    let singular: bool;
    let head: usize;
    let of: usize;

    if ws[p].is(&["one", "each", "either", "neither"]) && p + 1 < n && ws[p + 1].lower == "of" {
        singular = true;
        head = p;
        of = p + 1;
    } else if ws[p].is(DETERMINERS) {
        let i = p + 1;
        let Some(j) = nominal_end(ws, i) else { return };
        if suspicious(&ws[i..j]) {
            return;
        }
        if j < n && ws[j].is(AFTER_SUBJECT) && ws[j - 1].kind().is_noun() && !ws[j - 1].tagged("VERB") {
            // "The list of items are", "The students in my class is": the subject is the first noun.
            let Some(sg) = number_opt(&ws[j - 1], dict) else { return };
            singular = sg;
            head = j - 1;
            of = j;
        } else if j + 1 < n && ws[j].lower == "and" && ws[j + 1].is(DETERMINERS) && is_head(&ws[j - 1]) {
            // "The dog and the cat sleeps": two things, so the verb is plural.
            let k = j + 2;
            let Some(j2) = nominal_end(ws, k) else { return };
            if suspicious(&ws[k..j2]) {
                return;
            }
            verb_after_group(ws, k, j2, Some((usize::MAX, false)), subjunctive, closed, dict, out);
            return;
        } else {
            verb_after_group(ws, i, j, None, subjunctive, closed, dict, out);
            return;
        }
    } else {
        return;
    }

    // After "of": an optional determiner, a noun group, then the verb.
    let mut k = of + 1;
    if k < n && ws[k].is(DETERMINERS) {
        k += 1;
    }
    let Some(j) = nominal_end(ws, k) else { return };
    if suspicious(&ws[k..j]) {
        return;
    }
    verb_after_group(ws, k, j, Some((head, singular)), subjunctive, closed, dict, out);
}

/// Looks for the verb after the noun group `ws[i..j]` and flags it when it has the wrong number.
/// `subject` is given when the subject is already known ("the list of items", "the dog and the cat");
/// otherwise the subject is a noun of the group.
fn verb_after_group(
    ws: &[Word],
    i: usize,
    j: usize,
    subject: Option<(usize, bool)>,
    subjunctive: bool,
    closed: bool,
    dict: &impl Dictionary,
    out: &mut Vec<Found>,
) {
    let n = ws.len();
    let two = subject.is_some_and(|(h, _)| h == usize::MAX);
    let mut report = |verb: &Word, h: usize, sg: bool, fix: String| {
        if two {
            let message = format!("Two things are the subject, so the verb should be “{fix}”.");
            push(out, "NounVerbAgreement", verb.tok.span, &verb.text, fix, message);
        } else {
            flag(out, verb, &ws[h], sg, fix);
        }
    };
    // Case A: the verb follows the group ("The cost | were", "The car keys | is").
    if j < n && (is_head(&ws[j - 1]) || (subject.is_some() && ws[j - 1].kind().is_noun())) {
        let found = subject.or_else(|| number_opt(&ws[j - 1], dict).map(|sg| (j - 1, sg)));
        if let Some((h, sg)) = found {
            let verbal = ws[j].tagged("VERB") || ws[j].tagged("AUX") || ws[j].tag().is_none();
            if let Some(fix) = agree(&ws[j], sg, subjunctive, dict).filter(|_| verbal) {
                let be = be_singular_of(&ws[j].lower).is_some() || be_plural_of(&ws[j].lower).is_some();
                // "These tools help identify…": the group holds nouns of both numbers, so its last word
                // is probably the verb, not the subject.
                let mixed = subject.is_none()
                    && ws[i..j - 1].iter().any(|w| number_opt(w, dict).is_some_and(|other| other != sg));
                if be || !mixed {
                    return report(&ws[j], h, sg, fix);
                }
            }
        }
    }
    // Case B: the verb is inside the group, because it can also be a noun or an adjective
    // ("The report | show a drop", "Our customers | wants faster delivery"). The subject is then the
    // first noun, with only adjectives before it, so "The strategy converts offsets to…" is left alone.
    for t in i + 1..j {
        if !ws[i..t - 1].iter().all(|w| plain_adjective(w)) {
            break;
        }
        if !is_head(&ws[t - 1]) {
            continue;
        }
        let found = subject.or_else(|| number_opt(&ws[t - 1], dict).map(|sg| (t - 1, sg)));
        let Some((h, sg)) = found else { continue };
        // Harper tags each word where it stands. "The report show a drop" has "show" as a verb;
        // "the crimson room bloomed" has "room" as a noun, and is left alone.
        if !(ws[t].tagged("VERB") || ws[t].tag().is_none()) {
            continue;
        }
        if let Some(fix) = agree(&ws[t], sg, subjunctive, dict) {
            if closed && verb_reading_is_safe(ws, t) {
                report(&ws[t], h, sg, fix);
            }
            return;
        }
    }
}

/// The end of the run of adjectives and nouns starting at `i`. None when there is no such run, or it is
/// too long to be sure where the subject ends.
fn nominal_end(ws: &[Word], i: usize) -> Option<usize> {
    let mut j = i;
    while j < ws.len() {
        let w = &ws[j];
        let k = w.kind();
        let nominal = k.is_noun() || k.is_adjective() || k.is_possessive_nominal() || k.is_verb_progressive_form();
        if !nominal
            || k.is_determiner()
            || k.is_preposition()
            || k.is_conjunction()
            || k.is_pronoun()
            || k.is_auxiliary_verb()
            || w.is(FINITE)
            || w.is(MIDDLE_ADVERBS)
        {
            break;
        }
        j += 1;
        if j - i > 4 {
            return None;
        }
    }
    (j > i).then_some(j)
}

/// Names and titles ("The Hunger Games is…") and "the poor", where the usual reading fails.
fn suspicious(group: &[Word]) -> bool {
    group.iter().any(|w| w.capitalised() || w.is(PEOPLE_ADJECTIVES))
}

/// A word that can be the subject: tagged as a noun where it stands, and a noun in the dictionary.
fn is_head(w: &Word) -> bool {
    w.tagged("NOUN") && w.meta.as_ref().is_some_and(|m| m.is_noun())
}

/// Whether `word` is another noun with "s" or "es" added. Endings that are usually part of a singular
/// word ("glass", "bus", "analysis") do not count.
fn plural_by_shape(word: &str, dict: &impl Dictionary) -> bool {
    if !word.ends_with('s') || word.ends_with("ss") || word.ends_with("us") || word.ends_with("is") {
        return false;
    }
    let stems = [word.strip_suffix("es"), word.strip_suffix('s')];
    stems.into_iter().flatten().any(|stem| stem.len() > 2 && dict.get_word_metadata_str(stem).is_some_and(|m| m.is_singular_noun()))
}

/// An adjective that cannot also be an "-s" verb, so it can sit before the subject without being the verb.
fn plain_adjective(w: &Word) -> bool {
    w.meta.as_ref().is_some_and(|m| m.is_adjective() && !m.is_verb_third_person_singular_present_form())
}

/// Some(true) for a singular noun, Some(false) for a plural one, None when it cannot be told.
/// The dictionary's entry for the word itself is used: what the tagger says about it in context loses the number.
fn number_opt(w: &Word, dict: &impl Dictionary) -> Option<bool> {
    if w.is(UNCLEAR_NUMBER) || w.kind().is_possessive_nominal() || w.kind().is_pronoun() {
        return None;
    }
    let m = w.meta.as_ref()?;
    match (m.is_singular_noun(), m.is_plural_noun()) {
        // The dictionary lists some plurals as singular ("definitions"). A word that is another noun
        // plus "s" is plural.
        (true, false) if plural_by_shape(&w.lower, dict) => Some(false),
        (true, false) => Some(true),
        (false, true) => Some(false),
        _ => None,
    }
}

/// The form `v` should have for a subject of this number, when it has the wrong one.
fn agree(v: &Word, singular: bool, subjunctive: bool, dict: &impl Dictionary) -> Option<String> {
    let l = v.lower.as_str();
    if let Some(s) = be_singular_of(l) {
        // A plural form. "If the cost were lower" and "I ask that he have a say" are right.
        return if singular && !subjunctive { Some(s.to_string()) } else { None };
    }
    if let Some(p) = be_plural_of(l) {
        // A singular form.
        return if singular { None } else { Some(p.to_string()) };
    }
    let k = v.kind();
    if (k.is_auxiliary_verb() && !v.is(&["need", "needs", "dare", "dares"])) || v.is(MIDDLE_ADVERBS) || k.is_preposition() || k.is_conjunction() || k.is_determiner() || k.is_pronoun() {
        return None;
    }
    if singular {
        if subjunctive || !k.is_verb_lemma() || k.is_verb_third_person_singular_present_form() || k.is_verb_past_form() {
            return None;
        }
        third_person(l, dict)
    } else {
        if !k.is_verb_third_person_singular_present_form() || k.is_verb_lemma() {
            return None;
        }
        lemma(l, dict)
    }
}

/// When the verb could also be a noun ("show", "wants"), the words may be a noun group instead
/// ("the talent show a year ago was fun"). Only take the verb reading when what follows starts an object
/// and no other verb comes later.
fn verb_reading_is_safe(ws: &[Word], v: usize) -> bool {
    let Some(next) = ws.get(v + 1) else { return !ws[v].kind().is_noun() && !ws[v].kind().is_adjective() };
    // "The results shows that we won": the one verb that comes later belongs to what follows "that",
    // so this word is the verb of the sentence. With two ("the talent show that we won was fun") the
    // second may be the main verb, and the words are left alone.
    if next.lower == "that" {
        return ws[v + 2..].iter().filter(|w| can_be_verb(w, false)).count() == 1;
    }
    // "Its creamy texture and tangy taste make…": the subject goes on.
    if next.capitalised() || next.is(FINITE) || next.is(&["and", "or", "nor"]) {
        return false;
    }
    // A clause has one main verb. If a later word is one ("the talent show a year ago WAS fun"), this
    // word is part of the subject instead.
    !later_verb(&ws[v + 1..], false)
}

/// Whether any of `rest` can be the verb of the clause: a form of "be", "have" or "do", a modal, or a
/// word the dictionary knows as an "-s" or past form. With `count_tagged`, a word Harper tagged as a
/// verb where it stands counts too.
fn later_verb(rest: &[Word], count_tagged: bool) -> bool {
    rest.iter().any(|w| can_be_verb(w, count_tagged))
}

/// Whether one word can be the verb of a clause, as `later_verb` counts it.
fn can_be_verb(w: &Word, count_tagged: bool) -> bool {
    w.is(FINITE)
        || w.tagged("AUX")
        || (count_tagged && w.tagged("VERB"))
        || w.meta.as_ref().is_some_and(|m| {
            m.is_verb_third_person_singular_present_form() || m.is_verb_past_form() || m.is_verb_simple_past_form()
        })
}

/// The "-s" form of a verb ("show" to "shows", "carry" to "carries"). None unless the dictionary knows
/// the result as that form, so a made-up word is never suggested.
fn third_person(lemma: &str, dict: &impl Dictionary) -> Option<String> {
    let candidate = match lemma {
        "be" => return None,
        "have" => "has".to_string(),
        "do" => "does".to_string(),
        "go" => "goes".to_string(),
        l if l.ends_with('s') || l.ends_with('x') || l.ends_with('z') || l.ends_with("ch") || l.ends_with("sh") || l.ends_with('o') => {
            format!("{l}es")
        }
        l if l.ends_with('y') && !l.ends_with("ay") && !l.ends_with("ey") && !l.ends_with("oy") && !l.ends_with("uy") => {
            format!("{}ies", &l[..l.len() - 1])
        }
        l => format!("{l}s"),
    };
    dict.get_word_metadata_str(&candidate)
        .is_some_and(|m| m.is_verb_third_person_singular_present_form())
        .then_some(candidate)
}

/// The plain form of an "-s" verb ("shows" to "show", "carries" to "carry"). Each way of taking the
/// ending off is tried, and the first that the dictionary knows as a verb wins.
fn lemma(third: &str, dict: &impl Dictionary) -> Option<String> {
    let mut candidates: Vec<String> = Vec::new();
    match third {
        "has" => candidates.push("have".into()),
        "does" => candidates.push("do".into()),
        "goes" => candidates.push("go".into()),
        _ => {}
    }
    if let Some(stem) = third.strip_suffix("ies") {
        candidates.push(format!("{stem}y"));
    }
    if let Some(stem) = third.strip_suffix("es") {
        candidates.push(stem.to_string());
    }
    if let Some(stem) = third.strip_suffix('s') {
        candidates.push(stem.to_string());
    }
    candidates.into_iter().find(|c| dict.get_word_metadata_str(c).is_some_and(|m| m.is_verb_lemma()))
}

/// Records a verb that disagrees with its noun subject, with a message that names the subject.
fn flag(out: &mut Vec<Found>, verb: &Word, subject: &Word, singular: bool, fix: String) {
    let message = if singular {
        format!("“{}” is singular, so the verb should be “{}”.", subject.text, fix)
    } else {
        format!("“{}” is plural, so the verb should be “{}”.", subject.text, fix)
    };
    push(out, "NounVerbAgreement", verb.tok.span, &verb.text, fix, message);
}

/// Records one finding: replace the words at `span` (which read `original`) with `fix`.
fn push(out: &mut Vec<Found>, rule: &'static str, span: Span<char>, original: &str, fix: String, message: String) {
    // Keep a capital the user typed.
    let fix = if original.chars().next().is_some_and(|c| c.is_uppercase()) {
        let mut c = fix.chars();
        c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
    } else {
        fix
    };
    out.push(Found {
        rule,
        lint: Lint {
            span,
            lint_kind: LintKind::Agreement,
            suggestions: vec![Suggestion::ReplaceWith(fix.chars().collect())],
            message,
            priority: 40,
        },
    });
}

// MARK: Smaller patterns

/// "Everyone need to sign", "Nobody know", "Everybody are".
/// "Have" and "do" are left alone after these words, because they are usually orders ("Everyone have a
/// great weekend!"), except "have" before a past form.
fn everyone(ws: &[Word], p: usize, subjunctive: bool, dict: &impl Dictionary, out: &mut Vec<Found>) {
    if !ws[p].is(SINGULAR_PRONOUNS) || subjunctive {
        return;
    }
    let Some(v) = ws.get(p + 1) else { return };
    let l = v.lower.as_str();
    // Only forms of "be": "Everyone have a great weekend!" and "Somebody do something!" are orders.
    if v.is(&["are", "were", "aren't", "weren't"]) {
        if let Some(s) = be_singular_of(l) {
            return push(out, "EveryoneAgreement", v.tok.span, &v.text, s.to_string(), format!("“{}” is singular, so the verb should be “{}”.", ws[p].text, s));
        }
    }
    // "Somebody have left the door open": "have" before a past form ("left", "taken") is the helper verb,
    // not an order, so it is corrected too.
    if l == "have" && ws.get(p + 2).is_some_and(|w| w.meta.as_ref().is_some_and(|m| m.is_verb_past_participle_form() || m.is_verb_past_form() || m.is_verb_simple_past_form())) {
        return push(out, "EveryoneAgreement", v.tok.span, &v.text, "has".to_string(), format!("“{}” is singular, so the verb should be “has”.", ws[p].text));
    }
    if l == "like" {
        // "Something like that would help", "Someone like you deserves better": here "like" compares,
        // and the clause has its own verb further on. After "-thing" it nearly always compares.
        if ws[p].lower.ends_with("thing") || later_verb(&ws[p + 2..], true) {
            return;
        }
    }
    // "Everyone feel free to join" is an invitation.
    if l == "feel" && ws.get(p + 2).is_some_and(|w| w.lower == "free") {
        return;
    }
    if v.is(STATE_VERBS) {
        if let Some(fix) = third_person(l, dict) {
            let message = format!("“{}” is singular, so the verb should be “{}”.", ws[p].text, fix);
            push(out, "EveryoneAgreement", v.tok.span, &v.text, fix, message);
        }
    }
}

/// "There are a problem", "There is many reasons".
fn there(ws: &[Word], p: usize, dict: &impl Dictionary, out: &mut Vec<Found>) {
    if ws[p].lower != "there" || p + 2 >= ws.len() {
        return;
    }
    let v = &ws[p + 1];
    let x = &ws[p + 2];
    const MANY: &[&str] = &[
        "many", "several", "numerous", "multiple", "various", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    ];
    const NOT_ONE: &[&str] = &["few", "lot", "couple", "great", "good", "number", "dozen", "hundred", "thousand", "million", "billion"];
    if v.is(&["is", "was"]) && x.is(MANY) {
        // "There is five dollars on the table": an amount is one thing.
        if ws.get(p + 3).is_some_and(|w| w.is(UNITS)) {
            return;
        }
        let fix = if v.lower == "is" { "are" } else { "were" };
        return push(out, "ThereAgreement", v.tok.span, &v.text, fix.into(), format!("More than one thing follows, so this should be “{fix}”."));
    }
    if v.is(&["are", "were"]) && x.is(&["a", "an", "one", "another"]) {
        let i = p + 3;
        let Some(j) = nominal_end(ws, i) else { return };
        if ws[i..j].iter().any(|w| w.is(NOT_ONE)) || ws.get(j).is_some_and(|w| w.lower == "of") {
            return;
        }
        if number_opt(&ws[j - 1], dict) == Some(true) {
            let fix = if v.lower == "are" { "is" } else { "was" };
            push(out, "ThereAgreement", v.tok.span, &v.text, fix.into(), format!("One thing follows, so this should be “{fix}”."));
        }
    }
}

/// "This give us a problem", "That make me happy": "this" or "that" as the subject, a verb without
/// its "-s", and then the person it is done to. Only with "us", "me", "him", "them", "you" or "it" after
/// the verb, which rules out "this place" and "that show" as the start of a longer subject, and never
/// for a verb whose past is spelt the same ("This put us in a bind", "This let me see").
fn this_gives(ws: &[Word], dict: &impl Dictionary, out: &mut Vec<Found>) {
    if ws.len() < 3 || !ws[0].is(&["this", "that"]) || !ws[2].is(&["us", "me", "him", "them", "you", "it"]) {
        return;
    }
    let v = &ws[1];
    let k = v.kind();
    if !v.tagged("VERB") || v.is(FINITE) || k.is_auxiliary_verb() || !k.is_verb_lemma() {
        return;
    }
    if k.is_verb_third_person_singular_present_form() || k.is_verb_past_form() || k.is_verb_simple_past_form() {
        return;
    }
    let Some(fix) = third_person(&v.lower, dict) else { return };
    push(out, "ThisTheseAgreement", v.tok.span, &v.text, fix.clone(), format!("After “{}” this should be “{fix}”.", ws[0].text));
}

/// "This are a good idea", "These is the files".
fn this_these(ws: &[Word], out: &mut Vec<Found>) {
    if ws.len() < 2 {
        return;
    }
    let v = &ws[1];
    let fix = match (ws[0].lower.as_str(), v.lower.as_str()) {
        ("this", "are") => "is",
        ("this", "were") => "was",
        ("these" | "those", "is") => "are",
        ("these" | "those", "was") => "were",
        _ => return,
    };
    push(out, "ThisTheseAgreement", v.tok.span, &v.text, fix.into(), format!("After “{}” this should be “{fix}”.", ws[0].text));
}

/// "Me and him goes to the store", "Her and me went".
fn pronoun_pair(ws: &[Word], dict: &impl Dictionary, out: &mut Vec<Found>) {
    if ws.len() < 4 || ws[1].lower != "and" {
        return;
    }
    let fix = match (ws[0].lower.as_str(), ws[2].lower.as_str()) {
        ("me", "him") | ("him", "me") => "He and I",
        ("me", "her") | ("her", "me") => "She and I",
        ("me", "them") | ("them", "me") => "They and I",
        ("me", "you") => "You and I",
        _ => return,
    };
    let v = &ws[3];
    if !(v.kind().is_verb() || v.is(FINITE)) {
        return;
    }
    // "Me and her husband went": "her" may belong to the next word, and many nouns ("husband", "friend",
    // "mother") can also be verbs. After "her" the next word has to be a verb where it stands.
    if ws[2].lower == "her" && !(v.tagged("VERB") || v.tagged("AUX") || v.is(FINITE)) {
        return;
    }
    let span = Span::new(ws[0].tok.span.start, ws[2].tok.span.end);
    out.push(Found {
        rule: "SubjectPronouns",
        lint: Lint {
            span,
            lint_kind: LintKind::Agreement,
            suggestions: vec![Suggestion::ReplaceWith(fix.chars().collect())],
            message: format!("As the subject of the sentence this should be “{fix}”."),
            priority: 40,
        },
    });
    if let Some(plural) = agree(v, false, false, dict) {
        push(out, "SubjectPronouns", v.tok.span, &v.text, plural.clone(), format!("Two people are the subject, so the verb should be “{plural}”."));
    }
}

/// "Tom and Anna is on the call".
fn names(ws: &[Word], out: &mut Vec<Found>) {
    if ws.len() < 4 || ws[1].lower != "and" {
        return;
    }
    let name = |w: &Word| w.capitalised() && (w.kind().is_proper_noun() || matches!(w.kind(), TokenKind::Word(None))) && !w.kind().is_pronoun();
    if !name(&ws[0]) || !name(&ws[2]) {
        return;
    }
    let v = &ws[3];
    // "Tom and Jerry is a cartoon", "Romeo and Juliet is a play": the pair is the name of one thing.
    if v.is(&["is", "was", "isn't", "wasn't"]) && ws.get(4).is_some_and(|w| w.is(&["a", "an"])) {
        return;
    }
    if let Some(p) = be_plural_of(&v.lower) {
        push(out, "NamesAgreement", v.tok.span, &v.text, p.to_string(), format!("Two people are the subject, so the verb should be “{p}”."));
    }
}

/// "I seen that movie", "We done it".
fn seen(ws: &[Word], p: usize, out: &mut Vec<Found>) {
    if !ws[p].is(&["i", "we", "they", "he", "she", "you"]) {
        return;
    }
    let Some(v) = ws.get(p + 1) else { return };
    let fix = match v.lower.as_str() {
        "seen" => "saw",
        "done" => "did",
        _ => return,
    };
    push(out, "SeenWithoutHave", v.tok.span, &v.text, fix.into(), format!("Without “have”, this should be “{fix}”."));
}

/// "The price is to low for us".
fn to_too(ws: &[Word], p: usize, out: &mut Vec<Found>) {
    // "Been", "got" and "gets" are left out: "I have been to cold and remote places" is right.
    const AFTER_BE: &[&str] = &["is", "are", "was", "were", "it's", "that's", "be", "seems", "looks", "feels", "isn't", "wasn't"];
    const ADJECTIVES: &[&str] = &[
        "low", "high", "big", "small", "late", "early", "long", "short", "hot", "cold", "hard", "easy", "much", "many", "far",
        "old", "young", "expensive", "cheap", "good", "bad", "loud", "heavy", "difficult", "complicated", "strong", "weak", "tall",
        "soon", "little", "large", "fast", "slow", "tired", "busy", "dark",
    ];
    if p == 0 || ws[p].lower != "to" || !ws[p - 1].is(AFTER_BE) {
        return;
    }
    let Some(adjective) = ws.get(p + 1) else { return };
    if !adjective.is(ADJECTIVES) {
        return;
    }
    // "The plan is to slow the spread" is right: there the word is a verb with an object.
    if ws.get(p + 2).is_some_and(|w| !w.is(&["for", "to", "and", "or", "but"])) {
        return;
    }
    push(out, "ToToo", ws[p].tok.span, &ws[p].text, "too".into(), format!("Before “{}” this should be “too”.", adjective.text));
}

/// "that they was wrong", "we was late": "was" never goes with these.
/// "You" is only checked where a clause begins (`starts`), because it can also end one:
/// "The email I sent you was long".
fn they_was(ws: &[Word], p: usize, starts: bool, out: &mut Vec<Found>) {
    if !ws[p].is(&["they", "we", "you"]) || (ws[p].lower == "you" && !starts) {
        return;
    }
    let Some(v) = ws.get(p + 1) else { return };
    let fix = match v.lower.as_str() {
        "was" => "were",
        "wasn't" => "weren't",
        _ => return,
    };
    push(out, "TheyWas", v.tok.span, &v.text, fix.into(), format!("After “{}” this should be “{fix}”.", ws[p].text));
}

/// "The people who lives here": after "who", the verb agrees with the noun before it.
fn who_verb(ws: &[Word], p: usize, dict: &impl Dictionary, out: &mut Vec<Found>) {
    if p == 0 || ws[p].lower != "who" {
        return;
    }
    let Some(v) = ws.get(p + 1) else { return };
    let noun = &ws[p - 1];
    let singular = if noun.is(&["people", "children", "men", "women"]) {
        false
    } else if is_head(noun) && !noun.capitalised() {
        match number_opt(noun, dict) {
            Some(sg) => sg,
            None => return,
        }
    } else {
        return;
    };
    // "One of the people who …" and "the only one of the students who …" go either way.
    if ws[..p].iter().any(|w| w.is(&["one", "only", "each", "none", "any"])) {
        return;
    }
    // "The woman with the kids who lives next door": "who" may refer to the noun before the preposition.
    // "I asked the students who was responsible": "who" asks a question and refers to neither.
    if ws[..p].iter().any(|w| w.is(AFTER_SUBJECT) || w.is(ASKING_VERBS)) {
        return;
    }
    // Straight after "who" comes its verb, whatever the tagger made of the word ("lives" as a noun).
    if let Some(fix) = agree(v, singular, false, dict) {
        flag(out, v, noun, singular, fix);
    }
}

/// "This shoes are too tight": a plural noun and a plural verb after "this" or "that".
/// "That" is only checked as the first word of the sentence (`at_start`): anywhere else it usually joins
/// two clauses, as in "I think that dogs are loud".
fn this_shoes(ws: &[Word], p: usize, at_start: bool, dict: &impl Dictionary, out: &mut Vec<Found>) {
    if !ws[p].is(&["this", "that"]) || p + 2 >= ws.len() || (ws[p].lower == "that" && !at_start) {
        return;
    }
    let (noun, v) = (&ws[p + 1], &ws[p + 2]);
    if !v.is(&["are", "were", "have"]) || !is_head(noun) || number_opt(noun, dict) != Some(false) {
        return;
    }
    let fix = if ws[p].lower == "this" { "these" } else { "those" };
    push(out, "ThisShoes", ws[p].tok.span, &ws[p].text, fix.into(), format!("“{}” is plural, so this should be “{fix}”.", noun.text));
}

/// "Weather we need a second round": "whether" is meant when a pronoun follows.
fn weather(ws: &[Word], out: &mut Vec<Found>) {
    if ws.len() < 3 || ws[0].lower != "weather" || !ws[1].is(&["we", "you", "they", "he", "she", "it", "i", "or"]) {
        return;
    }
    push(out, "WeatherWhether", ws[0].tok.span, &ws[0].text, "whether".into(), "This should be “whether”.".into());
}

/// "My brother work at a bank": the verb is also a noun and reads like one, so the usual check passes it
/// by. In a sentence with no commas and no other word that could be its verb, it has to be the verb.
/// (A bare fragment ending in a full stop, "The car wash at the corner.", reads the same way and is
/// flagged too. None turned up in 356,000 words of prose; a sentence with its own verb is left alone.)
fn plain_sentence(ws: &[Word], dict: &impl Dictionary, out: &mut Vec<Found>) {
    if ws.len() < 5 || !ws[0].is(DETERMINERS) {
        return;
    }
    // Determiner, optional plain adjectives, a noun, then the word in question.
    let mut h = 1;
    while h < ws.len() && h <= 2 && plain_adjective(&ws[h]) && !ws[h].tagged("NOUN") {
        h += 1;
    }
    let v = h + 1;
    if !is_head(&ws[h]) || suspicious(&ws[1..=h]) {
        return;
    }
    if !ws[v].tagged("NOUN") {
        return;  // a word tagged as a verb is handled by the main check
    }
    let Some(sg) = number_opt(&ws[h], dict) else { return };
    // Nothing else may be able to be the verb, and at least two words must follow.
    if ws.len() - v - 1 < 2 {
        return;
    }
    let other_verb = later_verb(&ws[v + 1..], true);
    let next = &ws[v + 1];
    if other_verb || next.capitalised() || next.is(&["and", "or", "nor", "of"]) {
        return;
    }
    if let Some(fix) = agree(&ws[v], sg, false, dict) {
        flag(out, &ws[v], &ws[h], sg, fix);
    }
}

/// "Your going to love this", "Your a great friend", "Your welcome."
fn your(ws: &[Word], p: usize, whole_sentence_is_two_words: bool, out: &mut Vec<Found>) {
    if ws[p].lower != "your" {
        return;
    }
    let Some(next) = ws.get(p + 1) else { return };
    let wrong = match next.lower.as_str() {
        // "Bring your A game": a capital A is a grade or a name, not the article.
        "a" => next.text == "a",
        "an" | "not" | "gonna" => true,
        "going" => ws.get(p + 2).is_some_and(|w| w.lower == "to"),
        "welcome" => whole_sentence_is_two_words,
        _ => false,
    };
    if wrong {
        push(out, "YourYoure", ws[p].tok.span, &ws[p].text, "you're".into(), "This should be “you’re”, short for “you are”.".into());
    }
}

#[cfg(test)]
mod tests {
    use super::check;
    use harper_core::spell::FstDictionary;
    use harper_core::Document;

    /// What the checks would change `text` to: "word>fix" for each finding.
    fn fixes(text: &str) -> Vec<String> {
        let dict = FstDictionary::curated();
        let doc = Document::new_plain_english(text, dict.as_ref());
        check(&doc, dict.as_ref())
            .iter()
            .map(|f| {
                let fix = match f.lint.suggestions.first() {
                    Some(harper_core::linting::Suggestion::ReplaceWith(c)) => c.iter().collect::<String>(),
                    _ => String::new(),
                };
                format!("{}>{}", doc.get_span_content_str(&f.lint.span), fix)
            })
            .collect()
    }

    #[test]
    fn noun_subjects() {
        assert_eq!(fixes("The sentence are too long."), ["are>is"]);
        assert_eq!(fixes("The cost were higher than we planned."), ["were>was"]);
        assert_eq!(fixes("My friends is coming over tonight."), ["is>are"]);
        assert_eq!(fixes("The new features is ready for testing."), ["is>are"]);
        assert_eq!(fixes("The results shows a clear trend."), ["shows>show"]);
        assert_eq!(fixes("The report show a drop in sales."), ["show>shows"]);
        assert_eq!(fixes("The managers wants an update by Friday."), ["wants>want"]);
        assert_eq!(fixes("This document explain the process."), ["explain>explains"]);
        assert_eq!(fixes("We left because the dogs barks every night."), ["barks>bark"]);
        assert_eq!(fixes("The meeting start at nine tomorrow."), ["start>starts"]);
        assert_eq!(fixes("Our customers wants faster delivery."), ["wants>want"]);
        assert_eq!(fixes("The students in my class is very smart."), ["is>are"]);
        assert_eq!(fixes("The dog and the cat sleeps together."), ["sleeps>sleep"]);
        assert_eq!(fixes("Every student need a pencil."), ["need>needs"]);
        assert_eq!(fixes("The printer keep jamming every morning."), ["keep>keeps"]);
        assert_eq!(fixes("I think the instructions is confusing."), ["is>are"]);
    }

    #[test]
    fn subject_before_of() {
        assert_eq!(fixes("The list of items are on the desk."), ["are>is"]);
        assert_eq!(fixes("Each of the students have a laptop."), ["have>has"]);
        assert_eq!(fixes("One of my friends live in Boston."), ["live>lives"]);
        assert_eq!(fixes("The quality of the photos are poor."), ["are>is"]);
        assert_eq!(fixes("The box of chocolates are on the table."), ["are>is"]);
        assert!(fixes("A number of people are waiting.").is_empty());
        assert!(fixes("The majority of voters are undecided.").is_empty());
        assert!(fixes("A plurality of the rules are simple.").is_empty());
    }

    #[test]
    fn smaller_patterns() {
        assert_eq!(fixes("Everyone need to sign the form."), ["need>needs"]);
        assert_eq!(fixes("Nobody know the answer."), ["know>knows"]);
        assert_eq!(fixes("There is many reasons to wait."), ["is>are"]);
        assert_eq!(fixes("There are a problem with the invoice."), ["are>is"]);
        assert_eq!(fixes("This are a good idea."), ["are>is"]);
        assert_eq!(fixes("These is the files you asked for."), ["is>are"]);
        assert_eq!(fixes("Me and him goes to the store every day."), ["Me and him>He and I", "goes>go"]);
        assert_eq!(fixes("Tom and Anna is on the call."), ["is>are"]);
        assert_eq!(fixes("I seen that movie last week."), ["seen>saw"]);
        assert_eq!(fixes("Your going to love this."), ["Your>You're"]);
        assert_eq!(fixes("The price is to low for us."), ["to>too"]);
    }

    #[test]
    fn later_additions() {
        assert_eq!(fixes("The data shows that they was wrong."), ["was>were"]);
        assert_eq!(fixes("The people who lives here are friendly."), ["lives>live"]);
        assert_eq!(fixes("This shoes are too tight."), ["This>These"]);
        assert_eq!(fixes("Weather we need a second round of testing is unclear."), ["Weather>Whether"]);
        assert_eq!(fixes("My brother work at a bank."), ["work>works"]);
    }

    #[test]
    fn correct_sentences_are_left_alone() {
        for text in [
            "The report is finished and it reads well.",
            "The list of items is on the desk.",
            "The results show a clear trend.",
            "Everyone needs to sign the form.",
            "Everybody dance now!",
            "Somebody call a doctor.",
            "There are a lot of reasons to wait.",
            "There are a few problems with the invoice.",
            "The talent show a few years ago was fun.",
            "The school bus stops here.",
            "The poor need help.",
            "The team are meeting tomorrow.",
            "The police are on their way.",
            "If the cost were lower, we would buy it.",
            "I insist that the manager sign the form.",
            "These tools help identify the problem.",
            "The first build also resolves the packages.",
            "The strategy converts offsets to positions.",
            "A remote agent cannot inspect meetings.",
            "The maintained command definitions are in a file.",
            "The Hunger Games is a film.",
            "The plan is to slow the spread.",
            "The water still runs.",
            "Are the results in?",
            "Your going away party was fun.",
            "The summer break at school",
            "The weather we had was awful.",
            "This series are worth watching.",
            "She is one of the people who know the answer.",
            "The students who study pass.",
            "The car wash at the corner is open.",
            "The price drop this week surprised everyone.",
            "The day after the results were announced was quiet.",
            "The founder and CEO is here.",
            "Messages is a Mac app.",
            "We ran a backup restore drill (creates a project) last week.",
            "No integration build or inference yet.",
            "The small model still produced awkward wording.",
            "Its creamy texture and tangy taste make it ideal for desserts.",
            "The archive retains original path strings to preserve hashes.",
            "The students in my class are very smart.",
            "Politics is hard.",
            "Make sure the kids eat breakfast.",
        ] {
            assert!(fixes(text).is_empty(), "{text} -> {:?}", fixes(text));
        }
    }

    /// Checks every sentence and reports all that fail together, so one run names each of them.
    /// `want` is the fixes joined by " | ", or "" when the sentence should be left alone.
    fn assert_fixes(cases: &[(&str, &str)]) {
        let wrong: Vec<String> = cases
            .iter()
            .filter_map(|(text, want)| {
                let got = fixes(text).join(" | ");
                (got != *want).then(|| format!("{text} -> [{got}], wanted [{want}]"))
            })
            .collect();
        assert!(wrong.is_empty(), "\n{}\n", wrong.join("\n"));
    }

    // The tests below come in pairs. The first of each pair holds whatever part of speech Harper's
    // tagger gives the words: the rule decides on the words themselves. The second (`…_tagger`) also
    // needs the tagger to read the sentence the expected way, so a failure there may be the tagger.

    #[test]
    fn everyone_rule() {
        assert_fixes(&[
            ("Everybody are here.", "are>is"),
            // Orders and invitations, not mistakes.
            ("Everyone have a great weekend!", ""),
            ("Somebody do something!", ""),
            ("Everyone feel free to join.", ""),
            // "Like" that compares.
            ("Something like that would help.", ""),
            ("Someone like you deserves better.", ""),
            ("Nothing like that happened.", ""),
            // The subjunctive.
            ("It is vital that everyone have a say.", ""),
            ("Everyone but the managers is invited.", ""),
        ]);
    }

    #[test]
    fn everyone_rule_tagger() {
        assert_fixes(&[("Everyone like the idea.", "like>likes")]);
    }

    #[test]
    fn your_rule() {
        assert_fixes(&[
            ("Your a great friend.", "Your>You're"),
            ("Your not listening.", "Your>You're"),
            ("Your welcome.", "Your>You're"),
            ("Bring your A game.", ""),
        ]);
    }

    #[test]
    fn your_rule_tagger() {
        assert_fixes(&[("Your welcome mat is new.", "")]);
    }

    #[test]
    fn was_after_we_they_you() {
        assert_fixes(&[
            ("We was late.", "was>were"),
            ("You was right.", "was>were"),
            ("The email I sent you was long.", ""),
            ("The person who called you was my boss.", ""),
        ]);
    }

    /// Needs Harper to keep "wasn't" as one word.
    #[test]
    fn wasnt_after_they() {
        assert_fixes(&[("They wasn't ready.", "wasn't>weren't")]);
    }

    #[test]
    fn seen_and_done() {
        assert_fixes(&[("We done it.", "done>did"), ("They have done it.", "")]);
    }

    #[test]
    fn there_rule() {
        assert_fixes(&[
            ("There was several delays.", "was>were"),
            ("There are a number of issues.", ""),
            ("There are a variety of options.", ""),
            ("There is five dollars on the table.", ""),
        ]);
    }

    /// Needs the dictionary to list "problem" as a singular noun.
    #[test]
    fn there_were_one_thing() {
        assert_fixes(&[("There were a problem.", "were>was")]);
    }

    #[test]
    fn this_and_these() {
        assert_fixes(&[("This were a mistake.", "were>was"), ("Those was the days.", "was>were")]);
    }

    #[test]
    fn pronoun_pairs() {
        assert_fixes(&[
            ("Her and me went home.", "Her and me>She and I"),
            ("Me and them is ready.", "Me and them>They and I | is>are"),
        ]);
    }

    #[test]
    fn pronoun_pairs_tagger() {
        assert_fixes(&[("Me and her husband went to Paris.", "")]);
    }

    #[test]
    fn two_names() {
        assert_fixes(&[("Tom and Jerry is a cartoon.", ""), ("Romeo and Juliet is a play.", "")]);
    }

    /// Needs the dictionary to know "Tom" and "Anna" as names, as the older test above does.
    #[test]
    fn two_names_with_has() {
        assert_fixes(&[("Tom and Anna has a dog.", "has>have")]);
    }

    #[test]
    fn who_rule() {
        assert_fixes(&[
            ("I asked the students who was responsible.", ""),
            ("It doesn't matter to the voters who wins.", ""),
            ("The woman with the kids who lives next door is nice.", ""),
        ]);
    }

    #[test]
    fn who_rule_tagger() {
        assert_fixes(&[("The person who work here is kind.", "work>works")]);
    }

    #[test]
    fn that_before_a_plural() {
        assert_fixes(&[("I think that dogs are loud.", ""), ("She said that cats have nine lives.", "")]);
    }

    #[test]
    fn that_before_a_plural_tagger() {
        assert_fixes(&[("That shoes were expensive.", "That>Those")]);
    }

    #[test]
    fn to_and_too() {
        assert_fixes(&[
            ("I have been to cold and remote places.", ""),
            ("Of those cities, I have been to many.", ""),
        ]);
    }

    #[test]
    fn to_and_too_tagger() {
        assert_fixes(&[("The box is to big.", "to>too")]);
    }

    #[test]
    fn weather_or_not() {
        assert_fixes(&[("Weather or not it rains, we go.", "Weather>Whether")]);
    }

    #[test]
    fn unclear_plurals() {
        assert_fixes(&[("The phenomena are well known.", ""), ("The proceeds go to charity.", "")]);
    }

    #[test]
    fn a_line_that_starts_without_a_capital() {
        assert_fixes(&[("the results shows a trend.", "")]);
    }

    // Each of these is its own test, because each needs the tagger to read one particular sentence.

    #[test]
    fn tagger_older_brother() {
        assert_fixes(&[("My older brother work at a bank.", "work>works")]);
    }

    #[test]
    fn everyone_have_before_a_past_form() {
        assert_fixes(&[("Somebody have left the door open.", "have>has"), ("Someone have taken my seat.", "have>has")]);
        assert_fixes(&[("Everyone have a great weekend!", ""), ("Everyone have fun tonight.", "")]);
    }

    /// Not caught yet: "neither of the X" with a plain verb. Kept as a note of the gap; run with `--ignored`.
    #[test]
    #[ignore]
    fn tagger_neither_of() {
        assert_fixes(&[("Neither of the options work for us.", "work>works")]);
    }

    #[test]
    fn tagger_car_keys() {
        assert_fixes(&[("The car keys is on the table.", "is>are")]);
    }

    #[test]
    fn tagger_after_a_semicolon() {
        assert_fixes(&[("It rained; the roads was wet.", "was>were")]);
    }

    /// Also needs Harper to keep "isn’t", typed with a curly apostrophe, as one word.
    #[test]
    fn tagger_curly_apostrophe() {
        assert_fixes(&[("The results isn’t in.", "isn’t>aren't")]);
    }

    #[test]
    fn tagger_exclamation_mark() {
        assert_fixes(&[("The results shows it!", "shows>show")]);
    }

    #[test]
    fn tagger_two_lines() {
        assert_fixes(&[("The cost were high.\nMy friends is here.", "were>was | is>are")]);
    }

    #[test]
    fn tagger_watch_watches() {
        assert_fixes(&[("The teacher watch the class.", "watch>watches")]);
    }

    #[test]
    fn tagger_cry_cries() {
        assert_fixes(&[("The baby cry at night.", "cry>cries")]);
    }

    #[test]
    fn tagger_watches_watch() {
        assert_fixes(&[("The teachers watches the class.", "watches>watch")]);
    }

    #[test]
    fn tagger_cries_cry() {
        assert_fixes(&[("The babies cries at night.", "cries>cry")]);
    }

    #[test]
    fn tagger_go_goes() {
        assert_fixes(&[("The dog go outside every day.", "go>goes")]);
    }

    #[test]
    fn tagger_after_although() {
        assert_fixes(&[("We stayed although the rooms was cold.", "was>were")]);
    }

    /// A last line with no full stop is checked like a finished sentence ("The results shows a gain"
    /// typed into a message, with no full stop yet, must be underlined).
    #[test]
    fn a_line_without_a_full_stop() {
        assert_eq!(fixes("The results shows a gain"), ["shows>show"]);
        assert_eq!(fixes("The list of items are long"), ["are>is"]);
        assert_eq!(fixes("The list of items are"), ["are>is"]);
        assert_eq!(fixes("Notes from Monday\n\nThe list of items are long\n\nMore later."), ["are>is"]);
        assert_eq!(fixes("The managers wants an update by Friday\nThe report is late."), ["wants>want"]);
    }

    /// A line whose next line starts in lower case is the first half of a hand-wrapped sentence.
    #[test]
    fn a_wrapped_line_waits_for_its_full_stop() {
        assert_eq!(fixes("The word frequencies are derived from the data set, released under\nthe usual licence."), Vec::<String>::new());
        assert_eq!(fixes("The campaign engine resynchronizes only\nwhen the new name is saved."), Vec::<String>::new());
        assert_eq!(fixes("A later source fix at\n`12be46c` went in."), Vec::<String>::new());
    }

    /// A list item after a bullet is left alone, as it was: many are fragments ("- A front door for
    /// your team."), and two false alarms turned up in 312,000 words when they were checked.
    #[test]
    fn list_items_after_a_bullet_stay_quiet() {
        assert_eq!(fixes("- Buy milk\n- Call the bank\n- A front door for your team."), Vec::<String>::new());
    }

    /// A question is still left alone, with or without anything after it.
    #[test]
    fn a_question_is_not_a_statement() {
        assert_eq!(fixes("Are the results in?"), Vec::<String>::new());
        assert_eq!(fixes("What does the list of items show?"), Vec::<String>::new());
    }

    /// Headings and short fragments with no full stop stay quiet.
    #[test]
    fn headings_stay_quiet() {
        for text in ["The talent show", "The results page", "The awards shows", "Release notes", "The paint job on the cars", "How the checks work"] {
            assert_eq!(fixes(text), Vec::<String>::new(), "{text}");
        }
    }

    #[test]
    fn verb_before_that() {
        assert_eq!(fixes("The results shows that we won."), ["shows>show"]);
        assert_eq!(fixes("The report show that sales fell."), ["show>shows"]);
        // Two later verbs: the second may be the main one, so nothing is said.
        assert_eq!(fixes("The talent show that we won was fun."), Vec::<String>::new());
        assert_eq!(fixes("The report shows that we won."), Vec::<String>::new());
    }

    #[test]
    fn this_and_that_with_a_bare_verb() {
        assert_eq!(fixes("This give us a problem."), ["give>gives"]);
        assert_eq!(fixes("This make me happy."), ["make>makes"]);
        assert_eq!(fixes("That give them hope"), ["give>gives"]);
        for right in ["This gives us a problem.", "This put us in a bind.", "This let me see the plan.", "This place us in a bind.", "This will give us time.", "This gave us hope."] {
            assert_eq!(fixes(right), Vec::<String>::new(), "{right}");
        }
    }

    /// "The team have decided" is left alone on purpose: a group noun takes either verb, and the
    /// plural is the usual British form.
    #[test]
    fn group_nouns_take_either_verb() {
        assert_eq!(fixes("The team have decided."), Vec::<String>::new());
        assert_eq!(fixes("The team has decided."), Vec::<String>::new());
        assert_eq!(fixes("The committee are meeting today."), Vec::<String>::new());
    }
}
