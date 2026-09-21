#if os(macOS)
import GentleMergeCore
import SwiftUI

/// Restore points for one project. Restoring writes files back and never
/// deletes, so the worst case is files you have to remove yourself.
@MainActor
struct SnapshotsView: View {
    let model: InboxModel
    let projectPath: String
    var onBack: () -> Void

    @State private var snapshots: [SnapshotRef] = []
    @State private var confirming: String?
    @State private var report: RestoreReport?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if snapshots.isEmpty {
                        Text(GitSnapshot.isRepository(projectPath)
                            ? "No restore points yet. One is taken whenever a change is waiting for your approval."
                            : "This project is not a git repository, so there is nothing to snapshot.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }

                    ForEach(snapshots) { snapshot in
                        row(snapshot)
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .frame(maxHeight: 420)

            if let report {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Label(report.summary, systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                    if !report.created.isEmpty {
                        Text("Left in place: " + report.created.prefix(4).joined(separator: ", "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let safety = report.safety {
                        Text("Undo this restore with “\(safety.label)”.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 420)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Text("Restore points · \(URL(fileURLWithPath: projectPath).lastPathComponent)")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button("Take one now") {
                _ = model.createSnapshot(forProjectAt: projectPath, label: "manual")
                reload()
            }
            .controlSize(.small)
            .disabled(!GitSnapshot.isRepository(projectPath))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func row(_ snapshot: SnapshotRef) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(snapshot.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(snapshot.createdAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if confirming == snapshot.id {
                HStack(spacing: 6) {
                    Text("Write these files back over the current ones?")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore") {
                        report = model.restore(snapshot)
                        confirming = nil
                        reload()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Cancel") { confirming = nil }
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    Button("Restore…") { confirming = snapshot.id }
                        .controlSize(.small)
                    Text(snapshot.commit.prefix(8))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func reload() {
        snapshots = model.snapshots(forProjectAt: projectPath)
    }
}
#endif
