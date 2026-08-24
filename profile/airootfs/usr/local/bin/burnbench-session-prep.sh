#!/bin/bash
# BurnBench session preparation. Runs once after the XFCE session starts.
set -u

# Disable screen blanking / DPMS so an unattended machine never sleeps mid-test
xset s off -dpms 2>/dev/null
xset s noblank 2>/dev/null

# Mark the desktop launcher as trusted so double-click runs it without a prompt
launcher="$HOME/Desktop/Burn-In.desktop"
if command -v gio >/dev/null 2>&1; then
    gio set "$launcher" metadata::trusted true 2>/dev/null || true
fi
chmod +x "$launcher" 2>/dev/null || true

exit 0
