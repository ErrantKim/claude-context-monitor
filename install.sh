#!/bin/bash
# Builds and installs Claude Context Monitor for the current user.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/ClaudeContextMonitor.app"
COLLECTOR="$APP/Contents/MacOS/cc-widget-statusline"
LABEL="local.claude-context-monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="$HOME/.claude/settings.json"
CACHE="$HOME/.claude/widget-cache"

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc not found. Install the command line tools first:"
  echo "    xcode-select --install"
  exit 1
}
[ -d "$HOME/.claude" ] || {
  echo "~/.claude not found. Install Claude Code first."
  exit 1
}
[ -d "$HOME/.claude/sessions" ] || \
  echo "warning: ~/.claude/sessions is missing — the session list needs a recent Claude Code."

./build.sh

mkdir -p "$HOME/Applications" "$CACHE" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
cp -R build/ClaudeContextMonitor.app "$APP"

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

Installed. The widget is in your menu bar and starts at login.

  - macOS will ask to allow notifications, and to control your terminal the
    first time it reads which tab is in front. Both are optional.
  - Limits and context fill in as soon as a session renders its status line.
  - This checkout is no longer needed; everything runs from ~/Applications.

DONE
