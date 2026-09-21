import Foundation

/// One thing that can be run to find out whether the work holds up.
public struct Check: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case build
        case test
        case typecheck
        case lint
        case custom
    }

    public var id: String { name }
    public var name: String
    public var command: String
    public var kind: Kind
    public var timeout: TimeInterval
    /// Slow or fragile checks stay off until you ask for them.
    public var optional: Bool

    public init(
        name: String,
        command: String,
        kind: Kind,
        timeout: TimeInterval = 300,
        optional: Bool = false
    ) {
        self.name = name
        self.command = command
        self.kind = kind
        self.timeout = timeout
        self.optional = optional
    }
}

/// Per-project overrides, read from `.gentlemerge.json` in the project root.
public struct ProjectCheckConfig: Codable, Sendable, Equatable {
    public var checks: [Check]
    /// true = ignore what we detected and run only these.
    public var replaceDetected: Bool?

    public init(checks: [Check], replaceDetected: Bool? = nil) {
        self.checks = checks
        self.replaceDetected = replaceDetected
    }
}

/// Works out what this project can actually verify about itself, by looking at
/// the files that are there — the same way you would.
public enum ProjectChecks {
    public static let configFileName = ".gentlemerge.json"

    public static func checks(for project: URL) -> [Check] {
        let custom = configuration(for: project)
        if let custom, custom.replaceDetected == true { return custom.checks }
        return detect(in: project) + (custom?.checks ?? [])
    }

    public static func configuration(for project: URL) -> ProjectCheckConfig? {
        let url = project.appendingPathComponent(configFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder().decode(ProjectCheckConfig.self, from: data)
    }

    /// Run the checks, in order, capturing the tail of whatever fails. The
    /// same loop `gentlemerge review` prints line by line; landing needs the
    /// results as values so it can abort before touching main.
    public static func run(_ checks: [Check], in project: URL, skipOptional: Bool = true) -> [CheckResult] {
        checks.filter { !skipOptional || !$0.optional }.map { check in
            let output = Shell.sh(check.command, in: project, timeout: check.timeout)
            let status: CheckResult.Status = output.timedOut
                ? .timedOut
                : (output.succeeded ? .passed : .failed)
            return CheckResult(
                name: check.name,
                command: check.command,
                kind: check.kind,
                status: status,
                exitCode: output.status,
                duration: output.duration,
                output: output.succeeded ? "" : String(output.text.suffix(2_000))
            )
        }
    }

    static func detect(in project: URL) -> [Check] {
        var checks: [Check] = []
        let manager = FileManager.default
        func exists(_ name: String) -> Bool {
            manager.fileExists(atPath: project.appendingPathComponent(name).path)
        }

        if exists("Package.swift") {
            checks.append(Check(name: "swift build", command: "swift build", kind: .build))
            checks.append(Check(name: "swift test", command: "swift test", kind: .test, timeout: 600))
        }

        if exists("package.json") {
            checks.append(contentsOf: nodeChecks(in: project))
        }

        if exists("Cargo.toml") {
            checks.append(Check(name: "cargo build", command: "cargo build", kind: .build, timeout: 600))
            checks.append(Check(name: "cargo test", command: "cargo test", kind: .test, timeout: 900))
        }

        if exists("go.mod") {
            checks.append(Check(name: "go build", command: "go build ./...", kind: .build))
            checks.append(Check(name: "go test", command: "go test ./...", kind: .test, timeout: 600))
        }

        if exists("pyproject.toml") || exists("setup.py") || exists("pytest.ini") || exists("tox.ini") {
            checks.append(
                Check(name: "pytest", command: "pytest -q", kind: .test, timeout: 600, optional: true)
            )
        }

        if let scheme = xcodeScheme(in: project) {
            // Xcode builds are slow enough that they should be a choice.
            checks.append(
                Check(
                    name: "xcodebuild \(scheme)",
                    command: "xcodebuild -scheme '\(scheme)' -destination 'platform=macOS' build",
                    kind: .build,
                    timeout: 900,
                    optional: true
                )
            )
        }

        // A Makefile is the fallback for projects whose toolchain told us
        // nothing — not a second way to run the tests we already found.
        if !checks.contains(where: { $0.kind == .test }), let makeTarget = makefileTarget(in: project) {
            checks.append(Check(name: "make \(makeTarget)", command: "make \(makeTarget)", kind: .test, timeout: 600))
        }

        return checks
    }

    // MARK: - Node

    static func nodeChecks(in project: URL) -> [Check] {
        guard
            let data = try? Data(contentsOf: project.appendingPathComponent("package.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let scripts = json["scripts"] as? [String: Any] ?? [:]
        let runner = packageRunner(in: project)
        var checks: [Check] = []

        for (name, kind) in [("build", Check.Kind.build), ("test", .test), ("typecheck", .typecheck), ("lint", .lint)]
        where scripts[name] != nil {
            // Name it exactly as it runs, so the report and your terminal agree.
            let command = name == "test" ? "\(runner) test" : "\(runner) run \(name)"
            checks.append(Check(name: command, command: command, kind: kind, timeout: 600))
        }

        let hasTypecheck = checks.contains { $0.kind == .typecheck }
        if !hasTypecheck, FileManager.default.fileExists(
            atPath: project.appendingPathComponent("tsconfig.json").path
        ) {
            checks.append(
                Check(name: "tsc --noEmit", command: "npx --no-install tsc --noEmit", kind: .typecheck, optional: true)
            )
        }

        return checks
    }

    /// The lockfile is the honest answer to "which package manager is this".
    static func packageRunner(in project: URL) -> String {
        let manager = FileManager.default
        func exists(_ name: String) -> Bool {
            manager.fileExists(atPath: project.appendingPathComponent(name).path)
        }
        if exists("pnpm-lock.yaml") { return "pnpm" }
        if exists("yarn.lock") { return "yarn" }
        if exists("bun.lockb") || exists("bun.lock") { return "bun" }
        return "npm"
    }

    // MARK: - Xcode / make

    static func xcodeScheme(in project: URL) -> String? {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: project.path) else { return nil }
        let containers = entries.filter { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }

        // Shared schemes are plain files on disk, so this stays instant. Asking
        // xcodebuild would cost seconds before we have even started.
        for container in containers {
            let containerName = (container as NSString).deletingPathExtension
            let schemes = project
                .appendingPathComponent(container)
                .appendingPathComponent("xcshareddata/xcschemes")
            guard let files = try? manager.contentsOfDirectory(atPath: schemes.path) else { continue }

            let names = files
                .filter { $0.hasSuffix(".xcscheme") }
                .map { String($0.dropLast(".xcscheme".count)) }
                .sorted()
            // The scheme named after the project is the app itself; anything
            // else is a helper target you did not mean to build.
            if let match = names.first(where: { $0 == containerName }) { return match }
            if let first = names.first { return first }
        }
        return nil
    }

    static func makefileTarget(in project: URL) -> String? {
        let url = project.appendingPathComponent("Makefile")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for target in ["test", "check"] where contents.range(of: "\n\(target):") != nil
            || contents.hasPrefix("\(target):") {
            return target
        }
        return nil
    }
}
