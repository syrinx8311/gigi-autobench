#!/bin/bash
# BurnBench automated burn-in and benchmark suite.
# Designed to be launched from the "BurnBench Burn-In" desktop icon on the
# live ISO. Coworkers double-click, walk away, and hear the tone when done.
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

# ---------------------------------------------------------------- header ---
{
echo "==============================================================="
echo " BurnBench automated burn-in   $(date '+%Y-%m-%d %H:%M:%S')"
echo " Host: $HOSTNAME"
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
    done
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
    section "Stage 2: WiFi"
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
        log "available networks right now:"
        nmcli -f IN-USE,SSID,SIGNAL,SECURITY device wifi list --rescan yes 2>>"$LOG" \
            | sed 's/^/    scan| /' | tee -a "$LOG" >/dev/null

        deadline=$((SECONDS + WIFI_TIMEOUT_SECS))
        until nmcli -t -f GENERAL.STATE connection show burnbench-wifi 2>/dev/null | grep -q activated; do
            nmcli connection up burnbench-wifi --nowait >>"$LOG" 2>&1
            sleep 5
            [ $SECONDS -ge "$deadline" ] && break
        done
        if nmcli -t -f GENERAL.STATE connection show burnbench-wifi 2>/dev/null | grep -q activated; then
            ACT_IFACE="$(nmcli -g GENERAL.DEVICES connection show burnbench-wifi 2>/dev/null)"
            IP_ADDR="$(ip -4 -o addr show dev "$ACT_IFACE" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
            SIGNAL="$(nmcli -t -f ACTIVE,SIGNAL dev wifi list 2>/dev/null | head -1)"
            stage "wifi" "PASS" "connected to '${BAKED_SSID:-burnbench-wifi}' via $ACT_IFACE ip=$IP_ADDR signal=${SIGNAL:-?}%"

        else
            stage "wifi" "FAIL" "could not associate with '${BAKED_SSID:-burnbench-wifi}' within ${WIFI_TIMEOUT_SECS}s (see log)"
        fi
    fi
else
    stage "wifi" "SKIP" "disabled in config"
fi

# --------------------------------------------------------------- camera ---
CAM_PIDS=""
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
        if command -v guvcview >/dev/null 2>&1; then
            setsid nohup guvcview </dev/null >>"$LOG" 2>&1 &
            CAM_PID=$!
        elif command -v cheese >/dev/null 2>&1; then
            setsid nohup cheese </dev/null >>"$LOG" 2>&1 &
            CAM_PID=$!
        else
            stage "camera" "WARN" "devices found ($CAM_DEVS) but no viewer installed in image"
        fi
        if [ -n "$CAM_PID" ]; then
            CAM_PIDS="$CAM_PIDS $CAM_PID"
            sleep 3
            if kill -0 "$CAM_PID" 2>/dev/null; then
                stage "camera" "PASS" "viewer started for:$CAM_DEVS (pid $CAM_PID)"
            else
                stage "camera" "WARN" "devices found ($CAM_DEVS) but viewer exited early; see log"
            fi
        fi
    fi
else
    stage "camera" "SKIP" "disabled in config"
fi

# ------------------------------------------------------------ systester ---
section "Stage 4: systester-cli (CPU/RAM stability)"
command -v systester-cli >/dev/null 2>&1 || stage "systester" "FAIL" "binary missing from image"

if [ -z "${RESULTS[systester]:-}" ]; then
    THREADS="$NPROC"
    # systester hard-caps at MAX_THREADS 64
    [ "$THREADS" -gt 64 ] && THREADS=64
    # keep total worker memory under ~50% of what is currently available
    MEM_CAP_THREADS=$((MEM_AVAIL_MB * 50 / 100 / SYSTESTER_PER_THREAD_MB))
    if [ "$THREADS" -gt "$MEM_CAP_THREADS" ]; then
        log "RAM guard: limiting threads $THREADS -> $MEM_CAP_THREADS (${SYSTESTER_PER_THREAD_MB}MB/thread budget)"
        THREADS="$MEM_CAP_THREADS"
    fi
    [ "$THREADS" -lt 1 ] && THREADS=1
    TURNS=1000000   # effectively unbounded; timeout below enforces wall clock
    SYST_DIR="$LOG_DIR/$STAMP/systester"
    mkdir -p "$SYST_DIR"
    log "running: systester-cli -gausslg $SYSTESTER_DIGITS -threads $THREADS -turns $TURNS (limit ${SYSTESTER_MINUTES} min)"
    (
        cd "$SYST_DIR" &&
        timeout -k 30 "${SYSTESTER_MINUTES}m" \
            systester-cli -gausslg "$SYSTESTER_DIGITS" -threads "$THREADS" -turns "$TURNS" -test -log
    ) >>"$LOG" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]; then
        [ "$rc" -eq 0 ] \
            && stage "systester" "PASS" "completed all turns cleanly ($THREADS threads)" \
            || stage "systester" "PASS" "ran full ${SYSTESTER_MINUTES}min with $THREADS threads, no crash"
        tail -n 15 "$SYST_DIR/systester.log" >>"$LOG" 2>/dev/null || true
    else
        stage "systester" "FAIL" "exited rc=$rc after $((SECONDS))s of ${SYSTESTER_MINUTES}min (crash/OOM? see log)"
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
    setsid nohup gst </dev/null >>"$LOG" 2>&1 &
    GST_PID=$!
    sleep 6
    kill -0 "$GST_PID" 2>/dev/null && log "GST GUI open (pid $GST_PID), monitoring while stress-ng runs"

    # Exact mirror of GST's default selection ("CPU: All methods",
    # Workers=Auto): see gst/interactor/get_stressors_interactor.py and
    # gst/repository/stress_ng_repository.py upstream.
    TMPDIR_GST="$(mktemp -d /tmp/gst-stress.XXXXXX)"
    timeout -s INT $((GST_SECONDS + 45)) \
        stress-ng \
            --yaml "$TMPDIR_GST/report.yaml" \
            --metrics --times --no-rand-seed \
            --temp-path "$TMPDIR_GST" \
            --timeout "${GST_SECONDS}s" \
            --verify \
            --cpu "$NPROC" --cpu-method all \
            >>"$LOG" 2>&1
    rc=$?
    BOGO="$(awk '/bogo-ops:/ {sum += $NF} END {printf "%.0f", sum}' "$TMPDIR_GST/report.yaml" 2>/dev/null)"
    ELAPSED="$(awk '/wall-clock-time:/ {sum += $NF} END {printf "%.0f", sum}' "$TMPDIR_GST/report.yaml" 2>/dev/null)"
    cp "$TMPDIR_GST/report.yaml" "$LOG_DIR/$STAMP/stress-ng-report.yaml" 2>/dev/null || true
    rm -rf "$TMPDIR_GST"
    if [ "$rc" -eq 0 ] && [ "${ELAPSED:-0}" -ge $((GST_SECONDS - 10)) ]; then
        stage "gst" "PASS" "${GST_SECONDS}s all-core stress verified (workers=$NPROC, bogo-ops=${BOGO:-?}, elapsed=${ELAPSED:-?}s)"
    else
        stage "gst" "FAIL" "rc=$rc elapsed=${ELAPSED:-0}s bogo-ops=${BOGO:-?} (see log)"
    fi
    # Leave the GST window open so whoever returns can inspect temps/graphs.
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
    if [ "$VERDICT" != "PASS" ]; then
        # three short low beeps signal failure audibly
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
