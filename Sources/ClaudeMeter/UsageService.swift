import AppKit
import CoreServices
import os

/// `log show --predicate 'subsystem == "dev.local.claude-meter"'`
let log = Logger(subsystem: "dev.local.claude-meter", category: "usage")

/// Reads the plan's limits from the Claude Code CLI and decides when to.
///
/// `claude -p /usage` prints them without asking the model, but every run is a
/// whole CLI start — about 3.8 s of CPU. So it runs only when the numbers can
/// have moved: five minutes after Claude Code on this Mac last wrote to a
/// session (an FSEvents watch on `~/.claude/projects`, which `/usage` itself
/// doesn't touch), a minute after a reset, and every 30 minutes regardless —
/// for claude.ai and other machines, which nothing here can see.
///
/// Main thread only, like everything else in the app.
final class UsageService {
    private(set) var usage: Usage?
    /// Set only by a failed run, never by a valid reading.
    private(set) var failure: String?
    private(set) var isFetching = false
    var onChange: (() -> Void)?

    private static let busyEvery: TimeInterval = 5 * 60
    private static let idleEvery: TimeInterval = 30 * 60
    private static let retryFirst: TimeInterval = 2 * 60

    private var lastRun = Date.distantPast
    /// Claude Code wrote to a session since the last run.
    private var active = true
    private var failures = 0
    private var timer: Timer?
    private var watch: FSEventStreamRef?

    func start() {
        observeSleepWake()
        watchSessions()
        fetch()
    }

    /// The menu's Refresh, and the first reading after a wake.
    func fetch() {
        guard !isFetching else { return }
        isFetching = true
        lastRun = Date()
        active = false
        timer?.invalidate()
        let previous = usage
        DispatchQueue.global(qos: .utility).async {
            let result = Self.read()
            DispatchQueue.main.async {
                self.isFetching = false
                switch result {
                case .success(let fresh):
                    log.notice("read: \(fresh.windows.map { "\($0.title) \($0.used)%" }.joined(separator: ", "), privacy: .public)")
                    self.failures = 0
                    self.failure = nil
                    self.usage = fresh.steadied(after: previous)
                case .failure(let error):
                    log.error("read failed: \(error.text, privacy: .public)")
                    self.failures += 1
                    self.failure = error.text
                }
                self.schedule()
                self.onChange?()
            }
        }
    }

    // MARK: - When to run

    private func schedule() {
        timer?.invalidate()
        let now = Date()
        var next = lastRun.addingTimeInterval(Self.idleEvery)
        if active { next = min(next, lastRun.addingTimeInterval(Self.busyEvery)) }
        if failures > 0 {
            // 2, 4, 8 … minutes, up to the idle interval.
            let backoff = min(Self.retryFirst * pow(2, Double(failures - 1)), Self.idleEvery)
            next = min(next, lastRun.addingTimeInterval(backoff))
        }
        // A minute past a reset, since the CLI may print it a minute early.
        for resets in usage?.windows.compactMap(\.resets) ?? [] where resets > lastRun {
            next = min(next, resets.addingTimeInterval(60))
        }
        let delay = max(next.timeIntervalSince(now), 5)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.fetch() }
        t.tolerance = min(delay * 0.15, 60)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Claude Code wrote to a session: be due within five minutes of the last run.
    private func sessionsChanged() {
        guard !active else { return }
        active = true
        if !isFetching { schedule() }
    }

    private func watchSessions() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<UsageService>.fromOpaque(info).takeUnretainedValue().sessionsChanged()
        }
        // A minute of latency: a busy session writes every few seconds, and
        // one callback a minute is all the schedule needs.
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 60,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        watch = stream
    }

    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.timer?.invalidate()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Give the network a moment to come back before the CLI needs it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.fetch() }
        }
    }

    // MARK: - The CLI

    struct Failure: Error { let text: String }

    /// `claude -p /usage`, parsed. Runs from the app's own folder: Claude
    /// Code keeps a project entry for every directory it runs in.
    static func read() -> Result<Usage, Failure> {
        guard let cli = cli() else { return .failure(Failure(text: "no Claude Code CLI on this Mac")) }
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeMeter")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = run(cli, ["-p", "/usage", "--no-session-persistence"], in: folder, timeout: 60)
        guard let output = result.output else {
            return .failure(Failure(text: "the Claude Code CLI did not answer (\(result.error))"))
        }
        guard let usage = Usage.parse(String(decoding: output, as: UTF8.self), now: Date()) else {
            return .failure(Failure(text: "no limits in the CLI's answer"))
        }
        return .success(usage)
    }

    /// Standard output of a successful run; nil on failure or after `timeout`,
    /// with the reason: the exit status and the end of standard error.
    private static func run(_ tool: URL, _ arguments: [String], in folder: URL,
                            timeout: TimeInterval) -> (output: Data?, error: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        let errors = Pipe()
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return (nil, error.localizedDescription) }
        var output = Data(), errorOutput = Data()
        let drained = DispatchGroup()
        for (pipe, isError) in [(pipe, false), (errors, true)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isError { errorOutput = data } else { output = data }
                drained.leave()
            }
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return (nil, "timed out")
        }
        guard drained.wait(timeout: .now() + 2) == .success else { return (nil, "output not closed") }
        guard process.terminationStatus == 0 else {
            let tail = String(decoding: errorOutput.suffix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, "exit \(process.terminationStatus): \(tail)")
        }
        return (output, "")
    }

    /// The CLI isn't on PATH when Claude Code came with VS Code or the Claude
    /// app; take the newest copy of any of them.
    static func cli() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        var found: [URL] = []
        func add(parent: URL, _ tail: String) {
            for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] {
                let url = parent.appendingPathComponent(name).appendingPathComponent(tail)
                if fm.isExecutableFile(atPath: url.path) { found.append(url) }
            }
        }
        add(parent: home.appendingPathComponent(".vscode/extensions"), "resources/native-binary/claude")
        add(parent: home.appendingPathComponent("Library/Application Support/Claude/claude-code"),
            "claude.app/Contents/MacOS/claude")
        for path in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home.path + "/.local/bin/claude",
                     home.path + "/.claude/local/claude"] where fm.isExecutableFile(atPath: path) {
            found.append(URL(fileURLWithPath: path))
        }
        return found.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }
}
