import Foundation
import LassoCore

/// One line returned by an OCR pass, plus its normalized left edge when the
/// platform OCR provider exposes geometry. This deliberately contains no Vision
/// types so layout decisions remain testable on Linux.
public struct OCRTextObservation: Sendable, Equatable {
    public var text: String
    public var minX: Double?

    public init(text: String, minX: Double? = nil) {
        self.text = text
        self.minX = minX
    }
}

public struct OCRTextSelection: Sendable, Equatable {
    public var text: String?
    public var layoutHint: TextLayout?

    public init(text: String?, layoutHint: TextLayout?) {
        self.text = text
        self.layoutHint = layoutHint
    }
}

/// Chooses between the corrected detection pass and the identifier-preserving
/// pass. The corrected text remains the fallback if the second pass yields no
/// usable text, so a code-layout classification cannot discard OCR data.
public enum OCRTextPolicy {
    public static func select(
        classifiedLayout: TextLayout,
        correctedText: String?,
        uncorrectedText: String?
    ) -> OCRTextSelection {
        switch classifiedLayout {
        case .code:
            return OCRTextSelection(
                text: normalized(uncorrectedText) ?? normalized(correctedText),
                layoutHint: .code
            )
        case .prose:
            return OCRTextSelection(
                text: normalized(correctedText) ?? normalized(uncorrectedText),
                layoutHint: nil
            )
        }
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}

/// Pure code-vs-prose policy for screen OCR (SPE-564). It combines textual code
/// signals with indentation/alignment rather than trusting any one identifier.
public enum TextLayoutClassifier {
    public static func classify(_ observations: [OCRTextObservation]) -> TextLayout {
        let lines = observations
            .map { OCRTextObservation(text: $0.text, minX: $0.minX) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { return .prose }

        let text = lines.map(\.text).joined(separator: "\n")
        let identifiers = words(in: text).filter(isCodeIdentifier)
        let keywords = words(in: text).filter(codeKeywords.contains)
        let visible = text.filter { !$0.isWhitespace }
        let symbols = visible.filter { codeSymbols.contains($0) }

        var score = 0
        if identifiers.count >= 2 { score += 2 }
        else if identifiers.count == 1 { score += 1 }
        if keywords.count >= 2 { score += 2 }
        else if keywords.count == 1 { score += 1 }
        if !visible.isEmpty && Double(symbols.count) / Double(visible.count) >= 0.06 {
            score += 2
        }
        if hasIndentation(lines) { score += 1 }
        if looksLikeStackTraceOrDiagnostic(text) { score += 3 }

        return score >= 3 ? .code : .prose
    }

    private static let codeKeywords: Set<String> = [
        "class", "enum", "func", "import", "let", "return", "struct", "throw", "throws", "var",
    ]

    private static let codeSymbols = Set("{}[]()=;:<>/\\|&!+*%#@\"`")

    private static func words(in text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
    }

    private static func isCodeIdentifier(_ word: String) -> Bool {
        let chars = Array(word)
        let hasSnakeCase = chars.indices.dropFirst().contains { i in
            chars[i] == "_" && i + 1 < chars.count && chars[i - 1].isLetter && chars[i + 1].isLetter
        }
        let hasCamelCase = chars.indices.dropFirst().contains { i in
            chars[i].isUppercase && chars[i - 1].isLowercase
        }
        return hasSnakeCase || hasCamelCase
    }

    private static func hasIndentation(_ lines: [OCRTextObservation]) -> Bool {
        if lines.contains(where: { $0.text.first?.isWhitespace == true }) { return true }
        let edges = lines.compactMap(\.minX)
        guard let left = edges.min() else { return false }
        return edges.contains { $0 - left >= 0.02 }
    }

    private static func looksLikeStackTraceOrDiagnostic(_ text: String) -> Bool {
        let lower = text.lowercased()
        let hasStackFrame = lower.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("at ") && (trimmed.contains("(") || trimmed.contains(":"))
        }
        return lower.contains("error:") || lower.contains("exception:")
            || lower.contains("stack trace") || hasStackFrame
            || lower.contains(".swift:") || lower.contains(".js:") || lower.contains(".ts:")
    }
}
