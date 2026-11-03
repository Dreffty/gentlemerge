import Foundation

/// The human escape hatch: `GENTLEMERGE_SKIP=1 git commit …`.
///
/// One definition for every place that honours it. The gate treated any
/// non-empty value as "skip" while the edit-time advice treated any value at all
/// as "skip" (an empty one included), so `GENTLEMERGE_SKIP=` silenced one and
/// not the other — and `GENTLEMERGE_SKIP=0`, which anybody reads as "do not
/// skip", skipped both.
public enum EscapeHatch {
    /// Values a person means as "no".
    static let negatives: Set<String> = ["", "0", "false", "no", "off"]

    public static func isActive(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment["GENTLEMERGE_SKIP"] else { return false }
        return !negatives.contains(raw.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
