# BurnBench: the autologin on tty1 lands here - go straight into XFCE.
if [[ -z "$DISPLAY" ]]; then
    exec startxfce4 >/root/.xsession.log 2>&1
fi
