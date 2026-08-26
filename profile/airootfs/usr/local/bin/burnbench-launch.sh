#!/bin/bash
# BurnBench desktop launcher: single full-width burn-in terminal.
set -u

pgrep -f '/usr/local/bin/burn-in.sh' >/dev/null && {
    kdialog --sorry "Burn-in is already running." 2>/dev/null || true
    exit 0
}

exec konsole --title BurnBench --geometry 160x50 -e /bin/bash -c \
    '/usr/local/bin/burn-in.sh; echo; read -n 1 -s -r -p "Finished. Press any key to close this window..."'
