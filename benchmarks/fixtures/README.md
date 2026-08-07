# Benchmark fixtures

The benchmark consumes a private or redistributable corpus described by `manifest.json`. Copy `manifest.example.json` to `manifest.json`, place WAV files under `audio/`, and replace every example value with measured metadata and the file's SHA-256 digest.

`manifest.json` and `audio/` are ignored so personal recordings cannot be committed accidentally. A corpus intended for source control must include provenance, speaker consent, and a compatible redistribution license before removing those ignore rules.

## Audio contract

Every fixture must be:

- mono, 16 kHz WAV;
- finite PCM or float samples;
- accompanied by exact frame count, rounded duration, and SHA-256;
- assigned a stable ID and duration bucket;
- transcribed literally in `reference` without silently rewriting numbers or abbreviations.

Control fixtures such as silence or noise use `bucket: "control"` and `include_in_wer: false`. Invalid WAVs are test inputs for the validator, not corpus entries.

## Initial release corpus

Use 20 short (0.5–2 s), 20 medium (2–8 s), and 10 long (8–35 s) utterances, plus separate no-speech controls. Include technical terms, names, commands, numbers, punctuation, quiet speech, realistic noise, leading/trailing silence, and trailing plosive/fricative sounds.

The normalization contract is versioned as `wer-en-v1`: Unicode NFKC, lowercase lexical scoring, normalized apostrophes, punctuation removal, whitespace tokenization, and no numeric or abbreviation rewriting. Reports also retain a punctuation/case-sensitive score.
