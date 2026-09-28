import Foundation
import XCTest

// A small seeded property-testing harness.
//
// `forAll` draws values from a `Gen`, and on the first failure greedily
// shrinks the counterexample and reports it with the seed. Reproduce a
// failure with `SPEAKEASY_PROPERTY_SEED=<seed> swift test --filter <Test>`;
// raise coverage with `SPEAKEASY_PROPERTY_ITERATIONS`.

/// Deterministic, fast PRNG (SplitMix64) so every run is reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct Gen<Value> {
    let generate: (inout SplitMix64) -> Value
    /// Strictly "smaller" candidates tried, in order, while shrinking.
    let shrink: (Value) -> [Value]

    init(
        generate: @escaping (inout SplitMix64) -> Value,
        shrink: @escaping (Value) -> [Value] = { _ in [] }
    ) {
        self.generate = generate
        self.shrink = shrink
    }

    /// Transforms generated values. Shrinking is lost; shrink the source
    /// generator instead when a minimal counterexample matters.
    func map<T>(_ transform: @escaping (Value) -> T) -> Gen<T> {
        Gen<T> { rng in transform(generate(&rng)) }
    }
}

extension Gen {
    static func constant(_ value: Value) -> Gen<Value> {
        Gen { _ in value }
    }

    static func element(of values: [Value]) -> Gen<Value> {
        precondition(!values.isEmpty)
        return Gen { rng in values[Int.random(in: 0..<values.count, using: &rng)] }
    }

    /// Picks one generator per draw, weighted by the integer paired with it.
    static func frequency(_ weighted: [(Int, Gen<Value>)]) -> Gen<Value> {
        let total = weighted.reduce(0) { $0 + $1.0 }
        precondition(total > 0)
        return Gen { rng in
            var pick = Int.random(in: 0..<total, using: &rng)
            for (weight, gen) in weighted {
                if pick < weight { return gen.generate(&rng) }
                pick -= weight
            }
            return weighted[weighted.count - 1].1.generate(&rng)
        }
    }

    static func array<Element>(
        of element: Gen<Element>,
        count: ClosedRange<Int>
    ) -> Gen<[Element]> where Value == [Element] {
        Gen(
            generate: { rng in
                let length = Int.random(in: count, using: &rng)
                return (0..<length).map { _ in element.generate(&rng) }
            },
            shrink: { values in
                guard !values.isEmpty else { return [] }
                var candidates: [[Element]] = []
                if values.count > count.lowerBound {
                    // Halves first, then single removals.
                    if values.count / 2 >= count.lowerBound, values.count > 1 {
                        candidates.append(Array(values.prefix(values.count / 2)))
                        candidates.append(Array(values.suffix(values.count / 2)))
                    }
                    for index in values.indices {
                        var smaller = values
                        smaller.remove(at: index)
                        candidates.append(smaller)
                    }
                }
                for index in values.indices {
                    for replacement in element.shrink(values[index]) {
                        var smaller = values
                        smaller[index] = replacement
                        candidates.append(smaller)
                    }
                }
                return candidates
            }
        )
    }

}

/// Pairs two generators; shrinks each side independently.
func genZip<A, B>(_ a: Gen<A>, _ b: Gen<B>) -> Gen<(A, B)> {
    Gen(
        generate: { rng in (a.generate(&rng), b.generate(&rng)) },
        shrink: { pair in
            a.shrink(pair.0).map { ($0, pair.1) } + b.shrink(pair.1).map { (pair.0, $0) }
        }
    )
}

extension Gen where Value == Int {
    static func int(in range: ClosedRange<Int>) -> Gen<Int> {
        Gen(
            generate: { rng in Int.random(in: range, using: &rng) },
            shrink: { value in
                let target = range.contains(0) ? 0 : range.lowerBound
                guard value != target else { return [] }
                return [target, target + (value - target) / 2].filter { $0 != value }
            }
        )
    }
}

extension Gen where Value == String {
    /// Strings whose characters are drawn from `alphabet`.
    static func string(from alphabet: [Character], length: ClosedRange<Int>) -> Gen<String> {
        Gen<[Character]>.array(of: .element(of: alphabet), count: length).mapString()
    }

    /// Text built from `words` joined by generated separators.
    static func text(
        words: Gen<String>,
        separators: [String] = [" "],
        count: ClosedRange<Int>
    ) -> Gen<String> {
        Gen<[String]>.array(of: genZip(words, .element(of: separators)).map { $0.0 + $0.1 }, count: count)
            .mapJoined()
    }
}

extension Gen where Value == [Character] {
    /// Keeps shrinking by mapping each shrunk character array to a string.
    func mapString() -> Gen<String> {
        Gen<String>(
            generate: { rng in String(generate(&rng)) },
            shrink: { value in shrink(Array(value)).map { String($0) } }
        )
    }
}

extension Gen where Value == [String] {
    /// Joins generated pieces; shrinks the result by halves, then by
    /// removing single characters (bounded to the first 64).
    func mapJoined() -> Gen<String> {
        Gen<String>(
            generate: { rng in generate(&rng).joined() },
            shrink: { value in
                var candidates: [String] = []
                if value.count > 1 {
                    candidates.append(String(value.prefix(value.count / 2)))
                    candidates.append(String(value.suffix(value.count / 2)))
                }
                for index in value.indices.prefix(64) {
                    var smaller = value
                    smaller.remove(at: index)
                    candidates.append(smaller)
                }
                return candidates
            }
        )
    }
}

// MARK: - Runner

enum PropertyTesting {
    static var iterations: Int {
        ProcessInfo.processInfo.environment["SPEAKEASY_PROPERTY_ITERATIONS"].flatMap(Int.init) ?? 200
    }

    static var seed: UInt64 {
        ProcessInfo.processInfo.environment["SPEAKEASY_PROPERTY_SEED"].flatMap(UInt64.init)
            ?? UInt64.random(in: 0...UInt64.max)
    }
}

/// Checks `property` over generated values. On failure, shrinks to a
/// minimal counterexample and fails the test with the reproduction seed.
func forAll<Value>(
    _ gen: Gen<Value>,
    iterations: Int = PropertyTesting.iterations,
    seed: UInt64 = PropertyTesting.seed,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ property: (Value) -> Bool
) {
    var rng = SplitMix64(seed: seed)
    for iteration in 0..<iterations {
        let value = gen.generate(&rng)
        guard !property(value) else { continue }

        var minimal = value
        var steps = 0
        shrinking: while steps < 1_000 {
            for candidate in gen.shrink(minimal) where !property(candidate) {
                minimal = candidate
                steps += 1
                continue shrinking
            }
            break
        }
        XCTFail(
            """
            Property failed at iteration \(iteration) (SPEAKEASY_PROPERTY_SEED=\(seed)).
            Original: \(String(reflecting: value))
            Shrunk (\(steps) steps): \(String(reflecting: minimal))
            """,
            file: file,
            line: line
        )
        return
    }
}
