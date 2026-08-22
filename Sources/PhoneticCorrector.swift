import Foundation

/// A domain term taught to the phonetic corrector: how the ASR model tends
/// to hear it, and what should actually be written.
struct PhoneticTerm: Equatable, Sendable {
    /// A canonical spelling inserted into the transcript, e.g. `"cuDNN"`.
    let canonical: String
    /// Heard spellings that should be rewritten to `canonical`, e.g.
    /// `["koo dnn", "cu dnn"]`.
    let spokenForms: [String]

    init(canonical: String, spokenForms: [String]) {
        self.canonical = canonical
        self.spokenForms = spokenForms
    }
}

enum PhoneticCorrectorError: Error, Equatable {
    case tooManyTerms(Int)
    case canonicalIsEmpty(index: Int)
    case canonicalIsTooLong(index: Int, count: Int)
    case spokenFormIsEmpty(index: Int, formIndex: Int)
    case spokenFormIsTooLong(index: Int, formIndex: Int, count: Int)
    case duplicateSpokenForm(index: Int, duplicateOf: Int)
}

/// Deterministic pre-correction that rescues domain terms ASR mishears,
/// before exact-match corrections and spoken commands run.
///
/// Each spoken form is indexed two ways at initialization:
///
/// - **Consonant-skeleton keys** capture how a word sounds once vowels are
///   stripped (`"kudo"` and `"cuda"` both become `"kd"`). Multi-word forms
///   match whole windows of the same word count, so `"v llm"` rewrites to
///   `"vLLM"` without touching neighboring words.
/// - **Edit-distance entries** catch near-misses on longer words
///   (Levenshtein ≤ 1, or ≤ 2 for words of six-plus characters).
///
/// Negative guards keep the rewriter conservative: single-word edit-distance
/// matches must share their first letter and span at least five characters;
/// skeleton keys claimed by two distinct terms are dropped as ambiguous;
/// matches never overlap (leftmost, longest, highest-tier wins); and
/// replacements always come from the taught canonical spelling, never a
/// guess. Initialization compiles all indexes; `correct` only tokenizes and
/// walks them.
struct PhoneticCorrector: Sendable {
    static let maxTerms = 128
    static let maxCanonicalCharacters = 128
    static let maxSpokenFormCharacters = 128

    private static let vowelSet: Set<Character> = ["a", "e", "i", "o", "u", "y"]
    /// Words shorter than this never match through edit distance.
    private static let minimumEditDistanceLength = 5
    /// Edit distance allowed on words of at least six characters.
    private static let relaxedEditDistance = 2

    private struct CompiledForm: Sendable {
        /// Normalized words of the spoken form.
        let words: [String]
        /// Per-word consonant skeletons, parallel to `words`.
        let skeletons: [String]
        /// Joined skeleton used as the multi-word window key.
        let windowKey: String
        let canonical: String
    }

    private struct WindowEntry: Sendable {
        let form: CompiledForm
    }

    private struct EditDistanceEntry: Sendable {
        let word: String
        let canonical: String
    }

    private let forms: [CompiledForm]
    private let windowsBySkeleton: [String: WindowEntry]
    private let skeletonsByWord: [String: String]
    private let editDistanceEntries: [EditDistanceEntry]

