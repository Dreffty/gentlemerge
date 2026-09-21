#if os(macOS)
import GentleMergeCore
import AppKit
import SwiftUI

/// The report DiffGuard produces: what changed, what the project's own checks
/// say about it, and what no command here can answer.
@MainActor
struct ReviewView: View {
    let model: InboxModel
    var onBack: () -> Void

    @State private var expanded: Set<String> = []

    private var review: Review? { model.activeReview ?? model.reviews.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let review {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        workSection(review)
                        checksSection(review)
                        questionsSection(review)
                        if !model.reviews.isEmpty { pastSection }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 520)
            } else {
                Text("No review yet. Open one from a finished session.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
        }
        .frame(width: 420)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)

            Text(review.map { "Review · \($0.projectName)" } ?? "Review")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            if let review {
                Text(review.headline)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(verdictColor(review).opacity(0.16), in: Capsule())
                    .foregroundStyle(verdictColor(review))
            }

            Spacer()

            if review?.verdict == .running {
                Button("Stop") { model.cancelReview() }
                    .controlSize(.small)
            } else if let review {
                Menu {
                    Button("Run again") {
                        model.startReview(projectPath: review.projectPath, sessionID: review.sessionID)
                    }
                    Button("Run again including slow checks") {
                        model.startReview(
                            projectPath: review.projectPath,
                            sessionID: review.sessionID,
                            includeOptional: true
                        )
                    }
                    Button("Copy report") { copy(review) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Sections

    private func workSection(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("WHAT CHANGED")

            if !review.work.isRepository {
                Text("Not a git repository — no before-and-after to compare.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if review.work.changes.isEmpty {
                Text("No file changes since this session started.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(review.work.headline)
                    .font(.system(size: 12, weight: .medium))

                ForEach(review.work.changes.prefix(10)) { change in
                    HStack(spacing: 6) {
                        Text(change.isUntracked ? "new" : change.status)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(change.isUntracked ? .green : .secondary)
                            .frame(width: 26, alignment: .leading)
                        Text(change.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 4)
                        Text("+\(change.added)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.green)
                        Text("−\(change.removed)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }

                if review.work.changes.count > 10 {
                    Text("+ \(review.work.changes.count - 10) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if !review.work.outsidePaths.isEmpty {
                Label(
                    "Touched \(review.work.outsidePaths.count) path(s) outside the project",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.top, 2)
            }
        }
    }

    private func checksSection(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("CHECKS")

            if review.checks.isEmpty {
                Text("No build or test command was detected for this project. "
                    + "Add one in .gentlemerge.json and nothing here has to guess.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(review.checks) { check in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: check.symbol)
                            .font(.system(size: 10))
                            .foregroundStyle(color(for: check))
                        Text(check.name)
                            .font(.system(size: 11.5, weight: .medium))
                        if let reason = check.skipReason {
                            Text(reason)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if check.duration > 0 {
                            Text(String(format: "%.1fs", check.duration))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        if !check.output.isEmpty {
                            Button(expanded.contains(check.id) ? "Hide" : "Output") {
                                if expanded.contains(check.id) {
                                    expanded.remove(check.id)
                                } else {
                                    expanded.insert(check.id)
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10))
                        }
                    }

                    if expanded.contains(check.id), !check.output.isEmpty {
                        ScrollView {
                            Text(check.output)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(7)
                        }
                        .frame(maxHeight: 160)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }

    private func questionsSection(_ review: Review) -> some View {
        Group {
            if !review.openQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    sectionTitle("NEEDS YOUR EYES")
                    ForEach(review.openQuestions, id: \.self) { question in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "eye")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .padding(.top, 2)
                            Text(question)
                                .font(.system(size: 11))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var pastSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("EARLIER REVIEWS")
            ForEach(model.reviews.prefix(5)) { past in
                HStack(spacing: 6) {
                    Image(systemName: past.verdict == .problems ? "xmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(verdictColor(past))
                    Text(past.projectName)
                        .font(.system(size: 11, weight: .medium))
                    Text(past.headline)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(past.startedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    // MARK: - Helpers

    private func verdictColor(_ review: Review) -> Color {
        switch review.verdict {
        case .passed: return .green
        case .problems: return .red
        case .unverified: return .orange
        case .running: return .blue
        }
    }

    private func color(for check: CheckResult) -> Color {
        switch check.status {
        case .passed: return .green
        case .failed, .timedOut: return .red
        case .skipped: return .secondary
        case .running: return .blue
        }
    }

    private func copy(_ review: Review) {
        var lines = ["\(review.projectName): \(review.headline)", "", "Changed: \(review.work.headline)"]
        lines += review.work.changes.prefix(20).map { "  \($0.status) \($0.path) +\($0.added) −\($0.removed)" }
        lines += [""] + review.checks.map { "  [\($0.status.rawValue)] \($0.name)" }
        if !review.openQuestions.isEmpty {
            lines += ["", "Needs your eyes:"] + review.openQuestions.map { "  • \($0)" }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
#endif
