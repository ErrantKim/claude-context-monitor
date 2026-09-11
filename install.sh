#!/bin/bash
# Builds the app, installs it to ~/Applications, and wires it up.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/ClaudeContextMonitor.app"

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc not found. Install the command line tools first:"
  echo "    xcode-select --install"
  exit 1
}

./build.sh

# Stop the running copy before replacing it on disk — launchd refuses to
# bootstrap a job whose program was deleted out from under it.
launchctl bootout "gui/$(id -u)/local.claude-context-monitor" 2>/dev/null || true
pkill -x ClaudeContextMonitor 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R build/ClaudeContextMonitor.app "$APP"

./setup.sh "$APP"

echo "This checkout is no longer needed; everything runs from ~/Applications."
echo