    init(terms: [PhoneticTerm]) throws {
        guard terms.count <= Self.maxTerms else {
            throw PhoneticCorrectorError.tooManyTerms(terms.count)
        }

        var forms: [CompiledForm] = []
        var seenFormKeys: [String: Int] = [:]
        var windowCandidates: [String: CompiledForm] = [:]
        var ambiguousWindowKeys: Set<String> = []
        var skeletonCandidates: [String: String] = [:]
        var ambiguousSkeletons: Set<String> = []

        func compile(_ formWords: [String], canonical: String) -> CompiledForm {
            let skeletons = formWords.map(Self.phoneticSkeleton)
            return CompiledForm(
                words: formWords,
                skeletons: skeletons,
                windowKey: skeletons.joined(separator: "\u{1F}"),
                canonical: canonical
            )
        }

        for (index, term) in terms.enumerated() {
            let canonicalCount = term.canonical.count
            guard !term.canonical.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw PhoneticCorrectorError.canonicalIsEmpty(index: index)
            }
            guard canonicalCount <= Self.maxCanonicalCharacters else {
                throw PhoneticCorrectorError.canonicalIsTooLong(index: index, count: canonicalCount)
            }

            for (formIndex, spokenForm) in term.spokenForms.enumerated() {
                let formCount = spokenForm.count
                guard !spokenForm.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw PhoneticCorrectorError.spokenFormIsEmpty(
                        index: index,
                        formIndex: formIndex
                    )
                }
                guard formCount <= Self.maxSpokenFormCharacters else {
                    throw PhoneticCorrectorError.spokenFormIsTooLong(
                        index: index,
                        formIndex: formIndex,
                        count: formCount
                    )
                }

                let words = TranscriptPostProcessor.tokens(in: spokenForm)
                    .map(\.normalized)
                guard !words.isEmpty else {
                    throw PhoneticCorrectorError.spokenFormIsEmpty(
                        index: index,
                        formIndex: formIndex
                    )
                }

                let formKey = words.joined(separator: "\u{1F}")
                if let previousIndex = seenFormKeys[formKey] {
                    throw PhoneticCorrectorError.duplicateSpokenForm(
                        index: index,
                        duplicateOf: previousIndex
                    )
                }
                seenFormKeys[formKey] = index

                let form = compile(words, canonical: term.canonical)
                forms.append(form)

                // Skeleton keys claimed by distinct terms are unusable;
                // duplicate claims by the same term keep the first form.
                if let previous = windowCandidates[form.windowKey] {
                    if previous.canonical != term.canonical {
                        ambiguousWindowKeys.insert(form.windowKey)
                    }
                } else {
                    windowCandidates[form.windowKey] = form
                }

                if words.count == 1, !form.skeletons[0].isEmpty {
                    let skeleton = form.skeletons[0]
                    if let previous = skeletonCandidates[skeleton], previous != term.canonical {
                        ambiguousSkeletons.insert(skeleton)
                    } else {
                        skeletonCandidates[skeleton] = term.canonical
                    }
                }
            }
        }

        var windowsBySkeleton: [String: WindowEntry] = [:]
        for (key, entry) in windowCandidates where !ambiguousWindowKeys.contains(key) {
            windowsBySkeleton[key] = WindowEntry(form: entry)
        }
        self.windowsBySkeleton = windowsBySkeleton

        var skeletonsByWord: [String: String] = [:]
        for form in forms where form.words.count == 1 {
            let skeleton = form.skeletons[0]
            guard !skeleton.isEmpty, !ambiguousSkeletons.contains(skeleton) else { continue }
            skeletonsByWord[skeleton] = form.canonical
        }
        self.skeletonsByWord = skeletonsByWord

        var editDistanceEntries: [EditDistanceEntry] = []
        var seenEditWords: Set<String> = []
        for form in forms where form.words.count == 1 {
            let word = form.words[0]
            guard word.count >= Self.minimumEditDistanceLength else { continue }
            if seenEditWords.insert(word).inserted {
                editDistanceEntries.append(
                    EditDistanceEntry(word: word, canonical: form.canonical)
                )
            }
        }
        self.editDistanceEntries = editDistanceEntries
        self.forms = forms
    }

    /// Rewrites misheard term occurrences in `text`, leaving everything
    /// else — including punctuation and spacing — byte-identical.
    func correct(_ text: String) -> String {
        guard !windowsBySkeleton.isEmpty || !skeletonsByWord.isEmpty || !editDistanceEntries.isEmpty else {
            return text
        }
        let tokens = TranscriptPostProcessor.tokens(in: text)
        let words = tokens.filter { !$0.normalized.isEmpty && $0.hasLetterOrNumber }
        guard words.count > 0 else { return text }

        var candidates: [Candidate] = []
        for windowSize in stride(from: maxWordWindowSize, through: 1, by: -1) {
            guard words.count >= windowSize else { continue }
            var start = 0
            while start + windowSize <= words.count {
                defer { start += 1 }
                if windowSize > 1 {
                    appendWindowCandidate(
                        words: words,
                        start: start,
                        windowSize: windowSize,
                        into: &candidates
                    )
                } else {
                    appendSingleWordCandidates(word: words[start], into: &candidates)
                }
            }
        }

        guard !candidates.isEmpty else { return text }
        let selected = selectNonOverlapping(candidates)
        guard !selected.isEmpty else { return text }

        var output = text
        for candidate in selected.sorted(by: { left, right in
            left.range.lowerBound > right.range.lowerBound
        }) {
            output.replaceSubrange(candidate.range, with: candidate.replacement)
        }
        return output
    }

    // MARK: - Matching internals

    private struct Candidate {
        let range: Range<String.Index>
        let replacement: String
        /// Higher wins ties at the same position: whole-window skeleton
        /// matches beat single-word skeleton matches beat edit distance.
        let tier: Int
        /// Character count of the matched span; longer wins remaining ties.
        let width: Int
    }

    private var maxWordWindowSize: Int {
        forms.map(\.words.count).max() ?? 1
    }

    private func appendWindowCandidate(
        words: [TranscriptPostProcessor.Token],
        start: Int,
        windowSize: Int,
        into candidates: inout [Candidate]
    ) {
        var skeletons: [String] = []
        skeletons.reserveCapacity(windowSize)
        for offset in 0..<windowSize {
            skeletons.append(Self.phoneticSkeleton(words[start + offset].normalized))
        }
        let key = skeletons.joined(separator: "\u{1F}")
        guard let entry = windowsBySkeleton[key] else { return }
        candidates.append(Candidate(
            range: words[start].range.lowerBound..<words[start + windowSize - 1].range.upperBound,
            replacement: entry.form.canonical,
            tier: 3,
            width: windowSize
        ))
    }

    private func appendSingleWordCandidates(
        word: TranscriptPostProcessor.Token,
        into candidates: inout [Candidate]
    ) {
        let skeleton = Self.phoneticSkeleton(word.normalized)
        if !skeleton.isEmpty, let canonical = skeletonsByWord[skeleton] {
            candidates.append(Candidate(
                range: word.range,
                replacement: canonical,
                tier: 2,
                width: word.normalized.count
            ))
        }

        guard word.normalized.count >= Self.minimumEditDistanceLength else { return }
        for entry in editDistanceEntries {
            let limit = entry.word.count >= 6 ? Self.relaxedEditDistance : 1
            guard entry.word.first == word.normalized.first else { continue }
            guard abs(entry.word.count - word.normalized.count) <= limit else { continue }
            if Self.levenshtein(entry.word, word.normalized, limit: limit) <= limit {
                candidates.append(Candidate(
                    range: word.range,
                    replacement: entry.canonical,
                    tier: 1,
                    width: entry.word.count
                ))
                return
            }
        }
    }

    private func selectNonOverlapping(_ candidates: [Candidate]) -> [Candidate] {
        func order(_ left: Candidate, _ right: Candidate) -> Bool {
            if left.range.lowerBound != right.range.lowerBound {
                return left.range.lowerBound < right.range.lowerBound
            }
            if left.tier != right.tier {
                return left.tier > right.tier
            }
            return left.width > right.width
        }
        let ordered = candidates.sorted(by: order)

        var selected: [Candidate] = []
        var lastUpperBound: String.Index?
        for candidate in ordered {
            let start = candidate.range.lowerBound
            if let lastUpperBound, start < lastUpperBound {
                continue
            }
            selected.append(candidate)
            lastUpperBound = candidate.range.upperBound
        }
        return selected
    }

    // MARK: - Static helpers

    /// Consonant skeleton of a normalized word: letters and digits survive,
    /// `c`/`q` fold into `k`, vowels (`a e i o u y`) are dropped, and
    /// adjacent duplicate characters collapse — within this word only.
    static func phoneticSkeleton(_ word: String) -> String {
        var output = ""
        output.reserveCapacity(word.count)
        var lastScalar: Character?
        for character in TranscriptPostProcessor.normalize(word) {
            guard character.isLetter || character.isNumber else { continue }
            var mapped = character
            if character == "c" || character == "q" {
                mapped = "k"
            }
            guard !Self.vowelSet.contains(mapped) else { continue }
            if mapped == lastScalar { continue }
            output.append(mapped)
            lastScalar = mapped
        }
        return output
    }

    /// Capped Levenshtein distance; returns `limit + 1` once exceeded so
    /// typical near-matches exit early.
    static func levenshtein(_ left: String, _ right: String, limit: Int) -> Int {
        if abs(left.count - right.count) > limit { return limit + 1 }
        if left == right { return 0 }

        var previousRow = Array(0...right.count)
        var currentRow = [Int](repeating: 0, count: right.count + 1)

        for (rowIndex, leftCharacter) in left.enumerated() {
            currentRow[0] = rowIndex + 1
            var rowMinimum = currentRow[0]
            for (columnIndex, rightCharacter) in right.enumerated() {
                let insertion = previousRow[columnIndex + 1] + 1
                let deletion = currentRow[columnIndex] + 1
                let substitution = previousRow[columnIndex]
                    + (leftCharacter == rightCharacter ? 0 : 1)
                let value = min(insertion, deletion, substitution)
                currentRow[columnIndex + 1] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previousRow, &currentRow)
        }
        return previousRow[right.count]
    }
}
