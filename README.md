# AutoBench

An Arch-based live ISO in the spirit of PartedMagic, focused on **automated
hardware burn-in and benchmarking** with quality-of-life improvements for
shop-floor use: boot the USB stick, double-click one desktop icon, walk away.
A tone plays and a PASS/FAIL report lands on the desktop when it's done.

## What the automated run does (double-click `AutoBench Burn-In`)

| # | Stage | Behaviour |
|---|-------|-----------|
| 0 | Hardware summary | CPU/RAM/board/BIOS logged, sensors snapshot |
| 1 | CPU governor | Sets every cpufreq policy to `performance` (WARNs where unsupported) |
| 2 | Network | If a wireless card exists: scans + logs visible networks and connects to the SSID baked into the ISO. Then pings google.com 5 times (~5s) and reports resolved IP / packet loss / avg latency as its own PASS/FAIL line |
| 3 | Camera | If a capture device exists: launches a viewer window (guvcview) so a human can eyeball it later |
| 4 | systester-cli | Pi-calculation stability test. **One full turn**, digits auto-sized to **1M per GB of RAM, rounded up** to systester's next valid tier (7100MB -> 8M, 16GB -> 16M), threads = min(cores, 64, scaled RAM budget), live elapsed-time ticker. A safety cap (`SYSTESTER_MAX_MINUTES`, default 30) cuts off pathologically slow machines |
| 5 | GTK Stress Testing | Opens the GST GUI (temps/frequency graphs) and drives the exact same stress-ng command GST's "CPU: All methods" preset would run: all cores, verified, 60 s (`GST_SECONDS`), with a countdown |

Every stage prints live progress (spinners, attempt counters, elapsed/remaining tickers) so the script never looks like it's hanging.
| 6 | Tone + report | Success clip (`success.wav`, the batman mp3 converted at build time; falls back to `success.mp3` via mpg123, then sine). A short beep also plays at run start (`START_BEEP`). Audio is aggressively prepared: PipeWire started if down, every ALSA control unmuted at 75%, `alsactl init`, analog-stereo profile + speaker port forced via pactl, and `alsa-ucm-conf` shipped for modern SOF laptops, desktop notification, `AutoBench-Report-<date>.txt` on the desktop. Three chimes = something FAILED |

Every stage result is PASS/FAIL/SKIP/WARN; exit code is non-zero on any FAIL,
and the full log lives in `/var/log/autobench/<timestamp>/`.

## Repository layout

```
build.sh              one-command build (wraps itself in docker if needed)
config/wifi.conf.example  copy to config/wifi.conf, set your shop SSID/PSK
aur/                  vendored PKGBUILDs (gst, systester cli-only build)
profile/
  profiledef.sh       archiso profile definition
  packages.x86_64     package list
  pacman.conf         official repos + local AUR repo (out/repo, db autobench.db)
  grub/, syslinux/, efiboot/   boot menus (3s timeout, Memtest86+ entries)
  airootfs/           everything that lands in the live root:
    usr/local/bin/autobench.sh the orchestrator script
    usr/local/share/autobench/      defaults conf + success.wav
    etc/lightdm/...                root autologin straight to XFCE
    etc/NetworkManager/...         pre-configured wifi connection
    root/Desktop/AutoBench.desktop THE icon
```

## Building

Requirements: any Linux host with **docker** (nothing else), or an Arch host
with the `archiso` package installed.

```sh
cp config/wifi.conf.example config/wifi.conf
$EDITOR config/wifi.conf          # set SSID / PSK
./build.sh                        # -> out/autobench-*.iso
```

Write it to a USB stick:

```sh
sudo dd if=out/autobench-*.iso of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress
```

Both BIOS (syslinux) and UEFI (systemd-boot) boot are supported. There is no login screen: tty1 auto-logs-in as root and drops straight into KDE Plasma (X11). If the session ever fails to start, check `/root/.plasma-session.log`; you'll be at a root shell.

Desktop behaviour baked in: power button = immediate shutdown, tap-to-click forced on for touchpads, volume keys handled by plasma-pa, wallpaper applied via plasmashell scripting.

## Tuning knobs

Live-tunable in `/usr/local/share/autobench/autobench.conf`
(or bake changes into that file in `profile/airootfs/` before building):

| Variable | Default | Meaning |
|----------|---------|---------|
| `SYSTESTER_TURNS` | 1 | number of full pi-computation turns systester runs |
| `SYSTESTER_MAX_MINUTES` | 30 | wall-clock safety cap for the systester stage |
| `SYSTESTER_DIGITS` | auto | digits per turn; "auto" = 1M per GB of RAM rounded UP to the next valid tier (7100MB -> 8M) |
| `SYSTESTER_PER_THREAD_MB` | 64 | RAM budget per worker used by the auto-sizer |
| `GST_SECONDS` | 60 | stress-ng/GTK phase duration |
| `SET_PERFORMANCE_GOVERNOR` | 1 | set `performance` governor first |
| `WIFI_CONNECT` / `WIFI_TIMEOUT_SECS` | 1 / 90 | wifi stage switch & deadline |
| `CAMERA_CHECK` | 1 | launch viewer when camera found |
| `PLAY_TONE` | 1 | end-of-run chime |

## Notes / gotchas

- The first double-click may still show XFCE's "untrusted launcher" prompt on
  some boots if the session-prep step didn't get there first - clicking
  "Mark as trusted" once is enough.
- WiFi creds are baked into the image (root-readable). Treat the ISO as
  sensitive or use a PSK you rotate.
- systester's thread count is additionally capped by available RAM
  (~50% headroom) so low-RAM machines don't OOM during burn-in.
- GST has no CLI auto-run flags upstream, so the script drives stress-ng with
  the identical parameters GST's UI would use while its monitoring window is
  open - fully unattended, same workload.
- Extra benchmarking tools from the PartedMagic toolbox are included for
  manual runs: hardinfo, bonnie++, memtester, hdparm, gsmartcontrol,
  gnome-disks (benchmark), stress-ng, lshw, inxi, smartmontools.
