#!/bin/bash
# BurnBench session preparation. Runs once after the XFCE session starts.
set -u

# ------------------------------------------------------------- wallpaper ---
WALLPAPER="/usr/local/share/burnbench/wallpaper.png"
set_backdrop() { # set_backdrop <monitor-path-fragment>
    local base="/backdrop/screen0/$1"
    xfconf-query -c xfce4-desktop -p "$base/workspace0/last-image" -s "$WALLPAPER" -t string -n 2>/dev/null
    for ws in 1 2 3 4 5 6; do
        xfconf-query -c xfce4-desktop -p "$base/workspace$ws/last-image" -s "$WALLPAPER" -t string -n 2>/dev/null
    done
    xfconf-query -c xfce4-desktop -p "$base/workspace0/image-style" -s 5 -t uint -n 2>/dev/null
}
if command -v xfconf-query >/dev/null 2>&1 && [ -e "$WALLPAPER" ]; then
    # wait (max ~20s) until xfdesktop has registered its per-monitor props,
    # then rewrite every last-image it knows about
    waited=0
    until xfconf-query -c xfce4-desktop -lv 2>/dev/null | grep -q 'last-image'; do
        sleep 2
        waited=$((waited + 2))
        [ "$waited" -ge 20 ] && break
    done
    xfconf-query -c xfce4-desktop -lv 2>/dev/null | awk '/last-image/{
        n=split($1, a, "/"); sub(/^monitor/, "", a[4]); print a[4]
    }' | sort -u | while read -r mon; do
        [ -n "$mon" ] && set_backdrop "monitor$mon"
    done

    # also cover every physically connected output, whether or not xfdesktop
    # has created entries for it yet (eDP-1, HDMI-A-1, ...)
    for conn in /sys/class/drm/card*-*/status; do
        [ "$(cat "$conn" 2>/dev/null)" = "connected" ] || continue
        out=${conn#/sys/class/drm/card*-*/}
        out=${out%/status}
        set_backdrop "monitor$out"
    done
    set_backdrop "monitor0"   # legacy/generic path as final safety net
fi

# ------------------------------------------- volume hotkeys (Fn+Vol etc) ---
# Bind XF86 audio keys to amixer so they work without any panel plugin.
bind_key() { # bind_key <key> <command>
    xfconf-query -c xfce4-keyboard-shortcuts \
        -p "/commands/custom/$1" -s "$2" -t string -n 2>/dev/null
}
bind_key XF86AudioRaiseVolume 'amixer sset Master 5%+ unmute'
bind_key XF86AudioLowerVolume 'amixer sset Master 5%- unmute'
bind_key XF86AudioMute        'amixer sset Master toggle'

# ------------------------------------- trusted launcher + no blanking ------
xset s off -dpms 2>/dev/null
xset s noblank 2>/dev/null

launcher="$HOME/Desktop/Burn-In.desktop"
if command -v gio >/dev/null 2>&1; then
    gio set "$launcher" metadata::trusted true 2>/dev/null || true
fi
chmod +x "$launcher" 2>/dev/null || true

exit 0
