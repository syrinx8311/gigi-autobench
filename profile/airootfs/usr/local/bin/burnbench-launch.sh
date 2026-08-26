#!/bin/bash
# BurnBench desktop launcher: maximized burn-in terminal.
set -u

pgrep -f '/usr/local/bin/burn-in.sh' >/dev/null && {
    kdialog --sorry "Burn-in is already running." 2>/dev/null || true
    exit 0
}

exec kstart --maximize konsole --title BurnBench -e /bin/bash -c \
    '/usr/local/bin/burn-in.sh; echo; read -n 1 -s -r -p "Finished. Press any key to close this window..."'
