#!/bin/bash
# AutoBench asset tag management tool.
# Interactive menu for viewing and blanking SMBIOS asset tags.
#   Dell  -> libsmbios (smbios-sys-info)
#   HP    -> /sys/class/firmware-attributes/hp-bioscfg (kernel >= 6.6) or fwupdmgr
#   Lenovo (AMI)  -> offer reboot into FreeDOS (AMIDEDOS) / UEFI shell (amideefix64)
#   Lenovo (Insyde) -> inform-only (BIOS setup or WinPE with WinAIA)
set -o pipefail
umask 022

SHARE_DIR="/usr/local/share/autobench"
CONF_FILE="$SHARE_DIR/autobench.conf"
LOG_DIR="/var/log/autobench"
LOGFILE="$LOG_DIR/asset-tag.log"

[ -r "$CONF_FILE" ] && . "$CONF_FILE"

mkdir -p "$LOG_DIR"

log() {
    printf '%s [ASSET] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE"
}

clr_line() {
    printf '\r%*s\r' "$((${COLUMNS:-80}-1))" ''
}

pause() {
    echo
    read -n 1 -s -r -p "Press any key to continue..."
    echo
}

# ------------------------------------------------------------ detection ---
MANUFACTURER="$(dmidecode -s system-manufacturer 2>/dev/null)"
PRODUCT="$(dmidecode -s system-product-name 2>/dev/null)"
read_tag() {
    local t
    t="$(dmidecode -s chassis-asset-tag 2>/dev/null)"
    [ -n "$t" ] || t="$(dmidecode -s baseboard-asset-tag 2>/dev/null)"
    printf '%s' "$t"
}
CURRENT_TAG="$(read_tag)"
[ -n "$CURRENT_TAG" ] || CURRENT_TAG="(none)"

# normalize vendor for case-insensitive matching
VENDOR="$(printf '%s' "$MANUFACTURER" | tr '[:upper:]' '[:lower:]')"
detect_vendor() {
    case "$VENDOR" in
        *dell*)          echo "dell" ;;
        *hewlett-packard*|*hp*|*hpe*) echo "hp" ;;
        *lenovo*|*ibm*)  echo "lenovo" ;;
        *)               echo "other" ;;
    esac
}
VEN="$(detect_vendor)"

# Detect Lenovo firmware core (AMI vs Insyde) — AMIDEDOS/amideefix only work on AMI.
BIOS_VENDOR="$(dmidecode -t bios 2>/dev/null | awk -F': ' '/^[[:space:]]*Vendor:/{print $2; exit}')"
lcase_biov="$(printf '%s' "$BIOS_VENDOR" | tr '[:upper:]' '[:lower:]')"
FIRMWARE=""
case "$lcase_biov" in
    *ami*|*american*)  FIRMWARE="ami" ;;
    *insyde*)          FIRMWARE="insyde" ;;
    *)                 FIRMWARE="unknown" ;;
esac

# ------------------------------------------------------------ HP helpers ---
HP_BASE="/sys/class/firmware-attributes/hp-bioscfg/attributes/Asset Tracking Number"
hp_supported() { [ -e "$HP_BASE/current_value" ] || command -v fwupdmgr >/dev/null 2>&1; }
hp_read() {
    if [ -e "$HP_BASE/current_value" ]; then
        cat "$HP_BASE/current_value" 2>/dev/null
    elif command -v fwupdmgr >/dev/null 2>&1; then
        fwupdmgr get-bios-setting "Asset Tracking Number" 2>/dev/null | tr -d '\n'
    fi
}
hp_write() {   # hp_write <value>
    if [ -e "$HP_BASE/current_value" ]; then
        printf '%s' "$1" | tee "$HP_BASE/current_value" >/dev/null 2>&1
    elif command -v fwupdmgr >/dev/null 2>&1; then
        fwupdmgr set-bios-setting "Asset Tracking Number" "$1" >/dev/null 2>&1
    else
        return 1
    fi
}

# ------------------------------------------------------------ write ops ---
write_asset() {   # write_asset <newval>  -> 0 ok, 1 fail, 2 unsupported
    local new="$1"
    log "attempting to set asset tag -> '${new}' on $MANUFACTURER $PRODUCT"
    case "$VEN" in
        dell)
            if command -v smbios-sys-info >/dev/null 2>&1; then
                smbios-sys-info --asset-tag --set "$new" >/dev/null 2>&1
                return $?
            fi
            log "ERROR: smbios-sys-info (libsmbios) not installed"
            return 1
            ;;
        hp)
            hp_write "$new"; return $?
            ;;
        lenovo)
            return 2
            ;;
        *)
            return 2
            ;;
    esac
}

