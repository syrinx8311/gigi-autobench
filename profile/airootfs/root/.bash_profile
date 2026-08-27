# AutoBench: the autologin on tty1 lands here - start X ourselves (Plasma 6
# no longer spawns X from startplasma-x11) and go straight into KDE Plasma.
if [[ -z "$DISPLAY" ]]; then
    say() { echo "autobench-boot: $*" | tee /dev/ttyS0 2>/dev/null; }

    # agetty -a skips login(1)/PAM, so nothing starts user@0.service; without
    # it the whole PipeWire stack (user units) never comes up.
    export XDG_RUNTIME_DIR=/run/user/0
    mkdir -m 700 -p "$XDG_RUNTIME_DIR"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    systemctl start user@0.service >/dev/null 2>&1 &

    waited=0
    while ! systemctl is-active --quiet user@0.service && [ "$waited" -lt 15 ]; do
        sleep 1; waited=$((waited + 1))
    done

    # Gate Plasma on a WORKING sound server: plasma-pa does not reconnect on
    # its own, so starting X before audio is up means a stuck red tray icon.
    waited=0
    while ! pactl info >/dev/null 2>&1 && [ "$waited" -lt 20 ]; do
        [ "$waited" -eq 5 ] && systemctl --user enable --now \
            pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1
        sleep 1; waited=$((waited + 1))
    done
    if pactl info >/dev/null 2>&1; then
        say "audio confirmed up before X (${waited}s)"
    else
        say "WARNING: audio still down after ${waited}s - starting X anyway (session-prep will retry)"
    fi

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
