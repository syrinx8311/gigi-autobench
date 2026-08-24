#!/bin/bash
# BurnBench automated burn-in and benchmark suite.
# Designed to be launched from the "BurnBench Burn-In" desktop icon on the
# live ISO. Coworkers double-click, walk away, and hear the tone when done.
# Every stage prints live progress so it never looks like a hang.
set -o pipefail
umask 022

SHARE_DIR="/usr/local/share/burnbench"
CONF_FILE="$SHARE_DIR/burnbench.conf"
LOG_DIR="/var/log/burnbench"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$HOME/Desktop/BurnBench-Report-$STAMP.txt"

# shellcheck source=burnbench.conf
[ -r "$CONF_FILE" ] && . "$CONF_FILE"

HOSTNAME="$(cat /etc/hostname 2>/dev/null || hostname)"
mkdir -p "$LOG_DIR/$STAMP"
LOG="$LOG_DIR/$STAMP/burn-in.log"

RESULTS_ORDER=()
declare -A RESULTS
declare -A DETAILS

log() {
    printf '%s [%s] %s\n' "$(date '+%H:%M:%S')" "${2:-INFO}" "$1" | tee -a "$LOG"
}

stage() {          # stage <name> <status> <detail...>
    local name="$1" status="$2"
    shift 2
    RESULTS_ORDER+=("$name")
    RESULTS["$name"]="$status"
    DETAILS["$name"]="$*"
    log "$name: $status ($*)"
}

section() {
    { echo; echo "=== $* ==="; } | tee -a "$LOG"
}

run_logged() {     # run a command, capture stdout+stderr to the log
    "$@" >>"$LOG" 2>&1
}

# --------------------------------------------------- progress UI helpers ---
clr() {            # wipe the current line
    printf '\r%*s\r' "${CLR_COLS:-110}" ''
}

spin_start() {     # spin_start <text>   (indeterminate spinner)
    local t="$1" sp='|/-\' i=0
    while :; do
        printf '\r    [%c] %s' "${sp:i%4:1}" "$t"
        i=$((i + 1))
        sleep 0.25
    done &
    SPIN_PID=$!
}

spin_stop() {      # spin_stop
    kill "${SPIN_PID:-0}" 2>/dev/null
    wait "${SPIN_PID:-0}" 2>/dev/null
    clr
}

fmt_mmss() {       # seconds -> MM:SS
    printf '%02d:%02d' $(($1 / 60)) $(($1 % 60))
}

# ---------------------------------------------------------------- header ---
{
echo "==============================================================="
echo " BurnBench automated burn-in   $(date '+%Y-%m-%d %H:%M:%S')"
echo " Host: $HOSTNAME"
echo " You can walk away - a chime plays when everything is done."
echo "==============================================================="
} | tee "$LOG"

CPU_MODEL="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')"
NPROC="$(nproc)"
MEM_TOTAL_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
MEM_AVAIL_MB=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)

section "Hardware summary"
tee -a "$LOG" <<EOF
CPU:        $CPU_MODEL
Cores:      $NPROC logical
RAM:        ${MEM_TOTAL_MB} MB total / ${MEM_AVAIL_MB} MB available
Board:      $(dmidecode -s baseboard-manufacturer 2>/dev/null) $(dmidecode -s baseboard-product-name 2>/dev/null)
BIOS:       $(dmidecode -s bios-version 2>/dev/null) ($(dmidecode -s bios-release-date 2>/dev/null))
Kernel:     $(uname -r)  Live medium: BurnBench
EOF

