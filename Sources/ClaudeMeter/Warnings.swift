import AppKit
import UserNotifications

/// A notification each time the 5-hour limit passes another tenth from 70 %:
/// 70, 80, 90, 100. A jump over several steps warns once, for the highest.
/// The last warned step is kept across launches, so a restart doesn't repeat
/// it; usage falling below it means the window reset and the steps re-arm.
final class Warnings: NSObject, UNUserNotificationCenterDelegate {
    static let firstStep = 7

    private let defaults: UserDefaults?
    private static let key = "warnedStep"

    /// Pass nil to keep nothing (the demo).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        super.init()
    }

    /// The owner said no to notifications: the menu offers the way back.
    /// Read asynchronously, so a change shows from the next menu open.
    private(set) var denied = false

    func start() {
        UNUserNotificationCenter.current().delegate = self
        Self.authorize { _ in self.refresh() }
    }

    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async { self.denied = denied }
        }
    }

    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.local.claude-meter"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Asks once; the answer comes back on a background queue.
    static func authorize(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in done(granted) }
    }

    /// The step to warn about now, if any, given the last one warned about.
    static func due(used: Int, warned: Int?) -> (warn: Int?, keep: Int?) {
        let step = Usage.step(used)
        let warned = warned.flatMap { $0 > step ? nil : $0 }
        guard step >= firstStep, step > (warned ?? firstStep - 1) else { return (nil, warned) }
        return (step, step)
    }

    func check(_ window: Usage.Window?) {
        guard let window else { return }
        let warned = defaults?.object(forKey: Self.key) as? Int
        let (warn, keep) = Self.due(used: window.used, warned: warned)
        if keep != warned {
            if let keep { defaults?.set(keep, forKey: Self.key) } else { defaults?.removeObject(forKey: Self.key) }
        }
        if let warn { post(step: warn, window: window) }
    }

    func post(step: Int, window: Usage.Window) {
        let content = UNMutableNotificationContent()
        content.title = step >= 10 ? "Claude's 5-hour limit is used up" : "Claude's 5-hour limit is running out"
        var body = "\(window.used)% used"
        if let resets = window.resets {
            body += " · resets \(Format.when(resets, now: Date())), in \(Format.span(to: resets, from: Date()))"
        }
        content.body = body
        content.sound = .default
        // One identifier: a newer warning replaces the older in Notification Centre.
        deliver(UNNotificationRequest(identifier: "claude-meter.limit", content: content, trigger: nil))
    }

    /// The lid was opened after `since`, and lid sleep is off.
    func remindLid(closedSince since: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Your Mac stayed awake with the lid closed"
        content.body = "Closed for \(Format.span(to: Date(), from: since)). "
            + "\"Stay Awake With Lid Closed\" is still on in ClaudeMeter."
        content.sound = .default
        deliver(UNNotificationRequest(identifier: "claude-meter.lid", content: content, trigger: nil))
    }

    // MARK: - Delivery

    /// Held while the screen is locked, keyed by identifier, so a newer one
    /// replaces an older one as it would in Notification Centre. Main thread.
    private var held: [String: UNNotificationRequest] = [:]
    private var unlockWatch: NSObjectProtocol?

    /// A banner posted on the lock screen is shown there for its few seconds
    /// and goes to Notification Centre unseen — opening the lid lands exactly
    /// there. So while the screen is locked, wait for the unlock.
    private func deliver(_ request: UNNotificationRequest) {
        guard Self.screenIsLocked else { return UNUserNotificationCenter.current().add(request) }
        held[request.identifier] = request
        guard unlockWatch == nil else { return }
        unlockWatch = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            // A moment for the desktop to come up before the banner.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.release() }
        }
    }

    /// On the unlock notification itself: the session flag can lag behind it.
    private func release() {
        if let unlockWatch { DistributedNotificationCenter.default().removeObserver(unlockWatch) }
        unlockWatch = nil
        let requests = held.values
        held = [:]
        requests.forEach { UNUserNotificationCenter.current().add($0) }
    }

    static var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // A menu-bar app counts as frontmost often enough that banners would
    // otherwise be swallowed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
