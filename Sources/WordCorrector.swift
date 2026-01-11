import Foundation
import os

/// Simple word corrector using a user-defined dictionary.
/// Dictionary format: one entry per line, either:
///   - "word" (valid word, won't be changed)
///   - "wrong -> right" (replacement rule)
final class WordCorrector: @unchecked Sendable {
    private var validWords: Set<String> = []
    private var replacements: [String: String] = [:]
    private let logger = Logger(subsystem: "com.speakeasy.app", category: "corrector")
    
    static let shared: WordCorrector = {
        let corrector = WordCorrector()
        corrector.loadUserDictionary()
        return corrector
    }()
    
    private init() {}
    
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
    }
    
    /// Correct text using the user dictionary.
    /// Returns the corrected text.
    func correct(_ text: String) -> String {
        guard !replacements.isEmpty else {
            return text
        }
        
        var result = text
        
        // Apply replacements (case-insensitive matching, preserve case in output)
        for (wrong, right) in replacements {
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b",
                with: right,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        return result
    }
}