# ------------------------------------------------------------ Lenovo ---
lenovo_hint() {
    echo
    echo "  Lenovo stores the asset tag in a proprietary SMBIOS area."
    case "$FIRMWARE" in
        ami)
            echo "  This machine uses AMI firmware, so these paths work:"
            echo
            echo "  o BIOS mode: reboot and pick 'FreeDOS (AMI DMI tools)' from the"
            echo "    boot menu, then run in DOS:"
            echo "      AMIDEDOS /CA \"\"        (chassis asset tag)"
            echo "      AMIDEDOS /BT \"\"        (baseboard asset tag)"
            echo
            echo "  o UEFI mode: reboot and pick 'UEFI Shell (AMI DMI tools)', then:"
            echo "      fs0:"
            echo "      amideefix64.efi /CA \"\""
            echo "      amideefix64.efi /BT \"\""
            echo
            if [ "${FREEDOS_BOOT_ENTRY:-1}" = "1" ]; then
                read -r -p "  Reboot into the DOS/UEFI tool now? [y/N] " r
                case "$r" in
                    y|Y) log "user requested reboot into DOS/UEFI tool"; reboot ;;
                esac
            fi
            ;;
        insyde)
            echo "  This ThinkPad uses Insyde firmware - no Linux/DOS write path."
            echo "  Clear it from BIOS setup (F1 at boot, under Asset Tag) or"
            echo "  boot WinPE with:  WinAIA64.exe -silent -set \"USERASSETDATA.ASSET_NUMBER=\""
            ;;
        *)
            echo "  Firmware core is unknown; Linux cannot write it here."
            echo "  Try BIOS setup (F1) or Lenovo WinAIA from WinPE."
            ;;
    esac
}

# ------------------------------------------------------------ the menu ---
while :; do
    clr_line
    echo "==============================================================="
    echo " AutoBench Asset Tag Tool"
    echo "==============================================================="
    echo " Vendor:    $MANUFACTURER"
    echo " Product:   $PRODUCT"
    echo " Firmware:  ${BIOS_VENDOR:-unknown}"
    echo " Current:   \"$CURRENT_TAG\""
    echo "---------------------------------------------------------------"
    echo "  [1] View current asset tag"
    echo "  [2] Blank asset tag (set to empty)"
    echo "  [3] Set new asset tag"
    case "$VEN" in
        lenovo) echo "  [4] Lenovo: show how to blank it (DOS / UEFI / BIOS)" ;;
        *)
            if [ "$VEN" = "other" ]; then
                echo "  [4] Show supported-vendor info"
            else
                echo "  [4] (vendor supported natively via Linux)"
            fi
            ;;
    esac
    echo "  [0] Exit"
    echo "==============================================================="
    read -r -p "  Choose: " choice
    echo

    case "$choice" in
        1)
            CURRENT_TAG="$(read_tag)"
            [ -n "$CURRENT_TAG" ] || CURRENT_TAG="(none)"
            echo "  Current asset tag: \"$CURRENT_TAG\""
            pause
            ;;
        2)
            echo "  This will CLEAR the asset tag on this machine."
            read -r -p "  Continue? [y/N] " c
            case "$c" in
                y|Y) ;;
                *) echo "  cancelled"; pause; continue ;;
            esac
            write_asset ""
            rc=$?
            log "blank result rc=$rc"
            [ "$rc" = "2" ] && { echo "  Not writable from Linux on this machine."; [ "$VEN" = "lenovo" ] && lenovo_hint; pause; continue; }
            if [ "$rc" = "0" ]; then
                CURRENT_TAG="$(read_tag)"
                [ -n "$CURRENT_TAG" ] || CURRENT_TAG="(none)"
                echo "  Done. New tag: \"$CURRENT_TAG\"  (a reboot may be required)"
            else
                echo "  Action FAILED (rc=$rc). See $LOGFILE"
            fi
            pause
            ;;
        3)
            echo "  Enter the new asset tag value (max ~10-80 chars, no spaces):"
            read -r newval
            [ -z "$newval" ] && { echo "  empty - use 'Blank' instead"; pause; continue; }
            read -r -p "  Set asset tag to \"$newval\"? [y/N] " c
            case "$c" in
                y|Y) ;;
                *) echo "  cancelled"; pause; continue ;;
            esac
            write_asset "$newval"
            rc=$?
            log "set result rc=$rc"
            [ "$rc" = "2" ] && { echo "  Not writable from Linux on this machine."; [ "$VEN" = "lenovo" ] && lenovo_hint; pause; continue; }
            if [ "$rc" = "0" ]; then
                CURRENT_TAG="$(read_tag)"
                [ -n "$CURRENT_TAG" ] || CURRENT_TAG="(none)"
                echo "  Done. New tag: \"$CURRENT_TAG\"  (a reboot may be required)"
            else
                echo "  Action FAILED (rc=$rc). See $LOGFILE"
            fi
            pause
            ;;
        4)
            case "$VEN" in
                lenovo) lenovo_hint ;;
                other)
                    echo "  Asset tags are writable from Linux on Dell and HP systems."
                    echo "  This vendor is not natively supported; use its own tooling."
                    ;;
                *) echo "  This vendor is handled natively by this tool." ;;
            esac
            pause
            ;;
        0) echo "  Goodbye."; break ;;
        *) echo "  Invalid choice"; pause ;;
    esac
done

exit 0
