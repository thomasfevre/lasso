import Foundation

/// SPE-562: redaction of secrets from a Capture's text before it is stored.
///
/// Lasso hands on-screen pixels and their recognized text to an agent that may
/// log or transmit them, so a terminal, an `.env` in an editor, or an authed
/// dashboard under the gesture could leak a live credential. Redaction is a
/// best-effort defense-in-depth precondition, on by default at the Conductor
/// write boundary — not a guarantee. This type is a pure function so it is
/// testable everywhere (it builds on Linux); the pixel blur that pairs with it
/// lives in the macOS Conductor.
public enum SecretRedactor {
    /// The token substituted for every matched secret.
    public static let placeholder = "[REDACTED]"

    /// A single secret found in a string.
    public struct Match: Equatable, Sendable {
        /// A short kind label (e.g. "jwt", "openai-key") for diagnostics.
        public let kind: String
        /// The exact substring that matched — the value the pixel blur looks for
        /// in each OCR observation. This holds the raw secret in memory: it must
        /// never be logged, persisted, or surfaced in a UI.
        public let value: String

        public init(kind: String, value: String) {
            self.kind = kind
            self.value = value
        }
    }

    /// The outcome of redacting a string: the cleaned text and what was removed.
    public struct Result: Equatable, Sendable {
        public let text: String
        public let matches: [Match]
        public var didRedact: Bool { !matches.isEmpty }

        public init(text: String, matches: [Match]) {
            self.text = text
            self.matches = matches
        }
    }

    /// Options for what counts as a secret. Emails are off by default — they are
    /// legitimate on many screens and redacting them by default causes noticeable
    /// false positives — but can be turned on where a screen is known sensitive.
    public struct Options: Sendable, Equatable {
        public var redactEmails: Bool
        public init(redactEmails: Bool = false) {
            self.redactEmails = redactEmails
        }
        public static let `default` = Options()
    }

    /// Redacts known secret patterns and high-entropy tokens from `text`,
    /// replacing each with `placeholder`. Returns the input unchanged (no
    /// matches) when nothing looks like a secret. Pure and deterministic.
    public static func redact(_ text: String, options: Options = .default) -> Result {
        guard !text.isEmpty else { return Result(text: text, matches: []) }

        var matches: [Match] = []
        var result = text

        // Known patterns first. Order matters only for reporting; replacements
        // never overlap because each consumes its whole match.
        var patterns = knownPatterns
        if options.redactEmails { patterns.append(emailPattern) }
        for pattern in patterns {
            result = apply(pattern, to: result, into: &matches)
        }

        // High-entropy fallback: standalone tokens that look random (mixed case
        // + digits, long enough) — catches generic API keys / AWS secret keys the
        // named patterns miss, while sparing prose, paths, and hex hashes.
        result = redactHighEntropyTokens(in: result, into: &matches)

        return Result(text: result, matches: matches)
    }

    // MARK: - Known patterns

    private struct Pattern {
        let kind: String
        let regex: NSRegularExpression
        init(_ kind: String, _ raw: String, options: NSRegularExpression.Options = []) {
            self.kind = kind
            // Patterns are compile-time constants; a bad one is a programmer error.
            self.regex = try! NSRegularExpression(pattern: raw, options: options)
        }
    }

