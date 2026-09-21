import Foundation

/// Strips secrets out of anything before it is shared with another agent.
///
/// This app turns one session's private context into something several models
/// read. That is the whole point, and also the whole risk: a prompt is written
/// for one agent, not for three. Nothing reaches the bus unscrubbed — not even
/// the copy we keep on disk.
///
/// It errs toward keeping text useful: a line number, a port and a version are
/// not secrets, and a filter that eats them is a filter people turn off.
public enum Redactor {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case privateKey
        case jwt
        case apiKey
        case credentialsInURL
        case assignedSecret
        case email
        case card
        case iban
        case longNumber

        public var placeholder: String {
            switch self {
            case .privateKey: return "[redacted private key]"
            case .jwt: return "[redacted token]"
            case .apiKey: return "[redacted key]"
            case .credentialsInURL: return "[redacted credentials]"
            case .assignedSecret: return "[redacted]"
            case .email: return "[redacted email]"
            case .card: return "[redacted card]"
            case .iban: return "[redacted account]"
            case .longNumber: return "[redacted number]"
            }
        }

        public var label: String {
            switch self {
            case .privateKey: return "a private key"
            case .jwt: return "a token"
            case .apiKey: return "an API key"
            case .credentialsInURL: return "credentials in a URL"
            case .assignedSecret: return "a password or key"
            case .email: return "an email address"
            case .card: return "a card number"
            case .iban: return "a bank account"
            case .longNumber: return "a long number"
            }
        }
    }

    public struct Result: Sendable, Equatable {
        /// Safe to hand to another agent.
        public var text: String
        /// What was found, in the order it was found.
        public var kinds: [Kind]
        /// So little survived that sharing the remains would be misleading.
        public var isSuppressed: Bool

        public var didRedact: Bool { !kinds.isEmpty }

        /// "an API key and an email address"
        public var summary: String {
            let labels = Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue }.map(\.label)
            guard let last = labels.last else { return "" }
            if labels.count == 1 { return last }
            return labels.dropLast().joined(separator: ", ") + " and " + last
        }
    }

    // MARK: - Rules

    /// Order matters: the specific patterns run before the broad ones, so a key
    /// is reported as a key rather than as a long number.
    private static let rules: [(Kind, String)] = [
        (.privateKey, #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
        (.jwt, #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{6,}"#),
        (.apiKey, #"\b(?:sk-ant-[A-Za-z0-9_-]{12,}|sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20,}|nvapi-[A-Za-z0-9_-]{12,}|hf_[A-Za-z0-9]{20,}|(?:sk|pk)_(?:live|test)_[A-Za-z0-9]{10,}|glpat-[A-Za-z0-9_-]{16,})"#),
        (.credentialsInURL, #"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s/@:]+:[^\s/@]+@"#),
        (.email, #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#),
        // IBAN before card: "ES91 2100 0418 4502 0005 1332" is an account, not
        // four card groups, and shredding it as a card leaves the country
        // prefix plus the check digits behind.
        (.iban, #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}\b"#),
        (.card, #"\b\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{2,4}\b"#),
        // Short numbers are line numbers, ports and versions. Long runs are
        // phone numbers, document ids and account numbers.
        (.longNumber, #"\b\d{7,}\b"#),
    ]

    /// `password: hunter2`, `API_KEY=abc…`, `token = "…"`, `{"password":"…"}`
    /// — the name gives it away, so the value goes regardless of what it
    /// looks like. The name may wear a snake_case prefix (`DB_PASSWORD`,
    /// `APP_SECRET_KEY`): the trailing boundary still holds, so
    /// `bypass = true` does not match. JSON quotes the name
    /// (`"password":`), so one optional closing quote is allowed between
    /// the name and the separator.
    private static let assignment =
        #"(?i)\b([A-Za-z_]*(?:pass(?:word|wd)?|passphrase|contraseña|clave|secret|token|auth|authorization|bearer|api[_-]?key|apikey|access[_-]?key|private[_-]?key))\b["']?\s*[:=]\s*(?:"[^"\n]{1,200}"|'[^'\n]{1,200}'|[^\s,;)\]}]{3,200})"#

    /// Every pattern, so a test can prove they all compile. A rule that does
    /// not compile is skipped at runtime, and skipping is invisible.
    static var allPatterns: [(Kind, String)] { [(.assignedSecret, assignment)] + rules }

    // MARK: - Compiled once

    /// Compiling ten patterns per scrub dominated the cost (measured ~0.2ms a
    /// call, paid on every message write and every briefing line). Compiled
    /// once, shared by every thread: NSRegularExpression matching does not
    /// mutate the instance. A pattern that fails here fails the same way the
    /// per-call version did — logged, and its rule filters nothing.
    private static let compiledAssignment: NSRegularExpression? = {
        guard let regex = try? NSRegularExpression(pattern: assignment) else {
            Log.error("redaction rule assignedSecret does not compile — it is NOT filtering")
            return nil
        }
        return regex
    }()

    private static let compiledRules: [(Kind, NSRegularExpression)] = {
        var compiled: [(Kind, NSRegularExpression)] = []
        for (kind, pattern) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                Log.error("redaction rule \(kind.rawValue) does not compile — it is NOT filtering")
                continue
            }
            compiled.append((kind, regex))
        }
        return compiled
    }()

    /// Terminal control sequences are formatting, not content — and a
    /// cursor-moving escape smuggled into a briefing can rewrite what the
    /// reader thinks the previous line said. Stripped silently before the
    /// secret rules run; no kind recorded, nothing replaced.
    private static let ansiPattern = "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}\\[[0-9;?]*[A-Za-z]|\u{1B}[()][0-9A-Z]"
    private static let compiledANSI: NSRegularExpression? = try? NSRegularExpression(pattern: ansiPattern)

    public static func stripANSI(_ text: String) -> String {
        guard let compiledANSI else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return compiledANSI.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Scrubbing

    public static func scrub(_ text: String) -> Result {
        guard !text.isEmpty else { return Result(text: text, kinds: [], isSuppressed: false) }

        var working = stripANSI(text)
        var kinds: [Kind] = []
        var redactedCharacters = 0

        func apply(_ kind: Kind, _ regex: NSRegularExpression?, keepingPrefix: Bool = false) {
            guard let regex else {
                // Failing open here would leak exactly what this exists to stop.
                // (The missing compile is already logged where the cache built.)
                return
            }
            let range = NSRange(working.startIndex..., in: working)
            let matches = regex.matches(in: working, range: range)
            guard !matches.isEmpty else { return }

            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: working) else { continue }
                let original = String(working[matchRange])
                var replacement = kind.placeholder

                // For `token: value`, keep the name so the sentence still reads.
                if keepingPrefix, match.numberOfRanges > 1,
                   let nameRange = Range(match.range(at: 1), in: working) {
                    replacement = "\(working[nameRange]): \(kind.placeholder)"
                }

                redactedCharacters += max(0, original.count - replacement.count)
                working.replaceSubrange(matchRange, with: replacement)
                kinds.append(kind)
            }
        }

        apply(.assignedSecret, compiledAssignment, keepingPrefix: true)
        for (kind, regex) in compiledRules { apply(kind, regex) }

        // If most of it was secret, the leftovers are not worth sharing: they
        // are the shape of the secret with the secret taken out.
        let survived = max(0, text.count - redactedCharacters)
        let isSuppressed = !kinds.isEmpty && (survived < 12 || survived * 2 < text.count)

        return Result(text: working, kinds: kinds.reversed(), isSuppressed: isSuppressed)
    }

    /// What another agent should see. A suppressed message comes back as a
    /// visible stub, never as silence: in this contract "nothing shown" reads
    /// as "nothing new", and a reader must be able to tell the two apart.
    /// Only nil/empty input returns nil.
    public static func shared(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let result = scrub(text)
        if result.isSuppressed { return "(withheld: it was almost entirely \(result.summary))" }
        return result.text
    }
}
