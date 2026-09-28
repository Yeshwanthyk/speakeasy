import Foundation
import XCTest

// A bounded mutation fuzzer that runs inside XCTest.
//
// Xcode's Swift toolchain does not ship libFuzzer, so this harness trades
// coverage guidance for zero setup. Every run first replays the checked-in
// corpus at `Fuzz/Corpus/<target>/`, then mutates corpus entries for a small
// budget. Failures (a thrown `FuzzFailure`) are written to
// `Fuzz/Findings/<target>/`; move a finding into the corpus once fixed.
//
//   SPEAKEASY_FUZZ_SECONDS=60  run each target for 60 s instead of the default
//   SPEAKEASY_FUZZ_SEED=<n>    reproduce a run (the seed is printed)
//
// A crash (trap) ends the test process; rerun with the printed seed to
// reproduce it deterministically. `script/fuzz.sh` wraps both variables.

struct FuzzFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Throws `FuzzFailure` when `condition` is false.
func fuzzCheck(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
    if !condition() {
        throw FuzzFailure(message())
    }
}

enum Fuzzing {
    static let defaultIterations = 1_500
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // SpeakeasyTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()

    static func corpusDirectory(_ target: String) -> URL {
        repositoryRoot.appendingPathComponent("Fuzz/Corpus/\(target)", isDirectory: true)
    }

    static func findingsDirectory(_ target: String) -> URL {
        repositoryRoot.appendingPathComponent("Fuzz/Findings/\(target)", isDirectory: true)
    }

    static func loadCorpus(_ target: String) -> [(name: String, data: Data)] {
        let directory = corpusDirectory(target)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                return nil
            }
            return (name, data)
        }
    }

    fileprivate static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }
}

/// Replays the corpus for `target`, then fuzzes `body` with mutated inputs.
/// `body` throws `FuzzFailure` when an invariant breaks.
func fuzz(
    _ target: String,
    dictionary: [String] = [],
    maxInputBytes: Int = 4_096,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: (Data) throws -> Void
) {
    let corpus = Fuzzing.loadCorpus(target)
    guard !corpus.isEmpty else {
        XCTFail("No seed corpus at \(Fuzzing.corpusDirectory(target).path)", file: file, line: line)
        return
    }

    for entry in corpus {
        do {
            try body(entry.data)
        } catch {
            XCTFail("Corpus entry \(target)/\(entry.name) failed: \(error)", file: file, line: line)
            return
        }
    }

    let seed = Fuzzing.environment["SPEAKEASY_FUZZ_SEED"].flatMap(UInt64.init)
        ?? UInt64.random(in: 0...UInt64.max)
    let deadline = Fuzzing.environment["SPEAKEASY_FUZZ_SECONDS"].flatMap(Double.init)
        .map { Date().addingTimeInterval($0) }
    print("fuzz[\(target)] seed=\(seed) corpus=\(corpus.count)")

    var mutator = FuzzMutator(
        seed: seed,
        pool: corpus.map { [UInt8]($0.data) },
        dictionary: dictionary.map { Array($0.utf8) },
        maxInputBytes: maxInputBytes
    )
    var iteration = 0
    while deadline.map({ Date() < $0 }) ?? (iteration < Fuzzing.defaultIterations) {
        iteration += 1
        let input = Data(mutator.next())
        do {
            try body(input)
        } catch {
            let path = saveFinding(input, target: target)
            XCTFail(
                """
                fuzz[\(target)] failed at iteration \(iteration) (SPEAKEASY_FUZZ_SEED=\(seed)): \(error)
                Input saved to \(path)
                """,
                file: file,
                line: line
            )
            return
        }
    }
    print("fuzz[\(target)] ran \(iteration) mutated inputs")
}

private func saveFinding(_ input: Data, target: String) -> String {
    let directory = Fuzzing.findingsDirectory(target)
    // FNV-1a keeps finding names stable across runs.
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in input {
        hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
    let url = directory.appendingPathComponent(String(format: "%016llx", hash))
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try input.write(to: url)
        return url.path
    } catch {
        return "(not saved: \(error)); base64 \(input.base64EncodedString())"
    }
}

private struct FuzzMutator {
    private static let interestingBytes: [UInt8] = [
        0x00, 0x01, 0x09, 0x0A, 0x0D, 0x20, 0x22, 0x2C, 0x2D, 0x2E, 0x3A,
        0x5B, 0x5C, 0x5D, 0x7B, 0x7D, 0x7F, 0x80, 0xBF, 0xC0, 0xE2, 0xF0, 0xFF,
    ]

    private var rng: SplitMix64
    private let pool: [[UInt8]]
    private let dictionary: [[UInt8]]
    private let maxInputBytes: Int

    init(seed: UInt64, pool: [[UInt8]], dictionary: [[UInt8]], maxInputBytes: Int) {
        self.rng = SplitMix64(seed: seed)
        self.pool = pool
        self.dictionary = dictionary
        self.maxInputBytes = maxInputBytes
    }

    mutating func next() -> [UInt8] {
        var bytes = pool[random(pool.count)]
        for _ in 0...random(4) {
            mutate(&bytes)
        }
        if bytes.count > maxInputBytes {
            bytes.removeLast(bytes.count - maxInputBytes)
        }
        return bytes
    }

    private mutating func random(_ upperBound: Int) -> Int {
        upperBound <= 0 ? 0 : Int.random(in: 0..<upperBound, using: &rng)
    }

    private mutating func mutate(_ bytes: inout [UInt8]) {
        switch random(8) {
        case 0 where !bytes.isEmpty:
            let index = random(bytes.count)
            bytes[index] ^= UInt8(1 << random(8))
        case 1 where !bytes.isEmpty:
            bytes[random(bytes.count)] = Self.interestingBytes[random(Self.interestingBytes.count)]
        case 2:
            bytes.insert(UInt8(truncatingIfNeeded: rng.next()), at: random(bytes.count + 1))
        case 3 where !bytes.isEmpty:
            let start = random(bytes.count)
            let length = 1 + random(min(16, bytes.count - start))
            bytes.removeSubrange(start..<(start + length))
        case 4 where !bytes.isEmpty:
            let start = random(bytes.count)
            let length = 1 + random(min(32, bytes.count - start))
            bytes.insert(contentsOf: bytes[start..<(start + length)], at: random(bytes.count + 1))
        case 5 where !dictionary.isEmpty, 6 where !dictionary.isEmpty:
            bytes.insert(contentsOf: dictionary[random(dictionary.count)], at: random(bytes.count + 1))
        default:
            let other = pool[random(pool.count)]
            let head = bytes.prefix(random(bytes.count + 1))
            let tail = other.suffix(random(other.count + 1))
            bytes = Array(head) + Array(tail)
        }
    }
}
