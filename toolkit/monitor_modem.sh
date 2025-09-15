#!/usr/bin/env bash
set -euo pipefail

# monitor_modem.sh - Lightweight modem/SIM health logger with optional alerts
# Periodically captures key properties and counts RADIO_NOT_AVAILABLE occurrences.
# Can emit alert lines and/or exit non-zero when thresholds exceeded.
#
# Environment / Args:
#   INTERVAL=120            Poll interval seconds (default 120)
#   ALERT_RNA=10            Threshold for RADIO_NOT_AVAILABLE count in last slice
#   ALERT_SIM_PATTERN='ABSENT|UNKNOWN'  Regex for problematic SIM states
#   EXIT_ON_ALERT=1         If set (1), script exits code 20 on first alert
#   ON_ALERT_CMD='command'  Optional command executed locally when alert fires
#
# Usage:
#   INTERVAL=90 ALERT_RNA=5 EXIT_ON_ALERT=1 ./toolkit/monitor_modem.sh
#
# Output: <LOG_DIR>/modem_health.log and optional ALERT lines to stderr.

INTERVAL="${INTERVAL:-120}"
LOG_DIR="${LOG_DIR:-monlogs}"
ALERT_RNA="${ALERT_RNA:-10}"
ALERT_SIM_PATTERN="${ALERT_SIM_PATTERN:-ABSENT|UNKNOWN}"
EXIT_ON_ALERT="${EXIT_ON_ALERT:-0}"
ON_ALERT_CMD="${ON_ALERT_CMD:-}"
ADB=${ADB:-adb}
DEVICE="${DEVICE:-}"  # autodetect if empty

mkdir -p "$LOG_DIR"

pick_device(){
  local devs
  devs=$($ADB devices | awk 'NR>1 && $2=="device" {print $1}')
  if [ -n "$DEVICE" ]; then
    echo "$devs" | grep -q "^${DEVICE}$" || { echo "Device $DEVICE not found" >&2; exit 1; }
  else
    local c
    c=$(echo "$devs" | awk 'NF' | wc -l | tr -d ' ')
    [ "$c" = 1 ] || { echo "Expected one device, found $c" >&2; exit 1; }
    DEVICE=$(echo "$devs" | awk 'NF')
  fi
}

grab_radio_snapshot(){
  # Count RADIO_NOT_AVAILABLE over last short window (pull small log slice)
  local radio_chunk
  radio_chunk=$($ADB -s "$DEVICE" logcat -b radio -t 200 2>/dev/null || true)
  local rna_count
  rna_count=$(echo "$radio_chunk" | grep -c 'RADIO_NOT_AVAILABLE' || true)
  echo "$rna_count"
}

grab_props(){
  $ADB -s "$DEVICE" shell getprop | egrep 'vendor.ril.md_status_from_ccci|vendor.mtk.md1.status|gsm.sim.state|gsm.operator.numeric' || true
}

pick_device
echo "# Monitoring device $DEVICE every ${INTERVAL}s" | tee -a "$LOG_DIR/modem_health.log"

while true; do
  ts=$(date +%Y-%m-%dT%H:%M:%S)
  props=$(grab_props)
  rna=$(grab_radio_snapshot)
  line_props="$(echo "$props" | tr '\n' ' ' | sed -E 's/ +/ /g')"
  printf '%s | %s | RADIO_NOT_AVAILABLE(last200)=%s\n' "$ts" "$line_props" "$rna" | tee -a "$LOG_DIR/modem_health.log"
  alert=0
  if [ "$rna" -ge "$ALERT_RNA" ]; then
    echo "ALERT: High RADIO_NOT_AVAILABLE count=$rna (>= $ALERT_RNA) at $ts" >&2
    alert=1
  fi
  if echo "$line_props" | grep -E "gsm.sim.state=.*($ALERT_SIM_PATTERN)" >/dev/null 2>&1; then
    echo "ALERT: Problematic SIM state detected ($line_props)" >&2
    alert=1
  fi
  if [ $alert -eq 1 ] && [ -n "$ON_ALERT_CMD" ]; then
    bash -c "$ON_ALERT_CMD" || true
  fi
  if [ $alert -eq 1 ] && [ "$EXIT_ON_ALERT" = "1" ]; then
    echo "Exiting due to alert (EXIT_ON_ALERT=1)" >&2
    exit 20
  fi
  sleep "$INTERVAL"
done
