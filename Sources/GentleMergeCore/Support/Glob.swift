import Foundation

/// Minimal glob: `*` (no slash), `?`, `**/` (zero or more dirs), `**` (anything).
/// A pattern without wildcards also matches everything under it as a directory.
public enum Glob {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        let s = normalize(path)
        // An absolute pattern has no business matching a repo-relative path — and
        // matched nothing at all, so a claim written that way (which is what an
        // agent gets from the path extractor, since it returns absolute paths)
        // silently protected nothing and could not conflict-detect either
        // (audit Tier 5 #34). Nothing here knows the repository root, so each
        // trailing window of the pattern's components is tried in turn: for
        // `/Users/dev/app/lib/store/**` the window `lib/store/**` is the claim the
        // author meant. Each window is still anchored, so this cannot match a
        // path that merely *contains* the window.
        if pattern.hasPrefix("/") {
            let parts = pattern.split(separator: "/").map(String.init)
            for start in 0..<parts.count {
                // A window has to start on a real directory or file name. The last
                // window of `/Users/dev/app/lib/data/**` is `**` on its own, which
                // matches every path in the repository: a claim on `lib/data` blocked
                // commits to README.md. Anchoring on a literal component keeps the
                // window meaning "this directory or something named like it".
                let head = parts[start]
                if head.contains("*") || head.contains("?") { continue }
                if matchesOnce(parts[start...].joined(separator: "/"), s) { return true }
            }
            return false
        }
        return matchesOnce(pattern, s)
    }

    /// An absolute pattern made repository-relative, when it lies under one of
    /// `roots` (the checkout, the repository root, the git top level).
    ///
    /// Done where a claim is *recorded*, because that is the only place that knows
    /// where the repository is. `matches` can only guess with windows; a claim
    /// stored as `lib/data/**` needs no guessing. A symlinked prefix (`/tmp` is
    /// `/private/tmp`) is resolved before comparing. A pattern outside every root
    /// comes back unchanged.
    public static func relativize(_ pattern: String, roots: [String]) -> String {
        guard pattern.hasPrefix("/") else { return pattern }
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let firstWild = parts.firstIndex { $0.contains("*") || $0.contains("?") } ?? parts.count
        let literal = "/" + parts[..<firstWild].joined(separator: "/")
        let rest = parts[firstWild...].joined(separator: "/")
        let literalForms = Set([literal, URL(fileURLWithPath: literal).resolvingSymlinksInPath().path])

        for root in roots where root.hasPrefix("/") {
            for form in literalForms {
                for candidate in Set([root, URL(fileURLWithPath: root).resolvingSymlinksInPath().path]) {
                    let base = candidate.count > 1 && candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate
                    if form == base { return rest.isEmpty ? "**" : rest }
                    guard form.hasPrefix(base + "/") else { continue }
                    let inside = String(form.dropFirst(base.count + 1))
                    return [inside, rest].filter { !$0.isEmpty }.joined(separator: "/")
                }
            }
        }
        return pattern
    }

    private static func matchesOnce(_ pattern: String, _ path: String) -> Bool {
        let p = normalize(pattern)
        if p == path { return true }
        if !p.contains("*") && !p.contains("?") {
            return path.hasPrefix(p + "/")     // "lib/store" covers "lib/store/x.dart"
        }
        guard let re = regex(for: p) else { return false }
        let range = NSRange(path.startIndex..., in: path)
        return re.firstMatch(in: path, range: range) != nil
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

    /// Tail-normalizing: `.` segments and trailing slashes are noise.
    ///
    /// Absolute patterns are *not* normalized here — nothing here knows the
    /// repository root, so `matches` handles them by trying each trailing window
    /// of their components instead.
    ///
    /// `.` segments are removed *anywhere*, not only at the front. `src/./**`
    /// used to keep its middle dot, so it named a directory no repository has
    /// and matched nothing: the claim was accepted, reported as claimed, and
    /// protected nothing — the worst kind of failure, because it looks like
    /// protection (audit 2026-10-08). `.` means "this directory" wherever it
    /// appears, and a doubled `/` is a `.` you did not have to type.
    ///
    /// Two more spellings of the same file are folded here (audit 2026-11-01).
    /// A name is compared in its precomposed form, because macOS hands out
    /// `é` as one character or as `e` plus an accent depending on who made the
    /// file, and a wildcard claim (`café/*.txt`, matched by a regex that sees
    /// UTF-16 units) silently stopped matching the other spelling. And `a/../b`
    /// is `b`: a claim written with a `..` in the middle named a path nobody
    /// edits and protected nothing.
    static func normalize(_ s: String) -> String {
        var t = s.precomposedStringWithCanonicalMapping
        while t.hasPrefix("./") { t.removeFirst(2) }
        while t.hasSuffix("/") { t.removeLast() }
        guard t.contains("/./") || t.contains("//") || t.contains("/..") else { return t }
        // An absolute path stays absolute. Splitting on `/` drops the leading
        // one, so `/x//y` came back as `x/y` and `/Users/../etc` as `etc` — a
        // path inside the repository named `etc`.
        let absolute = t.hasPrefix("/")
        var kept: [Substring] = []
        for part in t.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            // `..` cancels the directory before it, but only a named one: it
            // cannot cancel a wildcard (`**/..` has no answer), and a leading
            // `..` points outside the repository and stays where it is.
            if part == "..", let last = kept.last, last != "..", !last.contains("*"), !last.contains("?") {
                kept.removeLast()
                continue
            }
            kept.append(part)
        }
        // `..` above the root of an absolute path is the root (`/..` is `/`).
        if absolute { return "/" + kept.drop { $0 == ".." }.joined(separator: "/") }
        return kept.joined(separator: "/")
    }

    /// How tightly a pattern pins a path, as a comparable tuple.
    ///
    /// Ranking only by `literalPrefix` — the run of characters before the first
    /// wildcard — threw away everything after it, so any pattern starting with a
    /// wildcard scored zero and two genuinely different patterns could tie at
    /// the same number and be separated by nothing but their order in the file.
    /// Confirmed: `**/models.dart` lost to `lib/**` on `lib/models.dart`;
    /// `lib/store/**` tied with `lib/*` at 4.
    ///
    /// The dominant term is the **longest literal run anywhere** in the pattern,
    /// because that is what names something specific: `models.dart` names a
    /// file, `lib/` names a directory. Total literal characters break ties
    /// between patterns with equally long runs, and the leading prefix settles
    /// what is left.
    static func specificity(of pattern: String) -> (longestRun: Int, literalCount: Int, prefix: Int) {
        var longestRun = 0
        var run = 0
        var literalCount = 0
        for character in pattern {
            if character == "*" || character == "?" {
                longestRun = max(longestRun, run)
                run = 0
            } else {
                run += 1
                literalCount += 1
            }
        }
        longestRun = max(longestRun, run)
        return (longestRun, literalCount, literalPrefix(pattern).count)
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
