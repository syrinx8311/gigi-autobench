#!/usr/bin/env bash
#
# AutoBench ISO build script.
#
#   ./build.sh              build AUR packages (if needed) + the ISO
#   ./build.sh aur          only build gst/systester into out/repo
#   ./build.sh iso          only run mkarchiso (expects out/repo populated)
#   ./build.sh clean        remove work/ and out/
#   ./build.sh --host ...   force running on the host (skip docker wrapper)
#
# On any Linux box with docker, just run ./build.sh - it re-executes itself
# inside a privileged archlinux container, so the host needs nothing installed.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

OUT="$PROJECT_DIR/out"
WORK="$PROJECT_DIR/work"
REPO="$OUT/repo"
STAGING="$WORK/profile"
IMAGE="${BURNBENCH_IMAGE:-archlinux:latest}"

WIFI_CONF="$PROJECT_DIR/config/wifi.conf"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m==> ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage_help() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

# ------------------------------------------------------------- docker wrap --
# Parses --host out of "$@" into ARGS array; sets HOST_MODE=1 if present.
parse_args() {
    HOST_MODE=0
    ARGS=()
    local a
    for a in "$@"; do
        if [ "$a" = "--host" ]; then
            HOST_MODE=1
        else
            ARGS+=("$a")
        fi
    done
}

maybe_docker() {
    if [ "$HOST_MODE" = "1" ]; then
        return
    fi
    if command -v docker >/dev/null 2>&1 && ! command -v mkarchiso >/dev/null 2>&1; then
        log "no mkarchiso on host - building inside docker ($IMAGE)"
        HOST_UID="$(id -u)" HOST_GID="$(id -g)"
        export HOST_UID HOST_GID
        docker run --rm --privileged \
            -v "$PROJECT_DIR":/project -w /project \
            -e BURNBENCH_IMAGE="$IMAGE" \
            -e HOST_UID -e HOST_GID \
            "$IMAGE" \
            bash -c '
                set -e
                pacman-key --init >/dev/null 2>&1 || true
                pacman -Sy --needed --noconfirm archlinux-keyring >/dev/null
                pacman -S --needed --noconfirm archiso base-devel sudo git rsync mtools unzip xorriso >/dev/null
                rc=0
                /project/build.sh --host "$@" || rc=$?
                # give build outputs back to the invoking user
                [ "${HOST_UID:-0}" != "0" ] && \
                    chown -R "$HOST_UID":"$HOST_GID" /project/out /project/work /project/aur 2>/dev/null || true
                exit $rc
            ' build "${ARGS[@]}"
        rc=$?
        exit $rc
    fi
}

