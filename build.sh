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
IMAGE="${AUTOBENCH_IMAGE:-archlinux:latest}"

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
            -e AUTOBENCH_IMAGE="$IMAGE" \
            -e HOST_UID -e HOST_GID \
            "$IMAGE" \
            bash -c '
                set -e
                pacman-key --init >/dev/null 2>&1 || true
                pacman -Sy --needed --noconfirm archlinux-keyring >/dev/null
                pacman -S --needed --noconfirm archiso base-devel sudo git rsync >/dev/null
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
             "$STAGING"/root/Desktop/AutoBench.desktop 2>/dev/null || true

    sed -i "s|__BURN_REPO__|$(sed 's/[\/&]/\\&/g' <<<"$REPO")|" "$STAGING/pacman.conf"
    grep -q '__BURN_REPO__' "$STAGING/pacman.conf" && die "failed to render pacman.conf"
    render_wifi "$STAGING"
    grep -rq '__WIFI_' "$STAGING/airootfs/etc/NetworkManager/system-connections/" \
        && die "wifi template not rendered"

    log "running mkarchiso (this downloads ~1GB of packages on first run)"
    # Start from a clean slate every build: mkarchiso caches steps via
    # _run_once markers AND overlays profile/airootfs onto a persistent
    # chroot - without this, removed packages/files linger in the ISO.
    rm -rf "$WORK/build"
    mkarchiso -v -w "$WORK/build" -o "$OUT" "$STAGING"
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
