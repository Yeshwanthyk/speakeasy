use serde::{Deserialize, Serialize};
use unicode_categories::UnicodeCategories;
use unicode_normalization::UnicodeNormalization;

pub const NORMALIZATION_VERSION: &str = "wer-en-v1";

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct EditCounts {
    pub substitutions: u64,
    pub deletions: u64,
    pub insertions: u64,
}

impl EditCounts {
    pub fn errors(self) -> u64 {
        self.substitutions + self.deletions + self.insertions
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct WordErrorScore {
    pub normalization_version: String,
    pub reference_words: u64,
    pub hypothesis_words: u64,
    pub edits: EditCounts,
    pub word_error_rate: Option<f64>,
    pub exact_match: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TranscriptScore {
    pub lexical: WordErrorScore,
    pub punctuation_sensitive: WordErrorScore,
}

pub fn score_transcript(reference: &str, hypothesis: &str) -> TranscriptScore {
    TranscriptScore {
        lexical: score_tokens(
            &normalize_lexical(reference),
            &normalize_lexical(hypothesis),
        ),
        punctuation_sensitive: score_tokens(
            &normalize_sensitive(reference),
            &normalize_sensitive(hypothesis),
        ),
    }
}

pub fn normalize_lexical(value: &str) -> Vec<String> {
    let normalized = normalize_apostrophes(value);
    let mut cleaned = String::with_capacity(normalized.len());
    for character in normalized.chars() {
        if character == '\'' || !character.is_punctuation() {
            cleaned.extend(character.to_lowercase());
        } else {
            cleaned.push(' ');
        }
    }
    tokenize(&cleaned)
}

pub fn normalize_sensitive(value: &str) -> Vec<String> {
    tokenize(&normalize_apostrophes(value))
}

fn normalize_apostrophes(value: &str) -> String {
    value
        .nfkc()
        .map(|character| match character {
            '\u{2018}' | '\u{2019}' | '\u{201B}' | '\u{02BC}' | '\u{FF07}' => '\'',
            _ => character,
        })
        .collect()
}

fn tokenize(value: &str) -> Vec<String> {
    value
        .split_whitespace()
        .map(str::to_owned)
        .collect::<Vec<_>>()
}

fn score_tokens(reference: &[String], hypothesis: &[String]) -> WordErrorScore {
    let edits = edit_counts(reference, hypothesis);
    let reference_words = reference.len() as u64;
    let hypothesis_words = hypothesis.len() as u64;
    let word_error_rate = if reference_words == 0 {
        None
    } else {
        Some(edits.errors() as f64 / reference_words as f64)
    };

    WordErrorScore {
        normalization_version: NORMALIZATION_VERSION.into(),
        reference_words,
        hypothesis_words,
        edits,
        word_error_rate,
        exact_match: reference == hypothesis,
    }
}

fn edit_counts(reference: &[String], hypothesis: &[String]) -> EditCounts {
    #[derive(Clone, Copy, Debug, Default)]
    struct Cell {
        distance: u64,
        edits: EditCounts,
    }

    let width = hypothesis.len() + 1;
    let mut cells = vec![Cell::default(); (reference.len() + 1) * width];
    for index in 1..=reference.len() {
        cells[index * width] = Cell {
            distance: index as u64,
            edits: EditCounts {
                deletions: index as u64,
                ..EditCounts::default()
            },
        };
    }
    for (index, cell) in cells
        .iter_mut()
        .enumerate()
        .take(hypothesis.len() + 1)
        .skip(1)
    {
        *cell = Cell {
            distance: index as u64,
            edits: EditCounts {
                insertions: index as u64,
                ..EditCounts::default()
            },
        };
    }

    for reference_index in 1..=reference.len() {
        for hypothesis_index in 1..=hypothesis.len() {
            let current = reference_index * width + hypothesis_index;
            let diagonal = (reference_index - 1) * width + hypothesis_index - 1;
            if reference[reference_index - 1] == hypothesis[hypothesis_index - 1] {
                cells[current] = cells[diagonal];
                continue;
            }

            let mut substitution = cells[diagonal];
            substitution.distance += 1;
            substitution.edits.substitutions += 1;

            let mut deletion = cells[(reference_index - 1) * width + hypothesis_index];
            deletion.distance += 1;
            deletion.edits.deletions += 1;

            let mut insertion = cells[reference_index * width + hypothesis_index - 1];
            insertion.distance += 1;
            insertion.edits.insertions += 1;

            cells[current] = [substitution, deletion, insertion]
                .into_iter()
                .min_by_key(|cell| cell.distance)
                .expect("three edit candidates");
        }
    }

    cells[reference.len() * width + hypothesis.len()].edits
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lexical_normalization_handles_unicode_case_punctuation_and_apostrophes() {
        assert_eq!(
            normalize_lexical("  HéLLo—don’t  42! "),
            vec!["héllo", "don't", "42"]
        );
    }

    #[test]
    fn scoring_counts_substitutions_deletions_and_insertions() {
        let substitution = score_transcript("one two three", "one four three");
        assert_eq!(substitution.lexical.edits.substitutions, 1);
        assert_eq!(substitution.lexical.word_error_rate, Some(1.0 / 3.0));

        let deletion = score_transcript("one two three", "one three");
        assert_eq!(deletion.lexical.edits.deletions, 1);

        let insertion = score_transcript("one three", "one two three");
        assert_eq!(insertion.lexical.edits.insertions, 1);
    }

    #[test]
    fn punctuation_sensitive_score_preserves_case_and_punctuation_differences() {
        let score = score_transcript("Hello, world.", "hello world");

        assert!(score.lexical.exact_match);
        assert!(!score.punctuation_sensitive.exact_match);
    }

    #[test]
    fn empty_reference_has_no_wer_but_tracks_insertions() {
        let score = score_transcript("", "unexpected words");

        assert_eq!(score.lexical.word_error_rate, None);
        assert_eq!(score.lexical.edits.insertions, 2);
        assert!(!score.lexical.exact_match);
    }

    #[test]
    fn numbers_are_not_rewritten() {
        let score = score_transcript("schedule it for 4", "schedule it for four");
        assert_eq!(score.lexical.edits.substitutions, 1);
    }
}
