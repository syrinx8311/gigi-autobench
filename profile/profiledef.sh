#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="burnbench"
iso_label="BURNBENCH_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m%d)"
iso_publisher="BurnBench <https://example.invalid>"
iso_application="BurnBench Live / Hardware Burn-in and Benchmark"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="burnbench"
buildmodes=('iso')
bootmodes=('bios.syslinux'
           'uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/etc/NetworkManager/system-connections"]="0:0:700"
  ["/etc/NetworkManager/system-connections/burnbench-wifi.nmconnection"]="0:0:600"
  ["/usr/local/bin/burn-in.sh"]="0:0:755"
  ["/usr/local/bin/burnbench-session-prep.sh"]="0:0:755"
)