# ------------------------------------------------------------ local repo ----
build_aur() {
    log "building AUR packages into $REPO"
    mkdir -p "$REPO"

    # install everything the vendored PKGBUILDs need
    BUILD_DEPS=(gmp pkg-config meson ninja appstream-glib gobject-introspection
        python python-build python-installer python-wheel python-humanfriendly
        python-peewee python-psutil python-gobject python-pyxdg python-yaml
        python-requests python-reactivex lm_sensors stress-ng dmidecode)
    PACMAN=(pacman -Sy --needed --noconfirm)
    [ "$(id -u)" != "0" ] && PACMAN=(sudo "${PACMAN[@]}")
    log "installing build dependencies"
    "${PACMAN[@]}" "${BUILD_DEPS[@]}" >/dev/null

    # makepkg refuses to run as root; use a builder account when in a container
    MAKEPKG=(makepkg -f --noconfirm -C)
    if [ "$(id -u)" = "0" ]; then
        if ! id builder >/dev/null 2>&1; then
            useradd -m builder
            printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
        fi
        chown -R builder:builder aur "$REPO"
        MAKEPKG=(sudo -u builder makepkg -f --noconfirm -C)
    fi

    # Build in multiple passes: a package may only become buildable after a
    # sibling package from this repo has been installed (e.g. gst depends on
    # our vendored python-injector).
    local pass dirs pkg
    for pass in 1 2 3 4 5; do
        dirs=()
        for pkgdir in aur/*/; do
            pkg="$(basename "$pkgdir")"
            if ls "$REPO/$pkg-"*.pkg.tar.zst >/dev/null 2>&1; then
                continue    # already built
            fi
            log "building $pkg (pass $pass)"
            if ! ( cd "$pkgdir" && rm -f ./*.pkg.tar.zst && "${MAKEPKG[@]}" ); then
                dirs+=("$pkgdir")
                continue   # retry next pass, deps may appear later
            fi
            cp "$pkgdir"/*.pkg.tar.zst "$REPO"/
            # install into this environment so later packages can depend on it
            pacman -U --needed --noconfirm "$REPO/$pkg-"*.pkg.tar.zst >/dev/null 2>&1 \
                || sudo pacman -U --needed --noconfirm "$REPO/$pkg-"*.pkg.tar.zst >/dev/null
        done
        [ ${#dirs[@]} -eq 0 ] && break
        [ "$pass" -eq 5 ] && die "packages failed to build: ${dirs[*]}"
        log "retrying failed packages: ${dirs[*]}"
    done

    # rebuild the database from scratch so removed versions disappear
    rm -f "$REPO"/autobench.db* "$REPO"/autobench.files*
    repo-add "$REPO/autobench.db.tar.gz" "$REPO"/*.pkg.tar.zst >/dev/null
    log "local repository ready: $(ls "$REPO" | tr '\n' ' ')"
}

# ---------------------------------------------------- DOS tools (FreeDOS) --
# Builds the FreeDOS floppy image (with AMIDEDOS) and the UEFI AMI DMI tool
# (amideefix64.efi) that the boot menus chainload for AMI-firmware Lenovo
# machines. Everything is fetched into a gitignored cache under work/ so no
# proprietary binaries are committed.
DOSTOOLS="$WORK/dostools"
FREEDOS_URL="https://download.freedos.org/1.4/FD14-FloppyEdition.zip"
AMIDEDOS_URL="https://support.nextcomputing.com/hc/en-us/attachments/200581211/AMIDEDOS.zip"   # pkg source; OEM redist
LENOVO_DMI_URL="https://download.lenovo.com/pccbbs/thinkcentre_bios/m1ujt77usa.zip"
LENOVO_AMIDEDOS_URL="https://download.lenovo.com/pccbbs/thinkcentre_bios/90jt18usa.zip"   # contains AMIDEDOS.exe

fetch() {   # fetch <url> <outfile>
    local url="$1" out="$2"
    if [ ! -s "$out" ]; then
        log "downloading $(basename "$out")"
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 3 -o "$out.part" "$url" || die "download failed: $url"
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$out.part" "$url" || die "download failed: $url"
        else
            die "need curl or wget to fetch DOS tools"
        fi
        mv "$out.part" "$out"
    fi
}

need_unzip() {
    command -v unzip >/dev/null 2>&1 || die "unzip required for DOS tools (pacman -S unzip)"
}

build_freedos_img() {   # -> $OUT/freedos.img
    local x86boot freedos_img
    mkdir -p "$DOSTOOLS/floppy"
    freedos_img="$OUT/freedos.img"

    if [ ! -s "$freedos_img" ]; then
        need_unzip
        [ -d "$DOSTOOLS/fd14" ] || {
            fetch "$FREEDOS_URL" "$DOSTOOLS/FD14-FloppyEdition.zip"
            ( cd "$DOSTOOLS" && unzip -o -q FD14-FloppyEdition.zip -d fd14 )
        }
        # pick the 1.44MB boot image
        x86boot="$(find "$DOSTOOLS/fd14" -iname 'x86BOOT*IMG' | head -1)"
        [ -n "$x86boot" ] || die "FreeDOS boot image not found in archive"

        # AMIDEDOS.EXE is proprietary; try several known public sources,
        # then fall back to Lenovo's official DMI zip (contains AMIDEDOS.exe).
        if [ ! -s "$DOSTOOLS/AMIDEDOS.EXE" ]; then
            if command -v curl >/dev/null 2>&1; then
                for u in "$AMIDEDOS_URL" \
                    "https://github.com/Haiballad/amidewinx64/releases/download/1.31/AMIDEDOS.EXE"; do
                    curl -fsSL --retry 2 -o "$DOSTOOLS/AMIDEDOS.EXE.part" "$u" \
                        && mv "$DOSTOOLS/AMIDEDOS.EXE.part" "$DOSTOOLS/AMIDEDOS.EXE" && break
                done
            fi
        fi
        if [ ! -s "$DOSTOOLS/AMIDEDOS.EXE" ]; then
            need_unzip
            log "AMIDEDOS direct sources failed - fetching Lenovo DMI zip"
            fetch "$LENOVO_AMIDEDOS_URL" "$DOSTOOLS/lenovo-amidedos.zip"
            ( cd "$DOSTOOLS" && unzip -o -q lenovo-amidedos.zip -d lenovo-amidedos )
            local exe
            exe="$(find "$DOSTOOLS/lenovo-amidedos" -iname 'amidedos.exe' | head -1)"
            [ -n "$exe" ] && cp "$exe" "$DOSTOOLS/AMIDEDOS.EXE"
        fi
        [ -s "$DOSTOOLS/AMIDEDOS.EXE" ] || die "could not fetch AMIDEDOS.EXE - place it at $DOSTOOLS/AMIDEDOS.EXE manually"

        log "building FreeDOS floppy with AMIDEDOS"
        cp "$x86boot" "$OUT/freedos.img"
        # Write an interactive AUTOEXEC.BAT menu into the FAT12 volume.
        {
            printf '@echo off\r\n'
            printf 'echo AutoBench - AMI DMI tools\r\n'
            printf 'echo ==================================\r\n'
            printf 'echo  AMIDEDOS /CA ""   clear chassis asset tag\r\n'
            printf 'echo  AMIDEDOS /BT ""   clear baseboard asset tag\r\n'
            printf 'echo  AMIDEDOS /?       full help / key list\r\n'
            printf 'echo ==================================\r\n'
            printf 'prompt DOS:\\$G\r\n'
        } > "$DOSTOOLS/AUTOEXEC.BAT"
        if command -v mcopy >/dev/null 2>&1; then
            mcopy -i "$OUT/freedos.img" "$DOSTOOLS/AMIDEDOS.EXE" ::/AMIDEDOS.EXE 2>/dev/null \
                || die "mtools failed to inject AMIDEDOS.EXE into floppy (install mtools)"
            mcopy -i "$OUT/freedos.img" "$DOSTOOLS/AUTOEXEC.BAT" ::/AUTOEXEC.BAT 2>/dev/null \
                || log "WARNING: could not inject AUTOEXEC.BAT (floppy still boots, no menu)"
        else
            log "WARNING: mtools not installed - AMIDEDOS not bundled into floppy (install mtools)"
        fi
        log "FreeDOS image ready: $(du -h "$OUT/freedos.img" | cut -f1)"
    fi
}

build_uefi_dmi() {   # -> $OUT/amideefix64.efi
    if [ ! -s "$OUT/amideefix64.efi" ]; then
        need_unzip
        [ -d "$DOSTOOLS/lenovo-dmi" ] || {
            fetch "$LENOVO_DMI_URL" "$DOSTOOLS/m1ujt77usa.zip"
            ( cd "$DOSTOOLS" && unzip -o -q m1ujt77usa.zip -d lenovo-dmi )
        }
        local efi
        efi="$(find "$DOSTOOLS/lenovo-dmi" -iname 'amideefix64.efi' | head -1)"
        [ -n "$efi" ] || die "amideefix64.efi not found in Lenovo package (m1ujt77usa.zip)"
        cp "$efi" "$OUT/amideefix64.efi"
        log "UEFI DMI tool ready: amideefix64.efi"
    fi
}

need_xorriso() {
    command -v xorriso >/dev/null 2>&1 || die "xorriso required (pacman -S xorriso)"
    command -v mcopy >/dev/null 2>&1 || die "mtools required (pacman -S mtools)"
}

build_dostools() {   # prepare FreeDOS floppy + UEFI AMI tool into $OUT
    mkdir -p "$DOSTOOLS" "$OUT"
    build_freedos_img
    build_uefi_dmi
}

# Post-build injection of the DOS/UEFI-bootable tool files.
# mkarchiso has no hook to place arbitrary files into the ISO's root /boot
# (for pre-boot syslinux MEMDISK) or onto the EFI system partition (which the
# interactive UEFI shell needs to reach amideefix64.efi). mkarchiso builds the
# ESP FAT with 8 MiB of slack explicitly "to allow adding custom files when
# repacking the ISO", so we repack with xorriso:
#   - freedos.img          -> iso9660 /boot/          (syslinux + grub MEMDISK)
#   - amideefix64.efi, startup.nsh -> ESP root        (UEFI shell, interactively)
inject_boot_files() {   # <iso>
    local iso="$1" work extract_dir esp freedos amideefix startup
    need_xorriso
    [ -s "$OUT/freedos.img" ]     || die "freedos.img missing - run './build.sh iso' after fetch"
    [ -s "$OUT/amideefix64.efi" ] || die "amideefix64.efi missing - run './build.sh iso' after fetch"
    [ -s "$iso" ] || die "ISO not found: $iso"

    work="$WORK/dostools-repack"
    extract_dir="$work/bootimg"
    freedos="$OUT/freedos.img"
    amideefix="$OUT/amideefix64.efi"
    startup="$STAGING/efiboot/startup.nsh"
    [ -s "$startup" ] || die "startup.nsh missing in profile/efiboot"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    {
        cd "$work"
        log "injecting boot files into $iso"
        # Extract the El Torito EFI boot image (the ESP partition) as a plain
        # file. Naming depends on catalog order (BIOS image often shadows it),
        # so match by suffix and fall back to the appended-partition views.
        xorriso -indev "$iso" -osirrox on -extract_boot_images "$extract_dir" >/dev/null \
            || die "could not extract EFI boot image from $iso"
        esp="$(compgen -G "$extract_dir/eltorito_img*_uefi.img" | head -1)"
        [ -n "$esp" ] || esp="$(compgen -G "$extract_dir/mbr_part2_efi.img" | head -1)"
        [ -n "$esp" ] || esp="$(compgen -G "$extract_dir/gpt_part*_efi.img" | head -1)"
        [ -s "$esp" ] || die "EFI boot image not found in $iso"
        file -b "$esp" | grep -qi 'dos/mbr' || die "extracted ESP '$esp' is not a FAT image"

        # Put the AMI tool + interactive shell help on the ESP root, same
        # location the UEFI shell starts in when systemd-boot chainloads
        # /shellx64.efi.
        mcopy -i "$esp" "$amideefix" ::/amideefix64.efi || die "mcopy amideefix64.efi into ESP failed"
        mcopy -i "$esp" "$startup"   ::/startup.nsh     || die "mcopy startup.nsh into ESP failed"

        # Repack the ISO: splice freedos.img into iso9660 /boot and re-embed
        # the modified ESP. -boot_image any replay preserves the El
        # Torito/isohybrid setup mkarchiso created for BIOS+UEFI boot entries.
        cp "$iso" "$iso.inj.tmp"
        if ! xorriso -dev "$iso.inj.tmp" -boot_image any replay \
                -map "$freedos" /boot/freedos.img \
                -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$esp" \
                -commit >/dev/null; then
            rm -f "$iso.inj.tmp"
            die "xorriso repack failed for $iso"
        fi
        mv -f "$iso.inj.tmp" "$iso"
    }
    rm -rf "$extract_dir"
    log "injected /boot/freedos.img and amideefix64.efi/startup.nsh (ESP) into $iso"
}

# ------------------------------------------------------------ wifi render ---
render_wifi() {
    local target="$1/airootfs/etc/NetworkManager/system-connections/autobench-wifi.nmconnection"
    local ssid psk sec_block

    SSID="" PSK=""
    if [ -r "$WIFI_CONF" ]; then
        # shellcheck source=config/wifi.conf.example disable=SC1091
        . "$WIFI_CONF"
    fi
    : "${SSID:?config/wifi.conf must define SSID (copy config/wifi.conf.example)}"

    ssid="$SSID" psk="${PSK:-}"
    esc() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

    if [ -n "$psk" ]; then
        sec_block=$'\n[wifi-security]\nkey-mgmt=wpa-psk\npsk='"$(esc "$psk")"$'\n'
    else
        sec_block=$'\n[wifi-security]\nkey-mgmt=none\n'
    fi

    cat > "$target" <<EOF
[connection]
id=autobench-wifi
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$(esc "$ssid")
$sec_block
[ipv4]
method=auto

[ipv6]
method=auto
EOF
    chmod 600 "$target"
    log "wifi profile rendered for SSID '$ssid'"
}

# ------------------------------------------------------------------- iso ----
build_iso() {
    [ -d "$REPO" ] || die "out/repo missing - run './build.sh aur' first"
    ls "$REPO"/autobench.db.tar.gz >/dev/null 2>&1 || die "repo db missing - run './build.sh aur' first"

    log "staging profile into $STAGING"
    rm -rf "$STAGING"
    mkdir -p "$WORK"
    cp -a "$PROJECT_DIR/profile" "$STAGING"
    chmod +x "$STAGING"/airootfs/usr/local/bin/*.sh \
             "$STAGING"/root/Desktop/AutoBench.desktop \
             "$STAGING"/root/Desktop/AssetTag.desktop 2>/dev/null || true

    sed -i "s|__BURN_REPO__|$(sed 's/[\/&]/\\&/g' <<<"$REPO")|" "$STAGING/pacman.conf"
    grep -q '__BURN_REPO__' "$STAGING/pacman.conf" && die "failed to render pacman.conf"
    render_wifi "$STAGING"
    grep -rq '__WIFI_' "$STAGING/airootfs/etc/NetworkManager/system-connections/" \
        && die "wifi template not rendered"
    build_dostools

    log "running mkarchiso (this downloads ~1GB of packages on first run)"
    # Start from a clean slate every build: mkarchiso caches steps via
    # _run_once markers AND overlays profile/airootfs onto a persistent
    # chroot - without this, removed packages/files linger in the ISO.
    rm -rf "$WORK/build"
    iso_before="$WORK/iso-before.txt"
    : > "$iso_before"
    for f in "$OUT"/*.iso; do
        [ -e "$f" ] && stat -c '%s %Y %n' "$f" >> "$iso_before"
    done
    mkarchiso -v -w "$WORK/build" -o "$OUT" "$STAGING"

    # Splice the FreeDOS floppy onto iso9660 /boot and amideefix64.efi /
    # startup.nsh onto the ESP (see inject_boot_files for why). Only touch
    # ISO(s) mkarchiso just produced - never older leftovers in $OUT.
    for iso in "$OUT"/*.iso; do
        [ -e "$iso" ] || continue
        fp="$(stat -c '%s %Y %n' "$iso")"
        grep -qF "$fp" "$iso_before" && continue
        inject_boot_files "$iso"
    done
    rm -f "$iso_before"

    log "done. ISO(s):"
    ls -lh "$OUT"/*.iso
}

# ------------------------------------------------------------------ main ----
parse_args "$@"
maybe_docker
MODE="${ARGS[0]:-all}"

case "$MODE" in
    aur)   build_aur ;;
    iso)   build_iso ;;
    clean) rm -rf "$WORK" "$OUT"; log "cleaned work/ and out/" ;;
    all)   build_aur; build_iso ;;
    -h|--help) usage_help ;;
    *)     die "unknown argument '$MODE' (try --help)" ;;
esac
