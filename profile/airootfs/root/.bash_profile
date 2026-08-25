# BurnBench: the autologin on tty1 lands here - go straight into KDE Plasma.
if [[ -z "$DISPLAY" ]]; then
    exec startplasma-x11 >/root/.plasma-session.log 2>&1
fi
