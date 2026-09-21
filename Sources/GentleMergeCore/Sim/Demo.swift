import Foundation

public enum Demo {
    /// Alphabetic UUID encoding keeps generated paths readable after scrubbing.
    public static func temporaryRoot(id: UUID = UUID()) -> URL {
        let alphabet = Array("abcdefghijklmnop")
        let suffix = id.uuidString.lowercased().compactMap { $0.hexDigitValue }.map { String(alphabet[$0]) }.joined()
        return FileManager.default.temporaryDirectory.appendingPathComponent("gentlemerge-demo-" + suffix)
    }

    /// ADAPTED: explicit phases replace timing-dependent threads. All three
    /// worktrees share the real bus; no UI, real agents, or user config edits.
    @MainActor
    @discardableResult
    public static func run(keep: Bool, paths: Paths, binary: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
                           log: @Sendable (String) -> Void) throws -> URL {
        let root = temporaryRoot()
        return try run(in: root, keep: keep, paths: paths, binary: binary, log: log)
    }

    @MainActor
    @discardableResult
    public static func run(in root: URL, keep: Bool, paths: Paths, binary: URL,
                           log: @Sendable (String) -> Void) throws -> URL {
        try SimEnvironment.validate()
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { if !keep { try? FileManager.default.removeItem(at: root) } }
        try paths.createDirectories()
        func git(_ arguments: [String], in directory: URL? = nil) throws {
            let output = Shell.run("/usr/bin/env", ["git", "-c", "commit.gpgsign=false"] + arguments,
                in: directory ?? repo, environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0"])
            guard output.succeeded else { throw SimError.expectationFailed("demo git: " + output.text) }
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "demo"])
        try git(["config", "user.email", "demo@gentlemerge.local"])
        try git(["config", "extensions.worktreeConfig", "true"])
        for directory in ["lib/store", "lib/data", "assets"] {
            try AtomicFile.write(Data("// demo\n".utf8), to: repo.appendingPathComponent(directory + "/README.md"))
        }
        try AtomicFile.write(Data(".gentlemerge/env.sh\n".utf8), to: repo.appendingPathComponent(".gitignore"))
        // ADAPTED: ProjectRegistry's handoff API is static in this repository.
        var handoff = ProjectRegistry.handoff(for: repo.path, refreshingCommits: false)
        handoff.extraSections.append((heading: Ownership.heading, body: "- lib/store/** → claude\n- lib/data/** → hermes\n- assets/** → codex"))
        guard ProjectRegistry.save(handoff) else { throw SimError.expectationFailed("cannot save demo handoff") }
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "demo initial state"])
        _ = try GitHookInstaller(paths: paths).install(repo: repo)
        var worktrees: [String: URL] = [:]
        let capabilities = ["claude": ["reasoning"], "codex": ["image_generation"], "hermes": ["cheap_long_context"]]
        let project = ProjectRegistry.canonicalPath(for: repo.path)
        for label in ["claude", "codex", "hermes"] {
            let worktree = root.appendingPathComponent("wt-" + label)
            try git(["worktree", "add", "-q", worktree.path, "-b", "agent/" + label])
            _ = try WorktreeLabel.write(label: label, in: worktree)
            worktrees[label] = worktree
            Presence.record(label: label, project: project, branch: nil, paths: paths, capabilities: capabilities[label] ?? [])
        }
        log(Redactor.scrub("repo: " + repo.path).text)
        log("ownership: lib/store/** → claude · lib/data/** → hermes · assets/** → codex")
        func run(_ label: String, _ steps: [SimStep]) throws {
            guard let worktree = worktrees[label] else { throw SimError.expectationFailed("missing demo worktree") }
            try SimAgent(paths: paths, worktree: worktree,
                script: SimScript(label: label, capabilities: capabilities[label] ?? [], steps: steps), binary: binary).run(log: log)
        }
        try run("hermes", [.init(action: "claim", paths: ["lib/data/**"], text: "models"),
            .init(action: "edit", paths: ["lib/data/models.dart"]), .init(action: "commit", text: "data: Product model", expectBlocked: false)])
        try run("claude", [.init(action: "claim", paths: ["lib/store/**"], text: "product page"),
            .init(action: "edit", paths: ["lib/store/product_page.dart"]), .init(action: "commit", text: "feat(store): product page", expectBlocked: false),
            .init(action: "delegate", text: "Hero image for category Ropa", to: "capability:image_generation", mayTouch: ["assets/**"])])
        try run("codex", [.init(action: "brief"), .init(action: "request_accept"),
            .init(action: "edit", paths: ["assets/hero_ropa.png.txt"], text: "(simulated image artifact)\n"),
            .init(action: "commit", text: "assets: hero ropa", expectBlocked: false), .init(action: "request_done", text: "assets/hero_ropa.png.txt")])
        try run("claude", [.init(action: "brief"), .init(action: "edit", paths: ["lib/data/models.dart"]),
            .init(action: "commit", text: "add sku to Product", expectBlocked: true),
            .init(action: "say", text: "need a nullable `sku` on Product, can you add it?", to: "hermes")])
        try run("hermes", [.init(action: "brief")])
        log("")
        log(Stats.summaryLine(paths: paths))
        return root
    }
}
