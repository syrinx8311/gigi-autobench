#!/bin/bash
# BurnBench desktop launcher: burn-in terminal (left) + keyboard input
# tester (right), tiled side by side via wmctrl.
set -u

pgrep -f '/usr/local/bin/burn-in.sh' >/dev/null && {
    kdialog --sorry "Burn-in is already running." 2>/dev/null || true
    exit 0
}

# right half: xev keyboard input tester (shows every keypress with keycode/sym)
setsid nohup xev </dev/null >/dev/null 2>&1 &

# left half: the burn-in terminal itself
konsole --title BurnBench -e /bin/bash -c \
    '/usr/local/bin/burn-in.sh; echo; read -n 1 -s -r -p "Finished. Press any key to close this window..."' &

tile() {
    command -v wmctrl >/dev/null 2>&1 || return 0
    local tries=0 wa rest geo x y w h hw
    while [ "$tries" -lt 30 ]; do
        sleep 1; tries=$((tries + 1))
        wmctrl -lx 2>/dev/null | grep -qi konsole || continue
        wmctrl -lx 2>/dev/null | grep -qi xev      || continue
        # parse work area from wmctrl -d current desktop line: "... WA: x,y WxH"
        wa="$(wmctrl -d 2>/dev/null | awk '/[*]/' | sed 's/.*WA: //')"
        rest="${wa#*,}"
        x="${wa%%,*}"; y="${rest%% *}"; geo="${rest##* }"
        w="${geo%%x*}"; h="${geo##*x}"
        [ -z "$w" ] || [ -z "$h" ] && continue
        hw=$((w / 2))
        for t in 1 2; do
            wmctrl -r BurnBench     -b remove,fullscreen -b remove,maximized_vert -b remove,maximized_horz
            wmctrl -r "Event Tester" -b remove,fullscreen -b remove,maximized_vert -b remove,maximized_horz
            wmctrl -r BurnBench     -e 0,"$x","$y","$hw","$h"
            wmctrl -r "Event Tester" -e 0,"$((x + hw))","$y","$((w - hw))","$h"
            [ "$t" -eq 1 ] && sleep 2
        done
        return 0
    done
}
tile

exit 0
