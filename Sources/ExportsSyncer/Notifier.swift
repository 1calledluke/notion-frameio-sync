import Foundation
import UserNotifications

/// User-visible alerts.
///
/// This app spends its life in the menu bar with nobody looking at it, so a
/// failure that only reaches `activity.log` is a failure nobody learns about:
/// Frame.io sync died on 2026-07-17 and went unnoticed for 25 days. Anything
/// that stops the pipeline until a human acts must come through here.
enum Notifier {

    static func notify(title: String = "Exports Syncer", body: String) {
        // UNUserNotificationCenter throws an unrecoverable NSException outside a
        // real .app bundle. Log instead.
        guard Bundle.main.bundleIdentifier != nil else {
            Log("(cli) \(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log("Notification error: \(error.localizedDescription)") }
        }
    }

    private static let lock = NSLock()
    private static var lastNotice: [String: Date] = [:]

    /// Log always, notify at most once per `reason` every 6 hours.
    ///
    /// The pollers retry every 15–300 seconds, so an unthrottled alert would
    /// fire hundreds of times a day and get muted — which is the same as
    /// silence, just louder.
    static func report(reason: String, _ message: String) {
        Log("\(reason): \(message)")
        lock.lock()
        let recent = lastNotice[reason].map { Date().timeIntervalSince($0) < 6 * 3600 } ?? false
        if !recent { lastNotice[reason] = Date() }
        lock.unlock()
        guard !recent else { return }
        notify(body: message)
    }

    /// Called when the thing works again, so the next breakage alerts at once
    /// instead of being swallowed by the throttle.
    static func clear(reason: String) {
        lock.lock()
        lastNotice[reason] = nil
        lock.unlock()
    }
}
