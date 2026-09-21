#if os(macOS)
import GentleMergeCore
import AppKit
import UserNotifications

/// Notifications carry the decision itself: Allow and Deny are buttons on the
/// banner, so answering never requires finding a window.
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()

    private weak var model: InboxModel?
    private var authorized = false

    private enum Category {
        static let attention = "gentlemerge.attention"
    }

    private enum Action {
        static let open = "gentlemerge.open"
        static let handled = "gentlemerge.handled"
    }

    func configure(model: InboxModel) {
        self.model = model

        // Running unbundled (swift run) there is no notification client at all;
        // fall back to a beep rather than trapping.
        guard Bundle.main.bundleIdentifier != nil else { return }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.attention,
                actions: [
                    UNNotificationAction(identifier: Action.open, title: "Open terminal", options: [.foreground]),
                    UNNotificationAction(identifier: Action.handled, title: "Got it", options: []),
                ],
                intentIdentifiers: []
            )
        ])

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func post(_ item: InboxItem) {
        guard Bundle.main.bundleIdentifier != nil, authorized else {
            if model?.config.playSound == true { NSSound.beep() }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(item.projectName) · \(item.provider.displayName)"
        content.subtitle = item.title
        content.body = item.summary
        content.categoryIdentifier = Category.attention
        content.userInfo = ["itemID": item.id]
        content.interruptionLevel = .active
        if model?.config.playSound == true {
            content.sound = .default
        }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
        )
    }

    func postDispatchApproval(_ request: AgentRequest, target: AgentTarget, reason: String) {
        guard Bundle.main.bundleIdentifier != nil, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Approve dispatch?"
        content.body = "\(request.id) → \(target.label): \(request.title)\n\(reason) — open the menu bar to approve or deny."
        content.interruptionLevel = .active
        if model?.config.playSound == true { content.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "dispatch-\(request.id)", content: content, trigger: nil)
        )
    }

    func withdraw(_ itemID: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [itemID])
    }

    private func handle(actionID: String, itemID: String) {
        guard let model, let item = model.items.first(where: { $0.id == itemID }) else { return }
        switch actionID {
        case Action.open, UNNotificationDefaultActionIdentifier:
            model.jumpToTerminal(item)
        case Action.handled:
            model.markHandled(item)
        default:
            break
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let itemID = response.notification.request.content.userInfo["itemID"] as? String
        if let itemID {
            Task { @MainActor in
                Notifier.shared.handle(actionID: actionID, itemID: itemID)
            }
        }
        completionHandler()
    }
}
#endif
