#!/bin/bash
# AutoBench session preparation (KDE Plasma). Runs once after the session
# starts, via ~/.config/autostart.
set -u

WALLPAPER="/usr/local/share/autobench/wallpaper.png"

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
    set_kde_wallpaper || echo "AutoBench: wallpaper apply failed" >&2
fi

# ------------------------------------------------------------- kwin watchdog -
# No kwin_x11 = no window manager: undecorated windows stacked at 0,0 and
# geometry requests (tiling) silently ignored. Relaunch if it is missing.
if command -v kwin_x11 >/dev/null 2>&1 && ! pgrep -x kwin_x11 >/dev/null 2>&1; then
    echo "AutoBench: kwin_x11 not running - relaunching" >&2
    setsid nohup /usr/bin/kwin_x11 --replace </dev/null \
        >>"$HOME/.kwin-watchdog.log" 2>&1 &
fi

# ---------------------------------------------------- sound service bootstrap -
# .bash_profile gates X on working audio; this is the safety net if that
# regressed. Poll briefly, force-enable the user units, raw daemons last.
if command -v pactl >/dev/null 2>&1; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
    ok=0
    for i in $(seq 1 10); do
        pactl info >/dev/null 2>&1 && { ok=1; break; }
        [ "$i" -eq 3 ] && systemctl --user enable --now \
            pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1
        sleep 1
    done
    if [ "$ok" -ne 1 ]; then
        echo "AutoBench: user PipeWire did not come up, launching raw daemons" >&2
        setsid nohup /usr/bin/pipewire </dev/null >/dev/null 2>&1 &
        sleep 1
        setsid nohup /usr/bin/wireplumber </dev/null >/dev/null 2>&1 &
        sleep 1
        setsid nohup /usr/bin/pipewire-pulse </dev/null >/dev/null 2>&1 &
        sleep 3
        pactl info >/dev/null 2>&1 && echo "AutoBench: raw PipeWire stack is up" >&2
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

# ------------------------------------------- trusted launchers + X ----
xset s off -dpms 2>/dev/null
xset s noblank 2>/dev/null

CONF_FILE="/usr/local/share/autobench/autobench.conf"
[ "$(id -u)" = "0" ] && [ -r "$CONF_FILE" ] && . "$CONF_FILE"
[ "${ASSET_TAG_TOOL:-1}" = "1" ] && ASSET_TAG="AssetTag.desktop" || ASSET_TAG=""

for launcher in \
    "$HOME/Desktop/AutoBench.desktop" \
    ${ASSET_TAG:+"$HOME/Desktop/$ASSET_TAG"}; do
    chmod +x "$launcher" 2>/dev/null || true
    if command -v gio >/dev/null 2>&1; then
        gio set "$launcher" metadata::trusted true 2>/dev/null || true
    fi
done

exit 0
