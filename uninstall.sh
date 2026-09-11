#!/bin/bash
# Removes everything install.sh put in place.
set -uo pipefail

LABEL="local.claude-context-monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="$HOME/.claude/settings.json"
CACHE="$HOME/.claude/widget-cache"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$PLIST"
pkill -x ClaudeContextMonitor 2>/dev/null

# Put back the status line we displaced, or drop the key if there was none.
python3 - "$SETTINGS" "$CACHE/chain" <<'PY'
import json, os, sys

settings_path, chain_path = sys.argv[1:3]
if not os.path.exists(settings_path):
    raise SystemExit

with open(settings_path) as f:
    data = json.load(f)

chained = ""
if os.path.exists(chain_path):
    with open(chain_path) as f:
        chained = f.read().strip()

if chained:
    data["statusLine"] = {"type": "command", "command": chained}
    print("restored your previous status line: " + chained)
else:
    data.pop("statusLine", None)
    print("removed the status line entry")

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PY

rm -rf "$HOME/Applications/ClaudeContextMonitor.app" "$CACHE"
defaults delete local.claude-context-monitor 2>/dev/null

echo "Uninstalled. ~/.claude itself was not touched."
echo "Your own push script, if you wrote one, was left alone."
