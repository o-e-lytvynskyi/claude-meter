import AppKit
import IOKit.pwr_mgt

/// "Sleep in N hours": keeps the Mac from idling to sleep until then, and
/// puts it to sleep when the time comes — the Claude session runs to its
/// end, and the Mac doesn't stay up all night after it.
///
/// Main thread only.
final class SleepTimer {
    static let choices = [1, 2, 3, 4, 6]

    private(set) var deadline: Date?
    /// Called just before the Mac is put to sleep, so lid sleep can come back
    /// first — the Mac can't sleep while it is disabled.
    var willSleep: (() -> Void)?
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var assertion: IOPMAssertionID = 0

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.woke() }
    }

    /// `--sleep-timer` prints instead of sleeping.
    static var dryRun = false

    func set(hours: Int?) {
        set(after: hours.map { TimeInterval($0) * 3600 })
    }

    func set(after interval: TimeInterval?) {
        deadline = interval.map { Date().addingTimeInterval($0) }
        arm()
        onChange?()
    }

    private func arm() {
        timer?.invalidate()
        timer = nil
        guard let deadline else {
            release()
            return
        }
        hold()
        // Timers count awake time only; `woke()` re-arms after a sleep.
        let t = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in self?.fire() }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fire() {
        guard let deadline, Date() >= deadline.addingTimeInterval(-60) else { return arm() }
        // Long past it, the Mac was asleep at the deadline and this is the
        // wake delivering the timer late: done, without sleeping again.
        let late = Date().timeIntervalSince(deadline) > 120
        self.deadline = nil
        arm()
        onChange?()
        guard !late else { return }
        willSleep?()
        Self.sleepNow()
    }

    /// The Mac slept on its own before the deadline. Past it, the job is
    /// done — putting it back to sleep the moment the lid opens would be
    /// a trap.
    private func woke() {
        guard let deadline else { return }
        if Date() >= deadline {
            self.deadline = nil
            onChange?()
        }
        arm()
    }

    // MARK: - System

    private func hold() {
        guard assertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "ClaudeMeter sleep timer" as CFString, &id)
        if result == kIOReturnSuccess { assertion = id }
    }

    private func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    static func sleepNow() {
        if dryRun { return print("would sleep now") }
        _ = Shell.run("/usr/bin/pmset", ["sleepnow"])
    }
}

/// Whether closing the lid puts the Mac to sleep: `pmset disablesleep`.
///
/// That needs root. The first switch asks for the admin password once and
/// leaves a sudoers rule allowing exactly `pmset -a disablesleep 0|1`; after
/// that the app flips it with `sudo -n`, which the sleep timer, Quit and the
/// next launch need, since nobody is there to type a password. `pmset -g` is
/// the source of truth — nothing is stored here.
enum LidSleep {
    static let rule = "/etc/sudoers.d/claude-meter"

    /// What `pmset -g` says; nil when it can't be read.
    static var isEnabled: Bool? {
        guard let output = Shell.run("/usr/bin/pmset", ["-g"]) else { return nil }
        let disabled = output.components(separatedBy: .newlines).contains {
            let parts = $0.split(whereSeparator: \.isWhitespace)
            return parts.count == 2 && parts[0] == "SleepDisabled" && parts[1] == "1"
        }
        return !disabled
    }

    /// Without asking: works once the sudoers rule is there.
    @discardableResult
    static func setQuietly(_ enabled: Bool) -> Bool {
        Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", enabled ? "0" : "1"]) != nil
    }

    /// Quietly if it can; otherwise through the admin password dialog, which
    /// also installs the rule. Returns an error text, nil on success.
    static func set(_ enabled: Bool) -> String? {
        if setQuietly(enabled) { return nil }
        let line = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let script = """
            T=$(/usr/bin/mktemp) && printf '%s\\n' '\(line)' > "$T" && /usr/sbin/visudo -cf "$T" >/dev/null \
            && /usr/bin/install -m 0440 -o root -g wheel "$T" \(rule); /bin/rm -f "$T"; \
            /usr/bin/pmset -a disablesleep \(enabled ? "0" : "1")
            """
        let source = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" "
            + "with prompt \"ClaudeMeter wants to change whether closing the lid puts the Mac to sleep.\" "
            + "with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        // -128: the dialog was cancelled — not an error worth showing.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "" }
        return error[NSAppleScript.errorMessage] as? String ?? "could not change lid sleep"
    }
}

enum Shell {
    /// Standard output of a successful run, nil otherwise. Short system tools
    /// only — this blocks the caller.
    static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// The lid opening and closing, as the power manager reports it — a message
/// from `IOPMrootDomain`, no polling. With lid sleep off the Mac doesn't sleep
/// or wake around the lid, so this is the only way to see it.
///
/// Main thread only.
final class Lid {
    /// True when the lid has just closed, false when it has just opened.
    var onChange: ((Bool) -> Void)?

    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var closed = Lid.isClosed ?? false

    /// `iokit_family_msg(sub_iokit_powermanagement, 0x100)`: a macro Swift
    /// doesn't import.
    private static let clamshellMessage: UInt32 = 0xE003_4100

    /// `AppleClamshellState` on the root domain; nil on a Mac without a lid.
    static var isClosed: Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
    }

    /// False when the watch could not be set up.
    @discardableResult
    func start() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        defer { IOObjectRelease(root) }
        IONotificationPortSetDispatchQueue(port, .main)
        self.port = port
        let callback: IOServiceInterestCallback = { refcon, _, type, argument in
            guard let refcon, type == Lid.clamshellMessage else { return }
            let closed = (Int(bitPattern: argument) & Int(kClamshellStateBit)) != 0
            Unmanaged<Lid>.fromOpaque(refcon).takeUnretainedValue().changed(closed)
        }
        let result = IOServiceAddInterestNotification(port, root, "IOGeneralInterest", callback,
                                                      Unmanaged.passUnretained(self).toOpaque(), &notifier)
        return result == KERN_SUCCESS
    }

    private func changed(_ closed: Bool) {
        // The message repeats on other clamshell events (an external display
        // coming and going); only a real change counts.
        guard closed != self.closed else { return }
        self.closed = closed
        onChange?(closed)
    }
}
