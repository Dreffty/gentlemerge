import GentleMergeCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS)
// A subcommand runs headless and exits; no arguments means the menu bar app.
if let exitCode = CLI.run(CommandLine.arguments) {
    exit(exitCode)
}
GentleMergeApp.main()
#else
// ADAPTED: CLI.run is the existing entry point; no arguments print help on Linux.
let arguments = CommandLine.arguments.count > 1
    ? CommandLine.arguments : [CommandLine.arguments[0], "--help"]
exit(CLI.run(arguments) ?? 0)
#endif
