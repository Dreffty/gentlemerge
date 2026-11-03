import Foundation

/// Sets one top-level key of a JSON object and leaves every other byte of the
/// file where it was.
///
/// `install` and `uninstall` only ever change `hooks` in `~/.claude/settings.json`,
/// but they parsed the whole file and wrote it back sorted and re-indented in
/// Foundation's own style (`"key" : value`): every other setting moved, and a
/// settings file kept in a dotfiles repository showed a diff on every line
/// (audit 2026-11-03). Here only the value of the one key is rewritten, in the
/// style Claude Code itself writes (two spaces, `"key": value`).
///
/// Anything this cannot read with certainty — not an object, a duplicated
/// key, text after the closing brace — returns nil, and the caller falls back
/// to writing the whole file.
enum JSONSplice {
    static func setting(_ key: String, to value: Any?, in text: String) -> String? {
        let bytes = Array(text.utf8)
        guard let object = TopLevel(bytes) else { return nil }
        guard object.members.filter({ $0.name == key }).count <= 1 else { return nil }
        let unit = object.indentUnit

        func render(_ value: Any) -> String? { Self.render(value, unit: unit, level: 1) }
        func slice(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }

        if let index = object.members.firstIndex(where: { $0.name == key }) {
            let member = object.members[index]
            if let value {
                guard let rendered = render(value) else { return nil }
                return slice(0..<member.valueStart) + rendered + slice(member.valueEnd..<bytes.count)
            }
            // Removing: take the comma that joined it to a neighbour with it.
            if index + 1 < object.members.count {
                return slice(0..<member.keyStart) + slice(object.members[index + 1].keyStart..<bytes.count)
            }
            if index > 0 {
                return slice(0..<object.members[index - 1].valueEnd) + slice(member.valueEnd..<bytes.count)
            }
            return slice(0..<(object.open + 1)) + slice(object.close..<bytes.count)
        }

        guard let value else { return text }
        guard let rendered = render(value), let name = Self.leaf(key) else { return nil }
        let entry = unit + name + ": " + rendered
        if let last = object.members.last {
            return slice(0..<last.valueEnd) + ",\n" + entry + slice(last.valueEnd..<bytes.count)
        }
        return slice(0..<(object.open + 1)) + "\n" + entry + "\n" + slice(object.close..<bytes.count)
    }

    /// Two-space JSON as `JSON.stringify(value, null, 2)` writes it. Keys are
    /// sorted: a dictionary has no order of its own to keep.
    static func render(_ value: Any, unit: String, level: Int) -> String? {
        let inner = String(repeating: unit, count: level + 1)
        let outer = String(repeating: unit, count: level)
        if let dictionary = value as? [String: Any] {
            if dictionary.isEmpty { return "{}" }
            var lines: [String] = []
            for key in dictionary.keys.sorted() {
                guard let name = leaf(key), let item = render(dictionary[key]!, unit: unit, level: level + 1) else { return nil }
                lines.append(inner + name + ": " + item)
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + outer + "}"
        }
        if let array = value as? [Any] {
            if array.isEmpty { return "[]" }
            var lines: [String] = []
            for element in array {
                guard let item = render(element, unit: unit, level: level + 1) else { return nil }
                lines.append(inner + item)
            }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + outer + "]"
        }
        return leaf(value)
    }

    /// A string, number, bool or null, spelled by Foundation.
    private static func leaf(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Where each member of the top-level object starts and ends.
    private struct TopLevel {
        struct Member {
            var name: String
            var keyStart: Int
            var valueStart: Int
            var valueEnd: Int
        }

        var open = 0
        var close = 0
        var members: [Member] = []
        var indentUnit = "  "

        init?(_ bytes: [UInt8]) {
            var i = 0
            func skipSpace() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
            func skipString() -> Bool {
                guard i < bytes.count, bytes[i] == 0x22 else { return false }
                i += 1
                while i < bytes.count {
                    if bytes[i] == 0x5C { i += 2; continue }
                    if bytes[i] == 0x22 { i += 1; return true }
                    i += 1
                }
                return false
            }
            func skipValue() -> Bool {
                guard i < bytes.count else { return false }
                if bytes[i] == 0x22 { return skipString() }
                if bytes[i] == 0x7B || bytes[i] == 0x5B {
                    var depth = 0
                    while i < bytes.count {
                        switch bytes[i] {
                        case 0x22: guard skipString() else { return false }; continue
                        case 0x7B, 0x5B: depth += 1
                        case 0x7D, 0x5D:
                            depth -= 1
                            if depth == 0 { i += 1; return true }
                        default: break
                        }
                        i += 1
                    }
                    return false
                }
                let start = i
                while i < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
                return i > start
            }

            skipSpace()
            guard i < bytes.count, bytes[i] == 0x7B else { return nil }
            open = i
            i += 1
            skipSpace()
            if i < bytes.count, bytes[i] == 0x7D {
                close = i
            } else {
                while true {
                    skipSpace()
                    let keyStart = i
                    guard skipString(),
                          let name = try? JSONSerialization.jsonObject(
                              with: Data(bytes[keyStart..<i]), options: .fragmentsAllowed) as? String
                    else { return nil }
                    skipSpace()
                    guard i < bytes.count, bytes[i] == 0x3A else { return nil }
                    i += 1
                    skipSpace()
                    let valueStart = i
                    guard skipValue() else { return nil }
                    members.append(Member(name: name, keyStart: keyStart, valueStart: valueStart, valueEnd: i))
                    skipSpace()
                    guard i < bytes.count else { return nil }
                    if bytes[i] == 0x2C { i += 1; continue }
                    guard bytes[i] == 0x7D else { return nil }
                    close = i
                    break
                }
            }
            i = close + 1
            skipSpace()
            guard i == bytes.count else { return nil }

            // The file's own indent, read off the first member's line.
            if let first = members.first {
                var start = first.keyStart
                while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
                let indent = String(decoding: bytes[start..<first.keyStart], as: UTF8.self)
                if start > 0, bytes[start - 1] == 0x0A, !indent.isEmpty { indentUnit = indent }
            }
        }
    }
}
