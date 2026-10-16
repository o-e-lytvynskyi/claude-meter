import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let isDemo = CommandLine.arguments.contains("--demo")
    private let service = UsageService()
    private let sleepTimer = SleepTimer()
    private let lid = Lid()
    /// When the lid last closed with lid sleep off; nil while it's open.
    private var lidClosedAt: Date?
    private lazy var warnings = Warnings(defaults: isDemo ? nil : .standard)
    private var statusItem: NSStatusItem?
    /// The demo's reading, standing in for the service's.
    private var demoUsage: Usage?

    /// The owner chose "Stay Awake With Lid Closed". Kept across launches:
    /// Quit turns lid sleep back on, so a Mac nobody watches never stays up in
    /// a bag, and the next launch turns it off again. The sleep timer ends it.
    private var stayAwake: Bool {
        get { UserDefaults.standard.bool(forKey: "lidOffByUs") }
        set { UserDefaults.standard.set(newValue, forKey: "lidOffByUs") }
    }

    private var usage: Usage? { isDemo ? demoUsage : service.usage }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The demo is allowed to run alongside the installed copy — otherwise
        // the single-instance guard would kill it on launch.
        guard isDemo || !handOffToRunningInstance() else { return }

        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()

        if isDemo {
            seedDemo()
            return
        }

        warnings.start()
        service.onChange = { [weak self] in self?.updated() }
        sleepTimer.onChange = { [weak self] in self?.render() }
        sleepTimer.willSleep = { [weak self] in
            self?.stayAwake = false
            self?.restoreLidSleep()
        }
        lid.onChange = { [weak self] closed in self?.lidChanged(closed) }
        // "Sleep Now" lets lid sleep back on for the sleep; take it away again.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.stayAwake, LidSleep.isEnabled == true else { return }
            LidSleep.setQuietly(false)
        }
        lid.start()
        if stayAwake, LidSleep.isEnabled == true { LidSleep.setQuietly(false) }
        service.start()
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isDemo, stayAwake else { return }
        restoreLidSleep()
    }

    private func restoreLidSleep() {
        guard LidSleep.isEnabled == false else { return }
        LidSleep.setQuietly(true)
    }

    /// Opened after a while closed with lid sleep off: say so, or it is easy
    /// to forget the Mac now runs in a bag.
    private func lidChanged(_ closed: Bool) {
        if closed {
            lidClosedAt = LidSleep.isEnabled == false ? Date() : nil
            return
        }
        defer { lidClosedAt = nil }
        guard let since = lidClosedAt, Date().timeIntervalSince(since) >= 60, LidSleep.isEnabled == false else { return }
        // The lock screen, if any, comes up a moment after the lid opens;
        // ask only once it has, or the reminder slips past the lock check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.warnings.remindLid(closedSince: since) }
    }

    /// A second launch just exits; the first one keeps the menu bar.
    private func handOffToRunningInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.local.claude-meter"
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0 != NSRunningApplication.current
        }
        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let btn = item.button else { return }
        btn.target = self
        btn.action = #selector(statusItemClicked)
        btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// A new reading or a failed one. Everything that depends on the reading
    /// is updated here.
    private func updated() {
        warnings.check(service.usage?.session)
        render()
    }

    private var lastStep: Int?? = .none

    private func render() {
        guard let btn = statusItem?.button else { return }
        let step = usage?.session.map { Usage.step($0.used) }
        // Redraw only when the colour changes; the tooltip is cheap.
        if lastStep != .some(step) {
            lastStep = .some(step)
            btn.image = StatusIcon.image(step: step)
        }
        btn.toolTip = tooltip()
    }

    private func tooltip() -> String {
        let now = Date()
        var lines: [String] = []
        if let usage {
            for window in usage.windows {
                var line = "\(window.title): \(window.used)%"
                if let resets = window.resets, resets > now { line += ", resets \(Format.when(resets, now: now))" }
                lines.append(line)
            }
            lines.append("Updated \(Format.ago(usage.at, now: now))")
        } else {
            lines.append(service.isFetching ? "Claude: reading the limits…" : "Claude: no limits yet")
        }
        if let failure = service.failure { lines.append("Last read failed: \(failure)") }
        if LidSleep.isEnabled == false { lines.append("Stays awake with the lid closed") }
        if let deadline = sleepTimer.deadline {
            lines.append("Sleeps at \(Format.when(deadline, now: now))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Menu

    @objc private func statusItemClicked() {
        guard let btn = statusItem?.button, let event = NSApp.currentEvent else { return }
        render()
        if !isDemo { warnings.refresh() }
        // Left click opens the same menu as right, so the icon is never a dead pixel.
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: btn)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let now = Date()

        let header = NSMenuItem()
        let view = NSHostingView(rootView: UsageView(usage: usage, failure: isDemo ? nil : service.failure,
                                                     isFetching: !isDemo && service.isFetching, now: now))
        view.frame.size = view.fittingSize
        header.view = view
        menu.addItem(header)

        let refresh = action("Refresh", #selector(refreshNow), key: "r")
        refresh.isEnabled = !service.isFetching
        menu.addItem(refresh)
        if !isDemo, warnings.denied {
            menu.addItem(action("Turn On Limit Notifications…", #selector(openNotificationSettings)))
        }

        menu.addItem(.separator())
        menu.addItem(sleepTimerItem(now: now))

        let awake = action("Stay Awake With Lid Closed", #selector(toggleStayAwake))
        let lidSleeps = LidSleep.isEnabled
        awake.state = lidSleeps == false ? .on : .off
        awake.isEnabled = lidSleeps != nil
        menu.addItem(awake)
        if lidSleeps == false {
            // `disablesleep` blocks every sleep, the Apple menu's too.
            menu.addItem(action("Sleep Now", #selector(sleepNow)))
            menu.addItem(secondary("While on, Apple menu → Sleep does nothing"))
        }

        menu.addItem(.separator())
        let login = action("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit ClaudeMeter", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    private func sleepTimerItem(now: Date) -> NSMenuItem {
        let item = NSMenuItem(title: "Sleep Timer", action: nil, keyEquivalent: "")
        if let deadline = sleepTimer.deadline {
            item.title = "Sleep in \(Format.span(to: deadline, from: now))"
        }
        let sub = NSMenu()
        if sleepTimer.deadline != nil {
            sub.addItem(action("Cancel", #selector(cancelSleepTimer)))
            sub.addItem(.separator())
        }
        for hours in SleepTimer.choices {
            let choice = action(hours == 1 ? "In 1 Hour" : "In \(hours) Hours", #selector(setSleepTimer(_:)))
            choice.tag = hours
            sub.addItem(choice)
        }
        if let deadline = sleepTimer.deadline {
            sub.addItem(.separator())
            sub.addItem(secondary("Sleeps at \(Format.when(deadline, now: now)); stays awake until then"))
        }
        item.submenu = sub
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func secondary(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        return item
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        guard !isDemo else { return }
        service.fetch()
        render()
    }

    @objc private func openNotificationSettings() {
        Warnings.openSettings()
    }

    @objc private func setSleepTimer(_ sender: NSMenuItem) {
        sleepTimer.set(hours: sender.tag)
    }

    @objc private func cancelSleepTimer() {
        sleepTimer.set(hours: nil)
    }

    @objc private func sleepNow() {
        // Lid sleep comes back after the wake (`didWake` above).
        LidSleep.setQuietly(true)
        SleepTimer.sleepNow()
    }

    @objc private func toggleStayAwake() {
        guard let lidSleeps = LidSleep.isEnabled else { return }
        if let error = LidSleep.set(!lidSleeps) {
            if !error.isEmpty { show("Could not change lid sleep", error) }
            return
        }
        stayAwake = lidSleeps
        render()
    }

    @objc private func toggleLaunchAtLogin() {
        if let error = LaunchAtLogin.apply(!LaunchAtLogin.isEnabled) {
            show("Launch at login", error)
        }
    }

    private func show(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Demo

    /// `--demo [used=N]`: a made-up reading, and the menu opened under the icon
    /// so it can be screenshotted.
    private func seedDemo() {
        let now = Date()
        let used = CommandLine.arguments.first { $0.hasPrefix("used=") }.flatMap { Int($0.dropFirst(5)) } ?? 12
        demoUsage = Usage(
            session: .init(title: "5-hour limit", used: used, resets: now.addingTimeInterval(4 * 3600 + 17 * 60)),
            weeks: [.init(title: "Weekly · all models", used: 51, resets: now.addingTimeInterval(2 * 3600 + 3 * 60)),
                    .init(title: "Weekly · Fable", used: 4, resets: now.addingTimeInterval(3 * 86400 + 3600))],
            at: now.addingTimeInterval(-3 * 60))
        render()
        if CommandLine.arguments.contains("timer") { sleepTimer.set(hours: 3) }
        guard !CommandLine.arguments.contains("closed"), let btn = statusItem?.button else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            // `sleepmenu`: the timer's submenu on its own, for its screenshot.
            let menu = CommandLine.arguments.contains("sleepmenu")
                ? self.sleepTimerItem(now: Date()).submenu! : self.buildMenu()
            menu.popUp(positioning: menu.items.first, at: NSPoint(x: 0, y: btn.bounds.height + 4), in: btn)
        }
    }
}
