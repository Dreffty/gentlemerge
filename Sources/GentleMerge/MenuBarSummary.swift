#if os(macOS)
import GentleMergeCore
import AppKit
import SwiftUI

/// The menu bar is a glance, not a workspace: who is running, anything waiting
/// on you, and a way into the window where the actual work happens.
///
/// A panel rather than a plain menu, against `the-menu-bar.md`'s default,
/// because approving a dispatch needs a reason to read and two buttons beside
/// it, which a menu item cannot hold.
@MainActor
struct MenuBarSummary: View {
    let model: InboxModel
    var openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("GentleMerge")
                    .font(.headline)
                Spacer()
                Text(model.liveActivities.isEmpty
                    ? "Nothing running"
                    : "\(model.liveActivities.count) running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                if model.liveActivities.isEmpty {
                    Text("Start an agent and it appears here.")
                        .foregroundStyle(.secondary)
                }

                ForEach(model.liveActivities.prefix(5)) { activity in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(activity.state.tint)
                            .frame(width: 7, height: 7)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(activity.displayName) · \(activity.projectName)")
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(activity.currentTask ?? activity.stateLabel)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                        Text(RelativeTime.short(from: activity.updatedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }

                if model.liveActivities.count > 5 {
                    Text("+ \(model.liveActivities.count - 5) more in the window")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if model.pendingCount > 0 {
                    Label("\(model.pendingCount) waiting on you", systemImage: "bell.badge.fill")
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                        .padding(.top, 3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            dispatchControls

            Divider()

            HStack(spacing: 8) {
                Button("Open GentleMerge") {
                    openMainWindow()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Spacer()

                Menu {
                    Button("Refresh") {
                        model.drainNow()
                        model.refreshBus()
                    }
                    .keyboardShortcut("r")
                    // `SettingsLink` rather than `openSettings`: the latter
                    // needs the macOS 15 SDK, and CI builds against 14.
                    // The Settings window brings the app forward itself.
                    SettingsLink { Text("Settings…") }
                        .keyboardShortcut(",")
                    Divider()
                    Button("Quit GentleMerge") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
    }

    private var dispatchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.config.allowDispatch },
                set: { model.config.allowDispatch = $0 }
            )) {
                Text("Allow dispatch")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Allow locally configured agents to run delegated requests without a live session")

            if !model.pendingApprovals.isEmpty {
                Text("Approve dispatch?")
                    .font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.pendingApprovals.keys.sorted(), id: \.self) { id in
                            if let (request, target, reason) = model.pendingApprovals[id] {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(request.id) → \(target.label): \(request.title)")
                                        .fontWeight(.medium)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(reason)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack {
                                        Button("Approve") { model.approve(id) }
                                            .disabled(!model.config.allowDispatch)
                                        Button("Deny", role: .destructive) { model.deny(id) }
                                    }
                                    .controlSize(.small)
                                    .padding(.top, 2)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
#endif