# ------------------------------------------------------- performance gov ---
if [ "${SET_PERFORMANCE_GOVERNOR:-1}" = "1" ]; then
    section "Stage 1: CPU governor -> performance"
    set_gov=0; ok_gov=0; unsupported=""
    for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -e "$gov_file" ] || continue
        cpu_dir=${gov_file%/*}
        set_gov=$((set_gov + 1))
        if ! grep -qw performance "$cpu_dir/scaling_available_governors" 2>/dev/null; then
            unsupported="${unsupported}$(basename "${cpu_dir%%/cpufreq}") "
            continue
        fi
        echo performance > "$gov_file" 2>>"$LOG" && ok_gov=$((ok_gov + 1))
        printf '\r    setting policy %-12s (%d/%d)' "$(basename "${cpu_dir%%/cpufreq}")" "$ok_gov" "$set_gov"
    done
    clr
    if [ "$set_gov" -eq 0 ]; then
        stage "governor" "WARN" "no cpufreq policy exposed (some VMs/embedded); running at defaults"
    elif [ "$ok_gov" -eq "$set_gov" ]; then
        stage "governor" "PASS" "performance applied to all $ok_gov policies"
    else
        stage "governor" "WARN" "performance on $ok_gov/$set_gov (unsupported: ${unsupported:-?})"
    fi
    grep -H . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >>"$LOG" 2>&1 || true
else
    stage "governor" "SKIP" "disabled in config"
fi

# ----------------------------------------------------------------- wifi ---
if [ "${WIFI_CONNECT:-1}" = "1" ]; then
    section "Stage 2: Network (WiFi + internet check)"
    WL_IFACES=""
    for iface_path in /sys/class/net/*; do
        [ -d "$iface_path/wireless" ] && WL_IFACES="${WL_IFACES}$(basename "$iface_path") "
    done
    if [ -z "$WL_IFACES" ]; then
        stage "wifi" "SKIP" "no wireless card detected"
    else
        log "wireless interface(s): $WL_IFACES"
        run_logged rfkill unblock wifi
        run_logged nmcli radio wifi on
        BAKED_SSID=$(sed -n 's/^ssid=//p' \
            /etc/NetworkManager/system-connections/burnbench-wifi.nmconnection 2>/dev/null | head -1)

        spin_start "scanning for networks..."
        nmcli device wifi list --rescan yes >>"$LOG" 2>&1
        sleep 3
        spin_stop
        nmcli -f IN-USE,SSID,SIGNAL,SECURITY device wifi list 2>>"$LOG" \
            | sed 's/^/    scan| /' | tee -a "$LOG" >/dev/null

        MAX_ATTEMPTS=$((WIFI_TIMEOUT_SECS / 5))
        attempt=0
        until nmcli -t -f GENERAL.STATE connection show burnbench-wifi 2>/dev/null | grep -q activated; do
            attempt=$((attempt + 1))
            printf '\r    connecting to "%s"... attempt %d/%d   ' "${BAKED_SSID:-?}" "$attempt" "$MAX_ATTEMPTS"
            nmcli connection up burnbench-wifi --nowait >>"$LOG" 2>&1
            [ "$attempt" -ge "$MAX_ATTEMPTS" ] && break
            sleep 5
        done
        clr

        if nmcli -t -f GENERAL.STATE connection show burnbench-wifi 2>/dev/null | grep -q activated; then
            ACT_IFACE="$(nmcli -g GENERAL.DEVICES connection show burnbench-wifi 2>/dev/null)"
            IP_ADDR="$(ip -4 -o addr show dev "$ACT_IFACE" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
            SIGNAL="$(nmcli -t -f ACTIVE,SIGNAL dev wifi list 2>/dev/null | head -1)"
            stage "wifi" "PASS" "connected to '${BAKED_SSID:-burnbench-wifi}' via $ACT_IFACE ip=$IP_ADDR signal=${SIGNAL:-?}%"
        else
            stage "wifi" "FAIL" "could not associate with '${BAKED_SSID:-burnbench-wifi}' within ${WIFI_TIMEOUT_SECS}s (see log)"
        fi
    fi

    # ---- internet reachability: 5 pings (~5 seconds) ----
    log "pinging google.com x5 (~5s)..."
    PING_IP="$(getent ahostsv4 google.com 2>/dev/null | awk '{print $1; exit}')"
    if [ -z "$PING_IP" ]; then
        stage "ping" "FAIL" "DNS lookup for google.com failed - no usable internet route"
    else
        POUT="$(ping -c 5 -W 2 google.com 2>&1)"
        PRC=$?
        LOSS="$(grep -oE '[0-9]+(\.[0-9]+)?% packet loss' <<<"$POUT" | grep -oE '^[0-9.]*%')"
        AVG="$(awk -F'/' '/^rtt|^round-trip/{print $5}' <<<"$POUT")"
        clr
        if [ "$PRC" -eq 0 ]; then
            stage "ping" "PASS" "google.com ($PING_IP): loss=${LOSS:-0%} avg=${AVG:-?}ms"
        else
            stage "ping" "FAIL" "google.com ($PING_IP): loss=${LOSS:-100%} - offline or ICMP blocked"
        fi
    fi
else
    stage "wifi" "SKIP" "disabled in config"
    stage "ping" "SKIP" "disabled in config"
fi

# --------------------------------------------------------------- camera ---
if [ "${CAMERA_CHECK:-1}" = "1" ]; then
    section "Stage 3: Camera"
    CAM_DEVS=""
    for vd in /dev/video*; do
        [ -e "$vd" ] || continue
        if v4l2-ctl -d "$vd" --info 2>>"$LOG" | grep -q 'Video Capture'; then
            CAM_DEVS="$CAM_DEVS $vd"
        fi
    done
    if [ -z "$CAM_DEVS" ]; then
        stage "camera" "SKIP" "no video capture device detected"
    else
        log "capture device(s):$CAM_DEVS"
        run_logged v4l2-ctl --list-devices
        export DISPLAY="${DISPLAY:-:0.0}"
        CAM_PID=""
        spin_start "launching camera viewer..."
        if command -v guvcview >/dev/null 2>&1; then
            setsid nohup guvcview </dev/null >>"$LOG" 2>&1 &
            CAM_PID=$!
        elif command -v cheese >/dev/null 2>&1; then
            setsid nohup cheese </dev/null >>"$LOG" 2>&1 &
            CAM_PID=$!
        else
            spin_stop
            stage "camera" "WARN" "devices found ($CAM_DEVS) but no viewer installed in image"
        fi
        if [ -n "$CAM_PID" ]; then
            sleep 4
            spin_stop
            if kill -0 "$CAM_PID" 2>/dev/null; then
                stage "camera" "PASS" "viewer started for:$CAM_DEVS (pid $CAM_PID) - window left open on desktop"
            else
                stage "camera" "WARN" "devices found ($CAM_DEVS) but viewer exited early; see log"
            fi
        fi
    fi
else
    stage "camera" "SKIP" "disabled in config"
fi

# ------------------------------------------------------------ systester ---
section "Stage 4: systester-cli (CPU/RAM stability, $SYSTESTER_TURNS turn(s))"
command -v systester-cli >/dev/null 2>&1 || stage "systester" "FAIL" "binary missing from image"

if [ -z "${RESULTS[systester]:-}" ]; then
    # ---- digits: 1M per GB of RAM, snapped to a valid systester tier ----
    DIGITS="${SYSTESTER_DIGITS:-auto}"
    if [ "$DIGITS" = "auto" ]; then
        DIGITS="$(awk -v mb="$MEM_TOTAL_MB" 'BEGIN {
            gb = mb / 1024
            split("128K 256K 512K 1M 2M 4M 8M 16M 32M 64M 128M", name, " ")
            split("0.125 0.25 0.5 1 2 4 8 16 32 64 128",      val,  " ")
            d = "128K"
            for (i = 1; i <= 11; i++) if (gb >= val[i]) d = name[i]
            print d
        }')"
    fi
    # memory used by a worker scales with digit count: budget is
    # SYSTESTER_PER_THREAD_MB at 1M digits, scaled proportionally
    DM="$(awk -v d="$DIGITS" 'BEGIN {
        split("128K 256K 512K 1M 2M 4M 8M 16M 32M 64M 128M", name, " ")
        split("0.125 0.25 0.5 1 2 4 8 16 32 64 128",         val,  " ")
        for (i = 1; i <= 11; i++) if (name[i] == d) printf "%.3f", val[i]
    }')"
    PER_THREAD_MB="$(awk -v m="$SYSTESTER_PER_THREAD_MB" -v dm="$DM" 'BEGIN {printf "%d", m * dm}')"
    [ "$PER_THREAD_MB" -lt 8 ] 2>/dev/null && PER_THREAD_MB=8

    THREADS="$NPROC"
    # systester hard-caps at MAX_THREADS 64
    [ "$THREADS" -gt 64 ] && THREADS=64
    # keep total worker memory under ~50% of what is currently available
    MEM_CAP_THREADS=$((MEM_AVAIL_MB * 50 / 100 / PER_THREAD_MB))
    if [ "$THREADS" -gt "$MEM_CAP_THREADS" ]; then
        log "RAM guard: limiting threads $THREADS -> $MEM_CAP_THREADS (${PER_THREAD_MB}MB/thread at $DIGITS digits)"
        THREADS="$MEM_CAP_THREADS"
    fi
    [ "$THREADS" -lt 1 ] && THREADS=1

    SYST_DIR="$LOG_DIR/$STAMP/systester"
    mkdir -p "$SYST_DIR"
    log "RAM ${MEM_TOTAL_MB}MB -> $DIGITS digits (1M per GB rule); $THREADS threads x ${PER_THREAD_MB}MB budget"
    log "running: systester-cli -gausslg $DIGITS -threads $THREADS -turns $SYSTESTER_TURNS"
    log "(live progress below; safety cap ${SYSTESTER_MAX_MINUTES} min)"

    (
        cd "$SYST_DIR" &&
        timeout -k 30 "${SYSTESTER_MAX_MINUTES}m" \
            systester-cli -gausslg "$DIGITS" -threads "$THREADS" -turns "$SYSTESTER_TURNS" -test -log
    ) >>"$LOG" 2>&1 &
    SYST_PID=$!
    SYST_START=$SECONDS
    while kill -0 "$SYST_PID" 2>/dev/null; do
        sleep 5
        EL=$((SECONDS - SYST_START))
        printf '\r    [systester] crunching pi (%s digits = %s/GB RAM, %d threads)... %s elapsed / cap %dmin   ' \
            "$DIGITS" "$DM" "$THREADS" "$(fmt_mmss "$EL")" "$SYSTESTER_MAX_MINUTES"
    done
    wait "$SYST_PID"
    rc=$?
    clr
    if [ "$rc" -eq 0 ]; then
        stage "systester" "PASS" "completed $SYSTESTER_TURNS turn(s) at $DIGITS digits ($MEM_TOTAL_MB MB RAM) with $THREADS threads in $(fmt_mmss $((SECONDS - SYST_START))) - no errors"
        tail -n 15 "$SYST_DIR/systester.log" >>"$LOG" 2>/dev/null || true
    elif [ "$rc" -eq 124 ]; then
        stage "systester" "FAIL" "hit the ${SYSTESTER_MAX_MINUTES}min safety cap mid-turn (machine too slow or hung?)"
    else
        stage "systester" "FAIL" "exited rc=$rc after $(fmt_mmss $((SECONDS - SYST_START))) (crash/OOM? see log)"
    fi
fi

# ---------------------------------------------------- GST / stress-ng -----
section "Stage 5: GTK Stress Testing (GST) - ${GST_SECONDS}s"
export DISPLAY="${DISPLAY:-:0.0}"
if ! command -v gst >/dev/null 2>&1; then
    stage "gst" "FAIL" "gst binary missing from image"
elif ! command -v stress-ng >/dev/null 2>&1; then
    stage "gst" "FAIL" "stress-ng missing from image"
else
    spin_start "opening GST monitoring window..."
    setsid nohup gst </dev/null >>"$LOG" 2>&1 &
    GST_PID=$!
    sleep 6
    spin_stop
    kill -0 "$GST_PID" 2>/dev/null && log "GST GUI open (pid $GST_PID); window stays up so you can review temps later"

    # Exact mirror of GST's default selection ("CPU: All methods",
    # Workers=Auto): see gst/interactor/get_stressors_interactor.py and
    # gst/repository/stress_ng_repository.py upstream.
    TMPDIR_GST="$(mktemp -d /tmp/gst-stress.XXXXXX)"
    log "stress-ng: --cpu $NPROC --cpu-method all --verify --timeout ${GST_SECONDS}s"
    timeout -k 30 $((GST_SECONDS + 45)) \
        stress-ng \
            --yaml "$TMPDIR_GST/report.yaml" \
            --metrics --times --no-rand-seed \
            --temp-path "$TMPDIR_GST" \
            --timeout "${GST_SECONDS}s" \
            --verify \
            --cpu "$NPROC" --cpu-method all \
            >>"$LOG" 2>&1 &
    SNG_PID=$!
    SNG_START=$SECONDS
    while kill -0 "$SNG_PID" 2>/dev/null; do
        sleep 5
        REM=$((GST_SECONDS - (SECONDS - SNG_START)))
        [ "$REM" -lt 0 ] && REM=0
        printf '\r    [gst/stress-ng] stressing all %d cores... ~%ds remaining of %ds   ' \
            "$NPROC" "$REM" "$GST_SECONDS"
    done
    wait "$SNG_PID"
    rc=$?
    clr
    BOGO="$(awk '/bogo-ops:/ {sum += $NF} END {printf "%.0f", sum}' "$TMPDIR_GST/report.yaml" 2>/dev/null)"
    ELAPSED="$(awk '/wall-clock-time:/ {sum += $NF} END {printf "%.0f", sum}' "$TMPDIR_GST/report.yaml" 2>/dev/null)"
    cp "$TMPDIR_GST/report.yaml" "$LOG_DIR/$STAMP/stress-ng-report.yaml" 2>/dev/null || true
    rm -rf "$TMPDIR_GST"
    if [ "$rc" -eq 0 ] && [ "${ELAPSED:-0}" -ge $((GST_SECONDS - 10)) ]; then
        stage "gst" "PASS" "${GST_SECONDS}s all-core stress verified (workers=$NPROC, bogo-ops=${BOGO:-?}, elapsed=${ELAPSED:-?}s)"
    else
        stage "gst" "FAIL" "rc=$rc elapsed=${ELAPSED:-0}s bogo-ops=${BOGO:-?} (see log)"
    fi
fi

# ------------------------------------------------------------ summary ----
section "Results summary"
FAILS=0
SUMMARY_LINES=""
for name in "${RESULTS_ORDER[@]}"; do
    st="${RESULTS[$name]}"
    line="$(printf '%-12s %-5s %s' "$name" "$st" "${DETAILS[$name]}")"
    SUMMARY_LINES+="$line"$'\n'
    [ "$st" = "FAIL" ] && FAILS=$((FAILS + 1))
done
echo "$SUMMARY_LINES" | tee -a "$LOG"
VERDICT="PASS"
[ "$FAILS" -gt 0 ] && VERDICT="FAIL ($FAILS stage(s) failed)"

SENSORS_OUT="$(sensors 2>/dev/null || true)"

{
echo "---------------------------------------------------------------"
echo " VERDICT: $VERDICT"
echo " Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo " Full log: $LOG"
[ -n "$SENSORS_OUT" ] && { echo; echo "--- sensors at finish ---"; echo "$SENSORS_OUT"; }
} | tee -a "$LOG"

# Desktop report so the results are one double-click away
cp "$LOG" "$REPORT" 2>/dev/null || cp "$LOG" "$HOME/Desktop/" 2>/dev/null || true

notify_send_done() {
    command -v notify-send >/dev/null 2>&1 && \
        notify-send -u critical -i dialog-information "BurnBench finished: $VERDICT" \
        "Report on the desktop: $(basename "$REPORT")"
}

# ------------------------------------------------------------ the tone ---
if [ "${PLAY_TONE:-1}" = "1" ]; then
    notify_send_done
    log "playing result tone..."
    if [ "$VERDICT" != "PASS" ]; then
        # three short chimes signal failure audibly
        paplay "$SHARE_DIR/success.wav" >/dev/null 2>&1
        sleep 0.4; paplay "$SHARE_DIR/success.wav" >/dev/null 2>&1; sleep 0.4
        paplay "$SHARE_DIR/success.wav" >/dev/null 2>&1
    elif paplay "$SHARE_DIR/success.wav" >/dev/null 2>&1; then
        log "success tone played"
    elif command -v speaker-test >/dev/null 2>&1; then
        speaker-test -t sine -f 880 -l 2 >/dev/null 2>&1 && log "tone played via speaker-test"
    else
        printf '\a' >&2
    fi
else
    notify_send_done
fi

log "all stages complete - verdict $VERDICT"
[ "$FAILS" -eq 0 ]
