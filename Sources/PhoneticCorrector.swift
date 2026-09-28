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
    // Common speech must never be turned into a taught technical term.
    private static let commonWords: Set<String> = Set("""
    a about above across act after again against age ago air all almost along already also always am an and another any anyone anything are area around as ask at away back bad be because become been before began begin behind being best better between big both bring but by call came can car care case change child children city clear close code come common could country course cut day days did different do does done down during each early earth easy end enough even ever every example eye face fact family far fast father feel few find first five for form found four free friend from full game gave get girl give go god going good got great group grow had half hand happen hard has have he head hear heard heart help her here high him his history home hope hot hour house how however human i if important in include inside into is it its itself just keep kind know known land large last later law lead learn leave left less let life light like line little live local long look lost lot love low made main make man many may me mean men might mind miss more most mother move much must my name near need never new next night no not nothing now number of off often old on once one only open or order other our out over own part past people perhaps person place plan play point possible power present problem public put question quite rather real really reason red remember result right room run said same saw say school see seem set seven she short should show side since six small so some someone something sometimes soon sound start state still stop story such sure system take talk tell ten than thank thanks that the their them then there these they thing things think this those though thought three through time to today together too took top true try turn two under understand until up upon us use used using usual very voice wait want was water way we well went were what when where which while white who whole why will with within without woman women word work world would write wrong year years yes yet you young your
    able account actually add address adult afternoon ahead allow alone although amount animal answer appear apple arm art attention available baby ball bank base beautiful bed begin beginning believe black blood blue board body book born box boy break brother build building business busy buy camera chance character check class clean clock cold college color company complete condition continue control cost create current dark data daughter deal death decide deep demand design develop die difference difficult dinner direct direction doctor door drive drop due eat education effect effort either else employ energy enjoy enter environment especially establish evening event exact expect experience explain express fall fear field figure fill final fine fire fish floor fly follow food foot force foreign forget forward future front future garden general get given glass goal government green ground hair happen happy health heavy held hit hold horse hospital idea imagine increase industry information instead interest issue job join key kitchen language late laugh lay letter listen long longer machine major market matter measure meeting member memory middle minute model money month morning mostly music natural nature nearly necessary network news nice nobody normal north note notice object office oil option outside page paper parent pass pay peace phone physical picture piece pitch plant police policy position price probably produce project provide quality reach ready receive record reduce relationship remain report research rest return rich ride river road rock role rule safe save science search season second security seem sense series serious service shape share shoot sight similar simple single sit situation size sleep slow social society son song sorry sort source space speak special speed spend sport spring stand star stay step stock store street strong student study style subject success summer support table task teach teacher team technology test theory third throw thus title tool town trade train travel treatment tree trouble trust truth unit university value video view visit volume walk wall war watch week weight west whether wife window wish wonder worry worth yesterday
    """.split(separator: " ").map(String.init))

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

        // Normalization-driven skeleton computation dominates this pass;
        // compute each unique word's skeleton exactly once.
        var skeletonCache: [String: String] = [:]
        func cachedSkeleton(_ normalized: String) -> String {
            if let cached = skeletonCache[normalized] {
                return cached
            }
            let computed = Self.phoneticSkeleton(normalized)
            skeletonCache[normalized] = computed
            return computed
        }

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
                        skeletonOf: cachedSkeleton,
                        into: &candidates
                    )
                } else {
                    appendSingleWordCandidates(
                        word: words[start],
                        skeletonOf: cachedSkeleton,
                        into: &candidates
                    )
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
        skeletonOf: (String) -> String,
        into candidates: inout [Candidate]
    ) {
        var skeletons: [String] = []
        skeletons.reserveCapacity(windowSize)
        for offset in 0..<windowSize {
            skeletons.append(skeletonOf(words[start + offset].normalized))
        }
        let window = words[start..<(start + windowSize)]
        guard window.reduce(0, { $0 + $1.normalized.count }) >= 4,
              window.allSatisfy({ !Self.commonWords.contains($0.normalized) }) else { return }
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
        skeletonOf: (String) -> String,
        into candidates: inout [Candidate]
    ) {
        guard word.normalized.count >= 4,
              !Self.commonWords.contains(word.normalized) else { return }
        let skeleton = skeletonOf(word.normalized)
        if !skeleton.isEmpty, let canonical = skeletonsByWord[skeleton],
           word.normalized.count < 5 || forms.contains(where: {
               $0.words.count == 1 && $0.windowKey == skeleton && $0.words[0].first == word.normalized.first
           }) {
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
