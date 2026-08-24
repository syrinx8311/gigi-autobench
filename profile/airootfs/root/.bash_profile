# BurnBench: the autologin on tty1 lands here - go straight into Hyprland.
if [[ -z "$WAYLAND_DISPLAY" && -z "$HYPRLAND_INSTANCE_SIGNATURE" ]]; then
    exec Hyprland >/root/.hyprland-session.log 2>&1
fi
