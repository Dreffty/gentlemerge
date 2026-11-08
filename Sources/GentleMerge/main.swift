import GentleMergeCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS)
// A subcommand runs headless and exits. The menu bar app is `gentlemerge app`, or
// this binary started inside GentleMerge.app with nothing typed (Finder, `open`).
if let exitCode = CLI.run(CommandLine.arguments) {
    exit(exitCode)
}
// One app per home. `open` reuses a running copy, but `gentlemerge app` with
// nothing installed starts the app inside this very process, and a second one drained,
// swept and notified alongside the first: two banners per event, and nudge
// limits kept in memory twice. The pid file alone is not
// proof — after a crash and a reboot its number can belong to anything — so the
// process behind it must also be a gentlemerge.
if let running = CLI.runningAppPID(), running != getpid() {
    FileHandle.standardError.write(Data("GentleMerge is already running (pid \(running)); it is in the menu bar.\n".utf8))
    exit(0)
}
GentleMergeApp.main()
#else
// ADAPTED: CLI.run is the existing entry point; no arguments print help on Linux.
let arguments = CommandLine.arguments.count > 1
    ? CommandLine.arguments : [CommandLine.arguments[0], "--help"]
exit(CLI.run(arguments) ?? 0)
#endif
