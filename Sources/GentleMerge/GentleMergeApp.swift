#if os(macOS)
import GentleMergeCore
import AppKit
import SwiftUI

@MainActor
enum Shared {
    static let model = InboxModel()
    static let windowID = "gentlemerge-main"
}

@MainActor
struct GentleMergeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = Shared.model
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("GentleMerge", id: Shared.windowID) {
            MainWindow(model: model)
        }
        .defaultSize(width: 940, height: 640)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarSummary(model: model, openMainWindow: showWindow)
        } label: {
            Image(systemName: menuBarSymbol)
            if model.liveActivities.count > 1 {
                Text("\(model.liveActivities.count)")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func showWindow() {
        openWindow(id: Shared.windowID)
        // A menu bar app is not the active app, so the window would open behind
        // whatever you were looking at.
        NSApp.activate(ignoringOtherApps: true)
    }

    private var menuBarSymbol: String {
        if model.pendingCount > 0 || !model.pendingApprovals.isEmpty { return "tray.full.fill" }
        return model.liveActivities.isEmpty ? "tray" : "antenna.radiowaves.left.and.right"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app, but with a real window you can actually work in.
        NSApp.setActivationPolicy(.accessory)
        Notifier.shared.configure(model: Shared.model)
        Shared.model.onNotify = { item in
            Notifier.shared.post(item)
        }
        Shared.model.onDispatchApproval = { request, target, reason in
            Notifier.shared.postDispatchApproval(request, target: target, reason: reason)
        }
        Shared.model.start()

        // An accessory app does not get a window handed to it. Bring the one
        // SwiftUI made to the front, or launching looks like nothing happened.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Shared.model.stop()
    }
}
#endif
