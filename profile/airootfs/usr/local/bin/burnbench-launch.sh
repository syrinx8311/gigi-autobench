#!/bin/bash
# BurnBench desktop launcher: burn-in terminal (left) + keyboard test pad
# (right), tiled side by side via wmctrl. Guarded against double-launch.
set -u

pgrep -f '/usr/local/bin/burn-in.sh' >/dev/null && {
    kdialog --sorry "Burn-in is already running." 2>/dev/null || true
    exit 0
}

# right half: the keyboard test pad (kate ships kwrite; use kate binary)
setsid nohup kate "$HOME/keyboard-test.txt" </dev/null >/dev/null 2>&1 &

# left half: the burn-in terminal itself
konsole --title BurnBench -e /bin/bash -c \
    '/usr/local/bin/burn-in.sh; echo; read -n 1 -s -r -p "Finished. Press any key to close this window..."' &

tile() {
    command -v wmctrl >/dev/null 2>&1 || return 0
    local line wa geo w h x y hw tries=0
    while [ "$tries" -lt 30 ]; do
        sleep 1; tries=$((tries + 1))
        wmctrl -lx 2>/dev/null | grep -qi konsole || continue
        wmctrl -lx 2>/dev/null | grep -qi kate    || continue
        line="$(wmctrl -d 2>/dev/null | awk '/[*]/')"
        # ... WA: x,y WxH
        wa="${line##*WA: }"
        rest="${wa#*,}"
        x="${wa%%,*}"; y="${rest%% *}"; geo="${rest##* }"
        w="${geo%%x*}"; h="${geo##*x}"
        [ -z "$w" ] || [ -z "$h" ] && continue
        hw=$((w / 2))
        for t in 1 2; do
            wmctrl -r BurnBench   -b remove,maximized_vert,maximized_horz -b remove,fullscreen
            wmctrl -r keyboard-test -b remove,maximized_vert,maximized_horz -b remove,fullscreen
            wmctrl -r BurnBench     -e 0,"$x","$y","$hw","$h"
            wmctrl -r keyboard-test -e 0,"$((x + hw))","$y","$((w - hw))","$h"
            [ "$t" -eq 1 ] && sleep 2
        done
        return 0
    done
}
tile

exit 0
