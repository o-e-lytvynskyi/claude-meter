import AppKit

// Debug flags are parsed before `NSApplication.shared` so they never spin up a
// UI. `key=value` tokens after a flag override its defaults.
private let args = CommandLine.arguments

private func value(_ key: String) -> String? {
    args.first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
}

private func positional(after flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag) else { return nil }
    return args[(idx + 1)...].first { !$0.contains("=") && !$0.hasPrefix("--") }
}

private func describe(_ usage: Usage) {
    let now = Date()
    for window in usage.windows {
        let title = window.title.padding(toLength: 22, withPad: " ", startingAt: 0)
        let resets = window.resets.map { "resets \(Format.when($0, now: now)) · in \(Format.span(to: $0, from: now))" }
            ?? "no reset pending"
        print("  \(title) \(String(format: "%3d", window.used))%  step \(Usage.step(window.used))  \(resets)")
    }
}

// `--selftest [usage.txt]` — parses `/usage` text (a saved one, or the live
// CLI's), then checks the rules that no live reading can show on demand:
// the warning steps, reset handling and the wobbling reset time.
if args.contains("--selftest") {
    var failed = 0
    func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failed += 1 }
    }

    let usage: Usage?
    if let path = positional(after: "--selftest") {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); exit(1) }
        usage = Usage.parse(text, now: Date())
    } else {
        switch UsageService.read() {
        case .success(let live): usage = live
        case .failure(let error): print("live read failed: \(error.text)"); exit(1)
        }
    }
    guard let usage else { print("no limits in the text"); exit(1) }
    print("limits:")
    describe(usage)
    print("")

    // Warning steps: (used, last warned) → (warn, keep).
    let cases: [(Int, Int?, Int?, Int?)] = [
        (12, nil, nil, nil), (69, nil, nil, nil), (70, nil, 7, 7), (79, 7, nil, 7), (80, 7, 8, 8),
        (95, nil, 9, 9), (100, 9, 10, 10), (100, 10, nil, 10), (14, 9, nil, nil), (74, 9, 7, 7),
    ]
    for (used, warned, warn, keep) in cases {
        let got = Warnings.due(used: used, warned: warned)
        check(got.warn == warn && got.keep == keep,
              "warn at \(used)% after \(warned.map(String.init) ?? "none") → \(got.warn.map(String.init) ?? "none")")
    }

    let gmt = TimeZone(identifier: "GMT")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = gmt
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))!
    let text = """
        Current session: 14% used · resets Oct 8 at 3:19pm (GMT)
        Current week (all models): 51% used · resets Oct 8 at 12:59pm (GMT)
        Current week (Fable): 0% used · resets Jan 2, 2027 at 1pm (GMT)
        Current week (Sonnet): 3% used
        """
    let parsed = Usage.parse(text, now: now)
    check(parsed?.session?.used == 14, "session parsed")
    check(parsed?.weeks.map(\.title) == ["Weekly · all models", "Weekly · Fable", "Weekly · Sonnet"], "weekly windows in order")
    check(parsed?.weeks[1].resets == calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 13)), "year kept")
    check(parsed?.weeks[2].resets == nil, "no reset pending")
    let bare = Usage.parse("Current session: 5% used · resets 11am (GMT)", now: now)
    check(bare?.session?.resets == calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 11)),
          "bare time past today is tomorrow's")
    let wobble = Usage.parse(text.replacingOccurrences(of: "12:59pm", with: "1pm"), now: now)!
    check(parsed!.steadied(after: wobble).weeks[0].resets == wobble.weeks[0].resets, "wobbling reset keeps the later time")
    check(Usage.parse("You are currently using your subscription", now: now) == nil, "no limits → nil")
    check((0...10).map { StatusIcon.tint($0) }.count == 11 && Usage.step(100) == 10 && Usage.step(99) == 9,
          "eleven colour steps")

    print(failed == 0 ? "\nall checks passed" : "\n\(failed) FAILED")
    exit(failed == 0 ? 0 : 1)
}

