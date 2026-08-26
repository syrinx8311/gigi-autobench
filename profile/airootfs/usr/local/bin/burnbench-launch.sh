#!/bin/bash
# BurnBench desktop launcher: maximized burn-in terminal, auto-sized to display.
set -u

pgrep -f '/usr/local/bin/burn-in.sh' >/dev/null && {
    kdialog --sorry "Burn-in is already running." 2>/dev/null || true
    exit 0
}

# auto-detect display resolution and size the window to ~90% of screen
GEO=""
res=$(xrandr --query 2>/dev/null | awk '/\*/{print $1; exit}')
if [ -n "$res" ]; then
    pw=${res%%x*}; ph=${res%%.*}
    # Hack 12pt: ~7.2px per char, ~15px per row
    cols=$(( pw * 90 / 100 / 7 ))
    rows=$(( ph * 90 / 100 / 15 ))
    [ "$cols" -gt 20 ] && [ "$rows" -gt 10 ] && GEO="--geometry ${cols}x${rows}"
fi

exec konsole --title BurnBench ${GEO:---geometry 160x50} -e /bin/bash -c \
    '/usr/local/bin/burn-in.sh; echo; read -n 1 -s -r -p "Finished. Press any key to close this window..."'
