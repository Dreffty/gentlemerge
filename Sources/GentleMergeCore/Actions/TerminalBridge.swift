import Foundation

/// Finds the terminal a session is running in and, when the terminal has a
/// scripting interface, drives it: focus the exact tab, or type an answer into
/// the session that is waiting for one.
///
/// The tty is the join key. A hook script runs with the agent's controlling
/// terminal, so `ps -o tty=` inside the hook identifies the window we need.
// ADAPTED: retain the public bridge/Outcome API used by InboxModel; only the
// AppleScript implementation is macOS-only. Linux explicitly refuses delivery.
public struct TerminalBridge: Sendable {
    public init() {}

    public enum Outcome: Sendable, Equatable {
        case focused
        case sent
        /// No scripting support (Ghostty, WezTerm, kitty…): we brought the app
        /// forward, but you have to find the tab yourself.
        case appActivatedOnly
        case notFound
        case unsupported(String)
        case failed(String)
    }

    // MARK: - Focus

    @discardableResult
    public func focus(tty: String?, terminalProgram: String?) -> Outcome {
        #if os(macOS)
        guard let tty, !tty.isEmpty else {
            return activateApp(named: terminalProgram) ? .appActivatedOnly : .notFound
        }

        for app in ScriptableTerminal.candidates(for: terminalProgram) {
            switch run(app.focusScript(tty: tty)) {
            case .success(let output) where output.contains("ok"):
                return .focused
            case .success:
                continue
            case .failure(let message):
                if message.contains("not authorized") || message.contains("-1743") {
                    return .failed(
                        "macOS blocked automation of \(app.applicationName). "
                            + "Allow it in System Settings › Privacy & Security › Automation."
                    )
                }
                continue
            }
        }

        return activateApp(named: terminalProgram) ? .appActivatedOnly : .notFound
        #else
        return .unsupported("no delivery channel on this platform")
        #endif
    }

    // MARK: - Typing a reply

    /// Types `text` into the session and presses return. Only single-line
    /// replies: a newline mid-string would submit early in an agent TUI.
    @discardableResult
    public func send(text: String, tty: String?, terminalProgram: String?) -> Outcome {
        #if os(macOS)
        let line = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .failed("Empty reply") }
        guard let tty, !tty.isEmpty else {
            return .unsupported("This session did not report a terminal, so there is nothing to type into.")
        }

        for app in ScriptableTerminal.candidates(for: terminalProgram) {
            switch run(app.sendScript(tty: tty, text: line)) {
            case .success(let output) where output.contains("ok"):
                return .sent
            case .success:
                continue
            case .failure(let message):
                return .failed(message)
            }
        }

        return .unsupported(
            "\(terminalProgram ?? "This terminal") has no scripting support, so replies must be typed there."
        )
        #else
        return .unsupported("no delivery channel on this platform")
        #endif
    }

    #if os(macOS)
    // MARK: - Plumbing

    private func activateApp(named name: String?) -> Bool {
        guard let name = name?.nonEmpty else { return false }
        let script = "tell application \"\(ScriptableTerminal.applicationName(for: name))\" to activate"
        if case .success = run(script) { return true }
        return false
    }

    enum ScriptResult {
        case success(String)
        case failure(String)
    }

    private func run(_ script: String) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(decoding: outputData, as: UTF8.self)
        let stderr = String(decoding: errorData, as: UTF8.self)

        if process.terminationStatus != 0 {
            return .failure(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .success(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    #endif
}

#if os(macOS)
/// The two macOS terminals with a usable AppleScript surface.
enum ScriptableTerminal: Sendable {
    case iTerm(name: String)
    case appleTerminal

    var applicationName: String {
        switch self {
        case .iTerm(let name): return name
        case .appleTerminal: return "Terminal"
        }
    }

    /// `TERM_PROGRAM` values map onto scripting names.
    static func applicationName(for termProgram: String) -> String {
        switch termProgram.lowercased() {
        case "iterm.app", "iterm2", "iterm": return "iTerm2"
        case "apple_terminal", "terminal": return "Terminal"
        default: return termProgram.replacingOccurrences(of: ".app", with: "")
        }
    }

    /// Try the reported terminal first, then the other one — a session can be
    /// re-attached (tmux, ssh) to a terminal that is not the one that spawned it.
    static func candidates(for termProgram: String?) -> [ScriptableTerminal] {
        let all: [ScriptableTerminal] = [.iTerm(name: "iTerm2"), .iTerm(name: "iTerm"), .appleTerminal]
        guard let termProgram = termProgram?.lowercased() else { return all }
        if termProgram.contains("apple_terminal") || termProgram == "terminal" {
            return [.appleTerminal] + all.filter { if case .appleTerminal = $0 { return false } else { return true } }
        }
        if termProgram.contains("iterm") { return all }
        return all
    }

    func focusScript(tty: String) -> String {
        switch self {
        case .iTerm(let name):
            return """
            tell application "\(name)"
              repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                  repeat with theSession in sessions of theTab
                    if tty of theSession is "\(escape(tty))" then
                      select theWindow
                      select theTab
                      select theSession
                      activate
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "notfound"
            """
        case .appleTerminal:
            return """
            tell application "Terminal"
              repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                  if tty of theTab is "\(escape(tty))" then
                    set selected of theTab to true
                    set index of theWindow to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "notfound"
            """
        }
    }

    func sendScript(tty: String, text: String) -> String {
        switch self {
        case .iTerm(let name):
            return """
            tell application "\(name)"
              repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                  repeat with theSession in sessions of theTab
                    if tty of theSession is "\(escape(tty))" then
                      tell theSession to write text "\(escape(text))"
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "notfound"
            """
        case .appleTerminal:
            return """
            tell application "Terminal"
              repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                  if tty of theTab is "\(escape(tty))" then
                    do script "\(escape(text))" in theTab
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "notfound"
            """
        }
    }

    private func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#endif
