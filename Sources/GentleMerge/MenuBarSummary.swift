#if os(macOS)
import GentleMergeCore
import AppKit
import SwiftUI

/// The menu bar is a glance, not a workspace: who is running, anything waiting
/// on you, and a way into the window where the actual work happens.
@MainActor
struct MenuBarSummary: View {
    let model: InboxModel
    var openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("GentleMerge")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.liveActivities.isEmpty
                    ? "nothing running"
                    : "\(model.liveActivities.count) running")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if model.liveActivities.isEmpty {
                    Text("Start an agent and it appears here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                ForEach(model.liveActivities.prefix(5)) { activity in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(color(for: activity.state))
                            .frame(width: 6, height: 6)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(activity.provider.displayName) · \(activity.projectName)")
                                .font(.system(size: 11.5, weight: .medium))
                            if let task = activity.currentTask {
                                Text(task)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(RelativeTime.short(from: activity.updatedAt))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }

                if model.pendingCount > 0 {
                    Divider().padding(.vertical, 2)
                    Label("\(model.pendingCount) waiting on you", systemImage: "bell.badge")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            dispatchControls

            Divider()

            HStack(spacing: 8) {
                Button("Open GentleMerge") {
                    openMainWindow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Menu {
                    Button("Refresh") {
                        model.drainNow()
                        model.refreshBus()
                    }
                    Divider()
                    // Terminal nudges and headless dispatch are separate opt-ins.
                    Toggle(
                        "Let agents type a one-line notice into an idle terminal",
                        isOn: Binding(
                            get: { model.config.allowNudges },
                            set: { model.config.allowNudges = $0 }
                        )
                    )
                    Divider()
                    Button("Quit") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 300)
    }

    private var dispatchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Allow dispatch", isOn: Binding(
                get: { model.config.allowDispatch },
                set: { model.config.allowDispatch = $0 }
            ))
            .help("Allow locally configured agents to run delegated requests without a live session")
            .font(.system(size: 11))

            if !model.pendingApprovals.isEmpty {
                Text("APPROVE DISPATCH?")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.pendingApprovals.keys.sorted(), id: \.self) { id in
                            if let (request, target, reason) = model.pendingApprovals[id] {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(request.id) → \(target.label): \(request.title)")
                                        .font(.system(size: 11, weight: .medium))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(reason).font(.system(size: 10)).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Approve") { model.approve(id) }
                                            .disabled(!model.config.allowDispatch)
                                        Button("Deny", role: .destructive) { model.deny(id) }
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func color(for state: AgentActivity.State) -> Color {
        switch state {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return .blue
        case .ended: return .secondary
        }
    }
}
#endif
