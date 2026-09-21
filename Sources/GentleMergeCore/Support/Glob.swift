import Foundation

/// Minimal glob: `*` (no slash), `?`, `**/` (zero or more dirs), `**` (anything).
/// A pattern without wildcards also matches everything under it as a directory.
public enum Glob {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        let p = normalize(pattern), s = normalize(path)
        if p == s { return true }
        if !p.contains("*") && !p.contains("?") {
            return s.hasPrefix(p + "/")     // "lib/store" covers "lib/store/x.dart"
        }
        guard let re = regex(for: p) else { return false }
        let range = NSRange(s.startIndex..., in: s)
        return re.firstMatch(in: s, range: range) != nil
    }

    /// Longest wildcard-free directory prefix. Used for cheap overlap checks.
    public static func literalPrefix(_ pattern: String) -> String {
        let p = normalize(pattern)
        guard let idx = p.firstIndex(where: { $0 == "*" || $0 == "?" }) else { return p }
        let head = String(p[..<idx])
        return head.lastIndex(of: "/").map { String(head[..<$0]) } ?? ""
    }

    /// Conservative: two patterns overlap if either matches the other's literal prefix.
    /// May report false positives; never false negatives for common patterns.
    public static func mayOverlap(_ a: String, _ b: String) -> Bool {
        // Guard against the pathological case: an empty prefix means a "**"
        // pattern — assume overlap, since a false negative would let two agents
        // edit the same file under the impression nobody else was there.
        if normalize(a) == normalize(b) { return true }
        let pa = literalPrefix(a), pb = literalPrefix(b)
        if pa.isEmpty || pb.isEmpty { return true }
        if pa.hasPrefix(pb) || pb.hasPrefix(pa) { return true }
        return matches(a, pb) || matches(b, pa)
    }

    /// The result of an overlap check, split out so the pre-commit gate can be
    /// honest about the one direction it can fail in: two globs it calls
    /// disjoint really are disjoint, while "overlap" may be a false positive.
    public enum DisjunctiveOverlap: Sendable, Equatable {
        case overlaps
        case disjoint
    }

    /// Tail-normalizing: `./` prefixes and trailing slashes are noise.
    static func normalize(_ s: String) -> String {
        var t = s
        while t.hasPrefix("./") { t.removeFirst(2) }
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    static func regex(for pattern: String) -> NSRegularExpression? {
        var out = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "*" {
                let n = pattern.index(after: i)
                if n < pattern.endIndex, pattern[n] == "*" {
                    let a = pattern.index(after: n)
                    if a < pattern.endIndex, pattern[a] == "/" {
                        out += "(?:.*/)?"
                        i = pattern.index(after: a)
                        continue
                    }
                    out += ".*"
                    i = a
                    continue
                }
                out += "[^/]*"
            } else if c == "?" {
                out += "[^/]"
            } else {
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = pattern.index(after: i)
        }
        out += "$"
        return try? NSRegularExpression(pattern: out)
    }
}
