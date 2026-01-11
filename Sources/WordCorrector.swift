import Foundation
import os

/// Simple word corrector using a user-defined dictionary.
/// Dictionary format: one entry per line, either:
///   - "word" (valid word, won't be changed)
///   - "wrong -> right" (replacement rule)
final class WordCorrector: @unchecked Sendable {
    private struct ReplacementRule {
        let regex: NSRegularExpression
        let replacement: String
    }

    private var validWords: Set<String> = []
    private var replacements: [String: String] = [:]
    private var replacementRules: [ReplacementRule] = []
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "corrector")
    
    static let shared: WordCorrector = {
        let corrector = WordCorrector()
        corrector.loadUserDictionary()
        return corrector
    }()
    
    private init() {}

    init(dictionaryContents: String) {
        parse(dictionaryContents)
    }
    
    private func loadUserDictionary() {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("com.speakeasy.app")
        
        guard let dictPath = supportDir?.appendingPathComponent("dictionary.txt"),
              FileManager.default.fileExists(atPath: dictPath.path) else {
            logger.debug("No user dictionary found")
            return
        }
        
        do {
            let content = try String(contentsOf: dictPath, encoding: .utf8)
            parse(content)
            logger.info("Loaded dictionary: \(self.validWords.count) words, \(self.replacements.count) replacements")
        } catch {
            logger.error("Failed to load dictionary: \(error.localizedDescription)")
        }
    }
    
    private func parse(_ content: String) {
        validWords.removeAll(keepingCapacity: true)
        replacements.removeAll(keepingCapacity: true)
        replacementRules.removeAll(keepingCapacity: true)

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            
            // Check for replacement rule: "wrong -> right"
            if let arrowRange = trimmed.range(of: "->") {
                let wrong = trimmed[..<arrowRange.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
                let right = trimmed[arrowRange.upperBound...].trimmingCharacters(in: .whitespaces)
                if !wrong.isEmpty && !right.isEmpty {
                    replacements[wrong] = right
                }
            } else {
                // Just a valid word
                validWords.insert(trimmed.lowercased())
            }
        }

        buildReplacementRules()
    }

    private func buildReplacementRules() {
        let keys = replacements.keys.sorted()
        replacementRules = keys.compactMap { wrong in
            guard let right = replacements[wrong] else {
                return nil
            }

            let escaped = NSRegularExpression.escapedPattern(for: wrong)
            let pattern = "\\b\(escaped)\\b"
            do {
                let regex = try NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                )
                return ReplacementRule(regex: regex, replacement: right)
            } catch {
                logger.error("Failed to compile regex for '\(wrong)': \(error.localizedDescription)")
                return nil
            }
        }
    }
    
    /// Correct text using the user dictionary.
    /// Returns the corrected text.
    func correct(_ text: String) -> String {
        guard !replacementRules.isEmpty else {
            return text
        }

        var result = text

        // Apply replacements (case-insensitive matching, preserve case in output)
        for rule in replacementRules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: rule.replacement
            )
        }

        return result
    }
}