    private static let knownPatterns: [Pattern] = [
        // JWT: three base64url segments, the first two being a `eyJ...` header/payload.
        Pattern("jwt", #"eyJ[A-Za-z0-9_-]{6,}\.eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}"#),
        // OpenAI-style keys: `sk-` optionally scoped, then a long token.
        Pattern("openai-key", #"sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{16,}"#),
        // GitHub personal-access / OAuth / server tokens.
        Pattern("github-token", #"gh[pousr]_[A-Za-z0-9]{20,}"#),
        Pattern("github-pat", #"github_pat_[A-Za-z0-9_]{20,}"#),
        // AWS access key IDs (long-term AKIA, temporary ASIA).
        Pattern("aws-access-key", #"(?:AKIA|ASIA)[0-9A-Z]{16}"#),
    ]

    private static let emailPattern = Pattern(
        "email", #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)

    private static func apply(_ pattern: Pattern, to text: String,
                              into matches: inout [Match]) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let found = pattern.regex.matches(in: text, range: full)
        guard !found.isEmpty else { return text }
        // Replace from the end so earlier ranges stay valid.
        var out = ns.mutableCopy() as! NSMutableString
        for m in found.reversed() {
            matches.append(Match(kind: pattern.kind, value: ns.substring(with: m.range)))
            out.replaceCharacters(in: m.range, with: placeholder)
        }
        return out as String
    }

    // MARK: - High-entropy tokens

    /// A token is treated as a secret when it is long and mixes three character
    /// classes (lowercase, uppercase, digit). This spares English words (one
    /// class), file paths (delimited, low variety), and hex git SHAs (two
    /// classes) while catching random-looking API keys.
    private static let minEntropyTokenLength = 20

    private static func redactHighEntropyTokens(in text: String,
                                                into matches: inout [Match]) -> String {
        // Split on anything that is not a plausible token character. `/` and `.`
        // are separators too: they split file paths and domains into single-class
        // fragments, so a mixed-case path like `Support/Lasso/store.sqlite3` is
        // not mistaken for one high-entropy blob. (Named patterns already cover
        // the `.`-bearing secrets — JWTs — so the entropy pass needn't keep dots.)
        // Known trade-off: this also fragments `/`-bearing base64 secrets (e.g. an
        // AWS *secret* key), so the prefixless-base64 case can slip the entropy
        // pass. Accepted deliberately — Lasso captures code/terminals constantly,
        // where path false positives would be frequent and degrade the Agent's
        // context, and redaction is best-effort defense-in-depth, not a guarantee.
        let separators = CharacterSet(charactersIn:
            " \t\n\r\"'`=:,;()[]{}<>|\\/.")
        // Walk tokens and rebuild, replacing secret-looking ones.
        var out = ""
        out.reserveCapacity(text.count)
        var current = ""
        func flush() {
            if !current.isEmpty {
                if looksHighEntropy(current) {
                    matches.append(Match(kind: "high-entropy", value: current))
                    out += placeholder
                } else {
                    out += current
                }
                current = ""
            }
        }
        for scalar in text.unicodeScalars {
            if separators.contains(scalar) {
                flush()
                out.unicodeScalars.append(scalar)
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        flush()
        return out
    }

    private static func looksHighEntropy(_ token: String) -> Bool {
        guard token.count >= minEntropyTokenLength, token != placeholder else { return false }
        var hasLower = false, hasUpper = false, hasDigit = false
        for ch in token.unicodeScalars {
            if ("a"..."z").contains(ch) { hasLower = true }
            else if ("A"..."Z").contains(ch) { hasUpper = true }
            else if ("0"..."9").contains(ch) { hasDigit = true }
            else if ch == "-" || ch == "_" || ch == "+" { continue } // allowed, not required
            else { return false } // a non-token character means this isn't an opaque secret
        }
        // Require all three of lower/upper/digit: random-looking, not a word or hash.
        return hasLower && hasUpper && hasDigit
    }
}

/// Applies `SecretRedactor` across every free-text field a Capture carries — the
/// OCR / AX text (`context.text`), the DOM text (`context.dom`), the window title
/// (best-effort OS text that can leak a secret from a tab, SPE-559), each pin's
/// resolution (`Marker.text` / `Marker.dom`), and the user-typed notes (which can
/// contain a pasted credential). Every DOM string is page-controlled, including
/// structural anchors, so locator fields are redacted and strictly validated.
/// Pure; the caller writes the result.
public enum CaptureRedactor {
    public static func redact(context: CaptureContext, markers: [Marker], note: String?,
                              options: SecretRedactor.Options = .default)
        -> (context: CaptureContext, markers: [Marker], note: String?) {
        var ctx = context
        ctx.text = redactOptional(ctx.text, options)
        ctx.dom = redactDOM(ctx.dom, options)
        ctx.windowTitle = redactOptional(ctx.windowTitle, options)
        let cleanMarkers = markers.map { marker -> Marker in
            var m = marker
            m.note = redactOptional(m.note, options)
            m.text = redactOptional(m.text, options)
            m.dom = redactDOM(m.dom, options)
            return m
        }
        return (ctx, cleanMarkers, redactOptional(note, options))
    }

    private static func redactOptional(_ text: String?, _ options: SecretRedactor.Options) -> String? {
        guard let text else { return nil }
        return SecretRedactor.redact(text, options: options).text
    }

    private static func redactDOM(_ dom: DOMFingerprint?, _ options: SecretRedactor.Options) -> DOMFingerprint? {
        guard var dom else { return nil }
        dom.selector = redactSelector(dom.selector, options)
        dom.role = dom.role.map {
            redactLocator($0, options, maxLength: 64, allowed: roleCharacters)
        }
        dom.text = redactOptional(dom.text, options)
        dom.nearbyText = redactOptional(dom.nearbyText, options)
        dom.componentName = dom.componentName.map {
            redactLocator($0, options, maxLength: 128, allowed: componentCharacters)
        }
        return dom
    }

    private static let roleCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )
    private static let componentCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.$-"
    )

    private static func redactLocator(_ value: String, _ options: SecretRedactor.Options,
                                      maxLength: Int, allowed: CharacterSet) -> String {
        let redacted = SecretRedactor.redact(value, options: options).text
        guard redacted == value,
              !value.isEmpty,
              value.count <= maxLength,
              value.unicodeScalars.allSatisfy(allowed.contains)
        else { return SecretRedactor.placeholder }
        return value
    }

    private static let selectorPattern = try! NSRegularExpression(
        pattern: #"^(?:#[A-Za-z_][A-Za-z0-9_-]{0,63}(?: > (?:[a-z][a-z0-9-]{0,63}|\*)(?::nth-of-type\([1-9][0-9]*\))?)*|(?:[a-z][a-z0-9-]{0,63}|\*)(?::nth-of-type\([1-9][0-9]*\))?(?: > (?:[a-z][a-z0-9-]{0,63}|\*)(?::nth-of-type\([1-9][0-9]*\))?)*)$"#
    )

    private static func redactSelector(_ value: String,
                                       _ options: SecretRedactor.Options) -> String {
        let locator = SecretRedactor.redact(value, options: options).text
        guard locator == value, !value.isEmpty, value.count <= 256
        else { return SecretRedactor.placeholder }
        let range = NSRange(locator.startIndex..<locator.endIndex, in: locator)
        guard selectorPattern.firstMatch(in: locator, range: range)?.range == range
        else { return SecretRedactor.placeholder }
        return locator
    }
}
