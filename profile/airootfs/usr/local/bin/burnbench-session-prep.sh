#!/bin/bash
# BurnBench session preparation. Runs once after the XFCE session starts.
set -u

# ------------------------------------------------------------- wallpaper ---
WALLPAPER="/usr/local/share/burnbench/wallpaper.png"
if command -v xfconf-query >/dev/null 2>&1 && [ -e "$WALLPAPER" ]; then
    # update every existing backdrop property, then make sure at least one exists
    while read -r prop; do
        xfconf-query -c xfce4-desktop -p "$prop" -s "$WALLPAPER" 2>/dev/null
    done < <(xfconf-query -c xfce4-desktop -lv 2>/dev/null | awk '/last-image/{print $1}')
    if ! xfconf-query -c xfce4-desktop -lv 2>/dev/null | grep -q last-image; then
        xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/workspace0/last-image \
            -s "$WALLPAPER" -t string -n
    fi
    while read -r prop; do
        xfconf-query -c xfce4-desktop -p "${prop%last-image}image-style" -s 5 -t uint -n 2>/dev/null
    done < <(xfconf-query -c xfce4-desktop -lv 2>/dev/null | awk '/last-image/{print $1}')
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
