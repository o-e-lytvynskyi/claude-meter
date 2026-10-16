# ClaudeMeter

A macOS menu-bar meter for Claude's plan limits, plus a sleep timer. No
windows, no settings: one icon and its menu.

Needs a Claude subscription and the Claude Code CLI on the Mac (from VS Code,
the Claude app, Homebrew or the standalone installer). An unofficial personal
tool, not affiliated with Anthropic.

- **Icon** — Claude's spark, coloured by how much of the **5-hour limit** is
  used: eleven steps, one per 10 % (green at 0 % → yellow → orange → red at
  100 %). From 70 % a dot joins the spark, so the warning zone reads by shape
  too. White/black (the menu bar's own colour) means nothing has been read yet.
- **Notifications** — when the 5-hour limit passes 70, 80, 90 and 100 %.
  One per step; a jump over several steps warns once, for the highest. The
  steps re-arm when the window resets.
- **Menu** — every limit with its bar and reset time (5-hour, weekly for all
  models, weekly per model), when they were read, Refresh.
- **Sleep Timer** — sleep the Mac in 1, 2, 3, 4 or 6 hours. Until then the Mac
  doesn't idle to sleep (the display still may); at the deadline it goes to
  sleep. If it slept anyway and wakes after the deadline, the timer is simply
  over — it doesn't put the Mac straight back to sleep.
- **Stay Awake With Lid Closed** — `pmset disablesleep`; checked, the Mac keeps
  running with the lid closed. Opening the lid after a minute or more closed
  brings a reminder notification that it stayed awake, and for how long, so
  the setting isn't forgotten. Quit turns lid sleep back on and the next launch
  turns it off again; the sleep timer and uninstall end it. While it is on,
  **no** sleep works — the Apple menu's Sleep does nothing — so the menu adds
  **Sleep Now**, which allows sleep for that one sleep and blocks it again on
  wake.
- **Launch at Login** — `SMAppService`, its status is the source of truth.

Notifications follow Focus: under an active Focus they go straight to
Notification Centre unless ClaudeMeter is among the Focus's allowed apps
(System Settings → Focus → the mode → Allowed Notifications). Time Sensitive
would break through, but its entitlement needs an Apple signature — an ad-hoc
signed app carrying it is killed at launch. Notifications posted while the
screen is locked wait for the unlock.

## Where the numbers come from

`claude -p /usage --no-session-persistence` — the Claude Code CLI prints the
limits without calling the model. It is a whole CLI start (~3.8 s of CPU), so
it runs only when the numbers can have moved:

- five minutes after the last run, if Claude Code on this Mac has written to a
  session since (an FSEvents watch on `~/.claude/projects`; `/usage` itself
  doesn't write there);
- a minute after a reset;
- every 30 minutes regardless — usage on claude.ai or other machines is
  invisible otherwise;
- on wake, and on Refresh.

Failures back off from 2 minutes up to 30 and keep the last reading. The CLI
is found among the VS Code extension, the Claude app and the usual install
paths (it is often not on `PATH`); the newest copy wins. It runs from
`~/Library/Application Support/ClaudeMeter`, since Claude Code keeps a project
entry per working directory.

Idle, the app itself uses no CPU: no timers besides the next due run.

## Lid sleep and the password

Changing `disablesleep` needs root. The first switch shows the macOS admin
password dialog and installs `/etc/sudoers.d/claude-meter`, which allows
exactly `pmset -a disablesleep 0` and `pmset -a disablesleep 1` for your user,
password-free. That is what lets the sleep timer, Quit and the next launch
switch it with nobody at the keyboard. `./uninstall.sh` removes the rule.

## Build and install

```sh
./install.sh           # build, install to /Applications, launch
./install.sh --dev     # keep .build/ for fast rebuilds
./uninstall.sh         # stop, restore lid sleep, remove the app and the sudoers rule
```

Requires the Command Line Tools; builds against the macOS 26 SDK.

## Debug flags

Run the installed binary, `/Applications/ClaudeMeter.app/Contents/MacOS/ClaudeMeter`:

| Flag | What it does |
|---|---|
| `--selftest [usage.txt]` | parses saved `/usage` text, or the live CLI's, and checks warning steps, reset handling and date parsing |
| `--icons [path.png]` | the menu-bar icon at every step on light and dark strips |
| `--demo [used=N] [timer] [sleepmenu] [closed]` | made-up reading, the menu (or the timer submenu) opened under the icon; runs alongside the installed copy |
| `--sleep-timer [seconds=5]` | runs the sleep timer, printing instead of sleeping; checks the idle-sleep hold appears and goes |
| `--lid [on\|off]` | reads, and optionally sets, lid sleep and whether the sudoers rule is in place |
| `--lid-watch [seconds=60]` | prints the lid closing and opening as the app sees them |
| `--notify [percent\|lid]` | posts the warning for that usage, or the lid reminder (needs the installed bundle) |
| `--login-item [on\|off]` | reads, and optionally sets, launch at login |

Logs: `log show --predicate 'subsystem == "dev.local.claude-meter"'`.