// `--icons [path]` — the menu-bar icon at every step, nothing-read first, on a
// light and a dark strip, as a PNG: the colours are checked without a screen
// capture.
if args.contains("--icons") {
    let path = positional(after: "--icons")
        ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("claude-meter-icons.png")
    let steps: [Int?] = [nil] + (0...10).map { $0 }
    let scale: CGFloat = 4, cell: CGFloat = 26
    let size = NSSize(width: cell * CGFloat(steps.count) * scale, height: cell * 2 * scale)
    let image = NSImage(size: size, flipped: false) { _ in
        for (row, background) in [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.16, alpha: 1)].enumerated() {
            background.setFill()
            NSRect(x: 0, y: CGFloat(1 - row) * cell * scale, width: size.width, height: cell * scale).fill()
            for (i, step) in steps.enumerated() {
                var icon = StatusIcon.image(step: step)
                if step == nil {
                    // Templates take the menu bar's colour; stand in for it.
                    let tint: NSColor = row == 0 ? .black : .white
                    let template = icon
                    icon = NSImage(size: StatusIcon.size, flipped: false) { rect in
                        template.draw(in: rect)
                        tint.set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                }
                let side = StatusIcon.size.width * scale
                icon.draw(in: NSRect(x: (CGFloat(i) * cell + 4) * scale, y: (CGFloat(1 - row) * cell + 4) * scale,
                                     width: side, height: side))
            }
        }
        return true
    }
    guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { print("render failed"); exit(1) }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { print("\(error)"); exit(1) }
    print(path)
    exit(0)
}

// `--login-item [on|off]` reports, and optionally changes, the login item
// registration without launching the UI.
if args.contains("--login-item") {
    switch positional(after: "--login-item") {
    case "on":  LaunchAtLogin.apply(true).map { print("note: \($0)") }
    case "off": LaunchAtLogin.apply(false).map { print("note: \($0)") }
    case .some(let other): print("usage: --login-item [on|off] (got \(other))"); exit(2)
    case nil:   break
    }
    print("launch at login: \(LaunchAtLogin.isEnabled ? "enabled" : "disabled")")
    exit(0)
}

// `--lid [on|off]` reports, and optionally changes, whether closing the lid
// sleeps the Mac. Changing it the first time asks for the admin password.
if args.contains("--lid") {
    if let wanted = positional(after: "--lid") {
        guard wanted == "on" || wanted == "off" else { print("usage: --lid [on|off]"); exit(2) }
        if let error = LidSleep.set(wanted == "on") { print("error: \(error.isEmpty ? "cancelled" : error)"); exit(1) }
    }
    let enabled = LidSleep.isEnabled
    print("sleep when lid closes: \(enabled.map { $0 ? "yes" : "no" } ?? "unknown")")
    print("password-free switching: \(FileManager.default.fileExists(atPath: LidSleep.rule) ? "yes" : "no") (\(LidSleep.rule))")
    exit(0)
}

// `--lid-watch [seconds=60]` — prints the lid opening and closing as the app
// sees them; close and open it while this runs.
if args.contains("--lid-watch") {
    let seconds = value("seconds").flatMap(Double.init) ?? 60
    let lid = Lid()
    lid.onChange = { closed in print("\(Format.clock.string(from: Date()))  lid \(closed ? "closed" : "opened")") }
    print("lid now: \(Lid.isClosed.map { $0 ? "closed" : "open" } ?? "no lid"); watch: \(lid.start() ? "on" : "FAILED")")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    exit(0)
}

// `--sleep-timer [seconds=5]` — runs the sleep timer for real, except that the
// last step prints instead of sleeping; checks the idle-sleep hold with pmset.
if args.contains("--sleep-timer") {
    SleepTimer.dryRun = true
    let seconds = value("seconds").flatMap(Double.init) ?? 5
    let timer = SleepTimer()
    timer.set(after: seconds)
    let held = Shell.run("/usr/bin/pmset", ["-g", "assertions"])?.contains("ClaudeMeter sleep timer") ?? false
    print("timer set for \(Int(seconds)) s; idle sleep held: \(held ? "yes" : "no")")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds + 3))
    let released = !(Shell.run("/usr/bin/pmset", ["-g", "assertions"])?.contains("ClaudeMeter sleep timer") ?? true)
    print("deadline cleared: \(timer.deadline == nil ? "yes" : "no"); hold released: \(released ? "yes" : "no")")
    exit(timer.deadline == nil && held && released ? 0 : 1)
}

// `--notify [percent|lid]` — posts the warning the app would post at that
// usage, or the lid reminder. Run from the installed app: notifications need
// its bundle.
if args.contains("--notify") {
    let what = positional(after: "--notify")
    let used = what.flatMap(Int.init) ?? 80
    let warnings = Warnings(defaults: nil)
    Warnings.authorize { granted in
        print("notifications allowed: \(granted ? "yes" : "no"); screen locked: \(Warnings.screenIsLocked ? "yes" : "no")")
        if what == "lid" { return warnings.remindLid(closedSince: Date().addingTimeInterval(-83 * 60)) }
        warnings.post(step: Usage.step(used), window: .init(title: "5-hour limit", used: used,
                                                             resets: Date().addingTimeInterval(95 * 60)))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
