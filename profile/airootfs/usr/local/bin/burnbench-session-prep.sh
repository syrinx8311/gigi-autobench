#!/bin/bash
# BurnBench session preparation (KDE Plasma). Runs once after the session
# starts, via ~/.config/autostart.
set -u

WALLPAPER="/usr/local/share/burnbench/wallpaper.png"

# ------------------------------------------------------------- wallpaper ---
set_kde_wallpaper() { # retry until plasmashell is on the bus (max ~30s)
    local waited=0 script
    script='desktops().forEach(function(d){
        d.wallpaperPlugin = "org.kde.image";
        d.currentConfigGroup = ["Wallpaper","org.kde.image","General"];
        d.writeConfig("Image", "file://'"$WALLPAPER"'");
        d.writeConfig("FillMode", 2);   /* stretched */
    })'
    while :; do
        for q in qdbus qdbus-qt6 qdbus6; do
            if command -v "$q" >/dev/null 2>&1; then
                "$q" org.kde.plasmashell /PlasmaShell \
                    evaluateScript "$script" 2>/dev/null && return 0
            fi
        done
        sleep 3
        waited=$((waited + 3))
        [ "$waited" -ge 30 ] && return 1
    done
}
if [ -e "$WALLPAPER" ]; then
    set_kde_wallpaper || echo "BurnBench: wallpaper apply failed" >&2
fi

# ---------------------------------------------------- sound service bootstrap -
# agetty -a skips PAM, so .bash_profile starts user@0.service (whose default
# target pulls in pipewire/wireplumber/pipewire-pulse). Wait here until the
# pulse socket answers; fall back to raw daemons if the user manager is dead.
if command -v pactl >/dev/null 2>&1; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    systemctl start user@0.service >/dev/null 2>&1
    ok=0
    for i in $(seq 1 30); do
        pactl info >/dev/null 2>&1 && { ok=1; break; }
        sleep 1
    done
    if [ "$ok" -ne 1 ]; then
        echo "BurnBench: user PipeWire did not come up, launching raw daemons" >&2
        setsid nohup /usr/bin/pipewire >/dev/null 2>&1 &
        sleep 1
        setsid nohup /usr/bin/wireplumber >/dev/null 2>&1 &
        sleep 1
        setsid nohup /usr/bin/pipewire-pulse >/dev/null 2>&1 &
        sleep 3
        pactl info >/dev/null 2>&1 && echo "BurnBench: raw PipeWire stack is up" >&2
    fi
fi

# ---------------------------------------------------- touchpad tap-to-click -
# libinput defaults to tapping-off; KDE only writes config once a user touches
# the KCM. Force it on for every pointing device that looks like a touchpad.
if command -v xinput >/dev/null 2>&1; then
    xinput --list --name-only 2>/dev/null | while IFS= read -r dev; do
        case "$dev" in
            *[Tt]ouch[Pp]ad*|*Touchscreen*)
                xinput set-prop "$dev" "libinput Tapping Enabled" 1 2>/dev/null
                xinput set-prop "$dev" "libinput Tapping Drag Enabled" 1 2>/dev/null
                ;;
        esac
    done
fi

# ------------------------------------------------- trusted launcher + X ----
xset s off -dpms 2>/dev/null
xset s noblank 2>/dev/null

launcher="$HOME/Desktop/Burn-In.desktop"
chmod +x "$launcher" 2>/dev/null || true
if command -v gio >/dev/null 2>&1; then
    gio set "$launcher" metadata::trusted true 2>/dev/null || true
fi

exit 0
