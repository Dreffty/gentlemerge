import Foundation

extension InboxModel {
    /// Review the work of a session: what changed since it started, what its own
    /// checks say about that, and what none of them can answer.
    public func startReview(
        projectPath: String,
        sessionID: String? = nil,
        includeOptional: Bool = false
    ) {
        cancelReview()

        let project = URL(fileURLWithPath: projectPath)
        let baseline = sessions.baseline(for: sessionID)
        let outside = outsidePaths(for: sessionID, project: projectPath)
        let planned = ProjectChecks.checks(for: project)
            .filter { includeOptional || !$0.optional }
        let skipped = ProjectChecks.checks(for: project)
            .filter { !includeOptional && $0.optional }

        var review = Review(
            id: UUID().uuidString,
            sessionID: sessionID,
            projectPath: projectPath,
            startedAt: Date(),
            finishedAt: nil,
            work: WorkSummary(
                projectPath: projectPath,
                isRepository: GitSnapshot.isRepository(projectPath),
                baseline: baseline,
                baselineIsHead: false,
                changes: [],
                outsidePaths: outside
            ),
            checks: planned.map {
                CheckResult(
                    name: $0.name,
                    command: $0.command,
                    kind: $0.kind,
                    status: .running,
                    exitCode: nil,
                    duration: 0,
                    output: ""
                )
            } + skipped.map {
                CheckResult(
                    name: $0.name,
                    command: $0.command,
                    kind: $0.kind,
                    status: .skipped,
                    exitCode: nil,
                    duration: 0,
                    output: "",
                    skipReason: "slow — run it with “Include slow checks”"
                )
            },
            openQuestions: []
        )
        activeReview = review

        reviewTask = Task { [weak self] in
            // Reading the diff hits git, so keep it off the main actor too.
            let work = await Task.detached(priority: .userInitiated) {
                WorkInspector.summarize(
                    projectPath: projectPath,
                    baseline: baseline,
                    outsidePaths: outside
                )
            }.value

            guard !Task.isCancelled else { return }
            review.work = work
            await MainActor.run { self?.activeReview = review }

            for check in planned {
                guard !Task.isCancelled else { return }
                let output = await Shell.shAsync(check.command, in: project, timeout: check.timeout)
                guard !Task.isCancelled else { return }

                let result = CheckResult(
                    name: check.name,
                    command: check.command,
                    kind: check.kind,
                    status: output.timedOut ? .timedOut : (output.succeeded ? .passed : .failed),
                    exitCode: output.status,
                    duration: output.duration,
                    // Failures are read from the bottom; that is where the
                    // compiler and the test runner put the reason.
                    output: output.succeeded ? "" : String(output.text.suffix(2_000))
                )
                if let index = review.checks.firstIndex(where: { $0.name == check.name }) {
                    review.checks[index] = result
                }
                await MainActor.run { self?.activeReview = review }
            }

            guard !Task.isCancelled else { return }
            review.finishedAt = Date()
            review.openQuestions = WorkInspector.openQuestions(for: review.work, checks: review.checks)

            await MainActor.run { self?.finish(review) }
        }
    }

    public func startReview(for item: InboxItem, includeOptional: Bool = false) {
        guard let projectPath = item.projectPath else {
            lastMessage = "That session did not report a project directory."
            return
        }
        startReview(projectPath: projectPath, sessionID: item.sessionID, includeOptional: includeOptional)
    }

    public func cancelReview() {
        reviewTask?.cancel()
        reviewTask = nil
        if activeReview?.finishedAt == nil { activeReview = nil }
    }

    func finish(_ review: Review) {
        activeReview = review
        reviews.removeAll { $0.id == review.id }
        reviews.insert(review, at: 0)
        reviews = Array(reviews.prefix(20))
        save(review)
        reviewTask = nil

        switch review.verdict {
        case .problems:
            lastMessage = "\(review.projectName): \(review.headline)."
        case .unverified:
            lastMessage = "\(review.projectName): nothing could be checked automatically."
        case .passed, .running:
            lastMessage = nil
        }
    }

    /// Everything the hooks saw this session reach outside its own project.
    func outsidePaths(for sessionID: String?, project: String) -> [String] {
        let relevant = items.filter { item in
            item.reachesOutsideProject
                && (sessionID == nil || item.sessionID == sessionID)
                && item.projectPath == project
        }
        let paths = relevant.flatMap(\.paths).filter { path in
            !PathExtractor.normalized(path).hasPrefix(PathExtractor.normalized(project))
        }
        return Array(Set(paths)).sorted()
    }

    // MARK: - Persistence

    func save(_ review: Review) {
        do {
            let url = paths.reviews.appendingPathComponent("\(review.id).json")
            try AtomicFile.write(try JSONCoding.encoder().encode(review), to: url)
        } catch {
            Log.error("could not save review: \(error.localizedDescription)")
        }
        pruneReviews()
    }

    func loadReviews() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.reviews.path) else { return }
        let decoder = JSONCoding.decoder()
        reviews = names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> Review? in
                guard let data = try? Data(contentsOf: paths.reviews.appendingPathComponent(name)) else { return nil }
                return try? decoder.decode(Review.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
        reviews = Array(reviews.prefix(20))
    }

    private func pruneReviews() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.reviews.path) else { return }
        let keep = Set(reviews.map { "\($0.id).json" })
        for name in names where name.hasSuffix(".json") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: paths.reviews.appendingPathComponent(name))
        }
    }
}
