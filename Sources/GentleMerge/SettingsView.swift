#if os(macOS)
import GentleMergeCore
import SwiftUI

/// The switches that apply to every project at once. They used to sit inside
/// each project's pane, which made one global setting look like a per-project
/// one; a settings window is where macOS keeps general, rarely changed options
/// (`settings.md` › Best practices).
@MainActor
struct SettingsView: View {
    let model: InboxModel

    var body: some View {
        Form {
            Section {
                // Who may start headless work, and how much of it per day.
                // Off by default; delegated lets agents trigger within tiers
                // and budget; strict only runs human-created requests and
                // parks the rest for approval.
                Toggle(isOn: Binding(
                    get: { model.config.allowDispatch },
                    set: { model.config.allowDispatch = $0 }
                )) {
                    Text("Allow dispatch")
                    Text("Locally configured agents may run delegated requests without a live session.")
                }

                Picker("Mode", selection: Binding(
                    get: { model.config.dispatchMode },
                    set: { model.config.dispatchMode = $0 }
                )) {
                    Text("Off").tag("off")
                    Text("Delegated").tag("delegated")
                    Text("Strict").tag("strict")
                }

                LabeledContent("Daily budget") {
                    HStack(spacing: 6) {
                        Text("\(model.config.dispatchDailyBudgetMinutes) min")
                            .monospacedDigit()
                        Stepper("Daily budget", value: Binding(
                            get: { model.config.dispatchDailyBudgetMinutes },
                            set: { model.config.dispatchDailyBudgetMinutes = max(0, $0) }
                        ), step: 15)
                        .labelsHidden()
                    }
                }
            } header: {
                Text("Headless work")
            } footer: {
                Text("Delegated lets agents start headless work within tiers and budget. "
                    + "Strict only runs human-created requests.")
                    .foregroundStyle(.secondary)
            }

            Section("Terminals") {
                // Terminal nudges and headless dispatch are separate opt-ins.
                Toggle("Let agents type a one-line notice into an idle terminal", isOn: Binding(
                    get: { model.config.allowNudges },
                    set: { model.config.allowNudges = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("GentleMerge Settings")
    }
}
#endif
