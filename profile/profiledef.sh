#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="autobench"
iso_label="AUTOBENCH_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m%d)"
iso_publisher="AutoBench <https://example.invalid>"
iso_application="AutoBench Live / Hardware Burn-in and Benchmark"
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
  ["/etc/NetworkManager/system-connections/autobench-wifi.nmconnection"]="0:0:600"
  ["/usr/local/bin/autobench.sh"]="0:0:755"
  ["/usr/local/bin/autobench-session-prep.sh"]="0:0:755"
  ["/usr/local/bin/autobench-launch.sh"]="0:0:755"
  ["/usr/local/bin/asset-tag.sh"]="0:0:755"
  ["/usr/local/bin/asset-tag-launch.sh"]="0:0:755"
  ["/root/Desktop/AutoBench.desktop"]="0:0:755"
  ["/root/Desktop/AssetTag.desktop"]="0:0:755"
  ["/root/Desktop/KeyboardTest.desktop"]="0:0:755"
)
