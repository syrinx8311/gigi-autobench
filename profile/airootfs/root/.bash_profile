# BurnBench: the autologin on tty1 lands here - start X ourselves (Plasma 6
# no longer spawns X from startplasma-x11) and go straight into KDE Plasma.
if [[ -z "$DISPLAY" ]]; then
    # agetty -a skips login(1)/PAM, so nothing starts user@0.service and the
    # whole PipeWire stack (user units) would never come up -> start it here
    # and point the Plasma session at the user bus.
    systemctl start user@0.service >/dev/null 2>&1 &
    export XDG_RUNTIME_DIR=/run/user/0
    mkdir -m 700 -p "$XDG_RUNTIME_DIR"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    waited=0
    while ! systemctl is-active --quiet user@0.service && [ "$waited" -lt 15 ]; do
        sleep 1; waited=$((waited + 1))
    done
    xinit /usr/bin/startplasma-x11 -- /usr/bin/Xorg -nolisten tcp vt1 \
        >/root/.plasma-session.log 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] || ! pgrep -x Xorg >/dev/null 2>&1; then
        {
        echo ""
        echo "=================================================================="
        echo " Plasma failed to start (xinit rc=$rc)"
        echo "=================================================================="
        echo "----- /root/.plasma-session.log -----"
        cat /root/.plasma-session.log 2>/dev/null
        echo "----- Xorg log -----"
        tail -n 60 /var/log/Xorg.1.log 2>/dev/null || tail -n 60 /root/.local/share/xorg/Xorg.0.log 2>/dev/null
        echo "=================================================================="
        } | tee /dev/ttyS0 2>/dev/null
        echo " You are at a root shell. Logs: /root/.plasma-session.log"
    fi
    exec bash
fi
