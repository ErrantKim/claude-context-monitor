#!/bin/bash
# Wires an already-installed app into Claude Code: points the status line at the
# collector and registers the app to start at login.
#
#   setup.sh [path to ClaudeContextMonitor.app]
#
# install.sh calls this; a Homebrew install runs it as
# claude-context-monitor-setup.
set -euo pipefail

# Where the app lives: an explicit argument, the usual place, or Homebrew's
# stable opt path (which survives version upgrades, unlike the Cellar path).
APP="${1:-}"
if [ -z "$APP" ]; then
  for candidate in \
    "$HOME/Applications/ClaudeContextMonitor.app" \
    "$(brew --prefix 2>/dev/null)/opt/claude-context-monitor/ClaudeContextMonitor.app"
  do
    [ -d "$candidate" ] && { APP="$candidate"; break; }
  done
fi
[ -n "$APP" ] || { echo "ClaudeContextMonitor.app not found; pass its path."; exit 1; }
COLLECTOR="$APP/Contents/MacOS/cc-widget-statusline"
LABEL="local.claude-context-monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="$HOME/.claude/settings.json"
CACHE="$HOME/.claude/widget-cache"

[ -x "$COLLECTOR" ] || { echo "not found: $COLLECTOR"; exit 1; }
[ -d "$HOME/.claude" ] || { echo "~/.claude not found. Install Claude Code first."; exit 1; }
[ -d "$HOME/.claude/sessions" ] || \
  echo "warning: ~/.claude/sessions is missing — the session list needs a recent Claude Code."

mkdir -p "$CACHE" "$HOME/Library/LaunchAgents"

# An existing status line is kept: its command is saved and the collector runs
# it, printing that output instead of its own.
python3 - "$SETTINGS" "$COLLECTOR" "$CACHE/chain" <<'PY'
import json, os, sys, time

settings_path, ours, chain_path = sys.argv[1:4]

data = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        data = json.load(f)

existing = data.get("statusLine")
if isinstance(existing, dict) and existing.get("command") and existing["command"] != ours:
    if "cc-widget-statusline" not in existing["command"]:
        with open(chain_path, "w") as f:
            f.write(existing["command"])
        print("kept your existing status line, chained: " + existing["command"])

data["statusLine"] = {"type": "command", "command": ours}

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
if os.path.exists(settings_path):
    backup = "%s.bak.%d" % (settings_path, int(time.time()))
    os.replace(settings_path, backup)
    print("settings backed up to " + backup)
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PY

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/ClaudeContextMonitor</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

cat <<'DONE'

Ready. The widget is in your menu bar and starts at login.

  - macOS will ask to allow notifications, and to control your terminal the
    first time it reads which tab is in front. Both are optional.
  - Limits and context fill in as soon as a session renders its status line.

DONE
