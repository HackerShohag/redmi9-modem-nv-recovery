#!/usr/bin/env bash
set -euo pipefail

# health_check.sh - One-shot modem/SIM status summary & anomaly flags
# Usage: ./toolkit/health_check.sh [--radio-lines 300]

RADIO_LINES=200
while [ $# -gt 0 ]; do
  case "$1" in
    --radio-lines) RADIO_LINES="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

ADB=${ADB:-adb}
DEVICE=${DEVICE:-}

pick(){
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

prop(){ $ADB -s "$DEVICE" shell getprop "$1" 2>/dev/null || true; }

pick

md_status=$(prop vendor.ril.md_status_from_ccci)
md1=$(prop vendor.mtk.md1.status)
sim_state=$(prop gsm.sim.state)
operators=$(prop gsm.operator.numeric)

echo "Device: $DEVICE"
echo "MD Status (ccci): $md_status"
echo "MD1 Status      : $md1"
echo "SIM State       : $sim_state"
echo "Operators       : $operators"

echo "--- Radio Focus (last ${RADIO_LINES} lines) ---"
$ADB -s "$DEVICE" logcat -b radio -t "$RADIO_LINES" 2>/dev/null | egrep -i 'GET_SIM_STATUS|ICCID|IMSI|RADIO_NOT_AVAILABLE|SIM_STATUS_CHANGED' || true

rna_count=$($ADB -s "$DEVICE" logcat -b radio -t "$RADIO_LINES" 2>/dev/null | grep -c 'RADIO_NOT_AVAILABLE' || true)

echo "--- Anomaly Flags ---"
flag=0
if [ "$md_status" != "ready" ]; then echo "[!] vendor.ril.md_status_from_ccci != ready"; flag=1; fi
if [ "$md1" != "ready" ]; then echo "[!] vendor.mtk.md1.status != ready"; flag=1; fi
if echo "$sim_state" | grep -qiE 'ABSENT|UNKNOWN'; then echo "[!] SIM state shows ABSENT/UNKNOWN"; flag=1; fi
if [ "$rna_count" -gt 5 ]; then echo "[!] Excess RADIO_NOT_AVAILABLE occurrences ($rna_count)"; flag=1; fi
[ $flag -eq 0 ] && echo "No critical anomalies detected." || echo "One or more anomalies present." 
