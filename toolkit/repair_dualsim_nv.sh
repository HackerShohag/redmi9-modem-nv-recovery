#!/usr/bin/env bash
set -euo pipefail

# Automated Dual-SIM Recovery Script (Redmi 9 / MTK Helio G80)
# Focus: Recover from modem NV corruption causing MD assertion (nvram_io.c:2679),
#        persistent ABSENT/UNKNOWN SIM states, RADIO_NOT_AVAILABLE spam.
#
# Strategy:
# 1. Pre-flight diagnostics & capture (props, radio, dmesg focus)
# 2. Heuristic failure detection (conditions matching historical issue)
# 3. Safe backups: current nvdata + nvcfg + diagnostic bundle
# 4. nvdata isolation (rename) to trigger regeneration on reboot
# 5. Post-reboot polling & validation of recovery signals
# 6. If successful: create known-good snapshot; if not: guided rollback
#
# REQUIREMENTS: adb, root (su). Use ONLY on the affected device profile.
# WARNING: This will reboot the device and modify /mnt/vendor/nvdata.

DEVICE=""            # autodetect single device if empty
ADB="adb"
TS="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="repairs/repair_${TS}"
MAX_POLL=30           # iterations * sleep seconds for post-reboot validation
SLEEP_INTERVAL=6      # seconds between polls
LOG_FOCUS_REGEX='gsm.sim.state|operator.numeric|vendor.ril.md_status_from_ccci|vendor.mtk.md1.status|uicc.applications.enable.state'

mkdir -p "$WORK_DIR/pre" "$WORK_DIR/post" || true

log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }

ensure_device(){
  command -v "$ADB" >/dev/null || fail "adb not found"
  local devs
  devs=$($ADB devices | awk 'NR>1 && $2=="device" {print $1}')
  if [ -n "$DEVICE" ]; then
    echo "$devs" | grep -q "^${DEVICE}$" || fail "Specified device $DEVICE not connected"
  else
    local c
    c=$(echo "$devs" | awk 'NF' | wc -l | tr -d ' ')
    [ "$c" = 1 ] || fail "Expected exactly one device (found $c). Export DEVICE=<serial> to disambiguate."
    DEVICE=$(echo "$devs" | awk 'NF')
  fi
  log "Using device $DEVICE"
}

shell(){ $ADB -s "$DEVICE" shell "$@"; }
root(){ $ADB -s "$DEVICE" shell su -c "$@"; }

check_root(){
  shell su -c id 2>/dev/null | grep -q 'uid=0' || fail "Root access (su) required"
  log "Root confirmed"
}

capture_pre(){
  log "Capturing pre-fix diagnostics"
  shell getprop > "$WORK_DIR/pre/getprop_all.txt" || true
  shell getprop | egrep "$LOG_FOCUS_REGEX" > "$WORK_DIR/pre/getprop_focus.txt" || true
  shell logcat -b radio -v time -d > "$WORK_DIR/pre/logcat_radio_full.txt" || true
  shell logcat -b radio -v time -d | egrep -i 'GET_SIM_STATUS|ICCID|IMSI|RADIO_NOT_AVAILABLE|SIM_STATUS_CHANGED' > "$WORK_DIR/pre/logcat_radio_focus.txt" || true
  shell dmesg > "$WORK_DIR/pre/dmesg_full.txt" || true
  shell dmesg | egrep -i 'ccci|nvram_io|md exception|ril' > "$WORK_DIR/pre/dmesg_modem_focus.txt" || true
}

heuristic_failure_detect(){
  log "Evaluating failure heuristics"
  local focus="$WORK_DIR/pre/getprop_focus.txt"
  [ -f "$focus" ] || return 1
  local sim_state md_status md1 iccid_part
  sim_state=$(grep -m1 'gsm.sim.state' "$focus" | awk -F'= ' '{print $2}')
  md_status=$(grep -m1 'vendor.ril.md_status_from_ccci' "$focus" | awk -F'= ' '{print $2}')
  md1=$(grep -m1 'vendor.mtk.md1.status' "$focus" | awk -F'= ' '{print $2}')
  iccid_part=$(grep -m1 'preiccid' "$focus" | awk -F'= ' '{print $2}')
  # Conditions: both slots not LOADED; md status != ready; or known partial ICCID w/ stop
  if echo "$sim_state" | grep -qE 'ABSENT|UNKNOWN' && [ "$md_status" != "ready" ]; then
    return 0
  fi
  if [ "$md1" != "ready" ]; then
    return 0
  fi
  if [ -n "$iccid_part" ] && [ "$md_status" = "stop" ]; then
    return 0
  fi
  return 1
}

backup_current_nv(){
  log "Backing up current nvdata & nvcfg"
  root "tar -czf /sdcard/nvdata_before_fix_${TS}.tar.gz /mnt/vendor/nvdata" || log "Warning: nvdata tar failed"
  root "tar -czf /sdcard/nvcfg_before_fix_${TS}.tar.gz /mnt/vendor/nvcfg" || log "Warning: nvcfg tar failed"
  $ADB -s "$DEVICE" pull /sdcard/nvdata_before_fix_${TS}.tar.gz "$WORK_DIR/" 2>/dev/null || true
  $ADB -s "$DEVICE" pull /sdcard/nvcfg_before_fix_${TS}.tar.gz "$WORK_DIR/" 2>/dev/null || true
}

isolate_nvdata(){
  log "Isolating nvdata (rename to trigger regeneration)"
  local ts_short=$(date +%s)
  root "mv /mnt/vendor/nvdata /mnt/vendor/nvdata.bak_${ts_short}" || fail "Rename nvdata failed"
  root "mv /mnt/vendor/nvcfg /mnt/vendor/nvcfg.bak_${ts_short}" || log "nvcfg rename skipped (maybe absent)"
  log "Requesting device reboot"
  shell reboot || fail "Reboot command failed"
}

wait_for_device(){
  log "Waiting for device to come back"
  $ADB -s "$DEVICE" wait-for-device
  # Additional short sleep to allow properties to settle
  sleep 5
}

poll_post_state(){
  log "Polling post-reboot state (max ${MAX_POLL} * ${SLEEP_INTERVAL}s)"
  local i=0
  while [ $i -lt $MAX_POLL ]; do
    sleep $SLEEP_INTERVAL
    shell getprop | egrep "$LOG_FOCUS_REGEX" > "$WORK_DIR/post/getprop_focus_poll.txt" || true
    local md=$(grep -m1 'vendor.ril.md_status_from_ccci' "$WORK_DIR/post/getprop_focus_poll.txt" | awk -F'= ' '{print $2}')
    local sim=$(grep -m1 'gsm.sim.state' "$WORK_DIR/post/getprop_focus_poll.txt" | awk -F'= ' '{print $2}')
    log "Poll $((i+1)): md=$md sim=$sim"
    if [ "$md" = "ready" ] && echo "$sim" | grep -q 'LOADED'; then
      log "Success criteria met (md ready & SIM LOADED)"
      return 0
    fi
    i=$((i+1))
  done
  return 1
}

capture_post(){
  log "Capturing post-fix diagnostics"
  shell getprop > "$WORK_DIR/post/getprop_all.txt" || true
  shell getprop | egrep "$LOG_FOCUS_REGEX" > "$WORK_DIR/post/getprop_focus.txt" || true
  shell logcat -b radio -v time -d > "$WORK_DIR/post/logcat_radio_full.txt" || true
  shell logcat -b radio -v time -d | egrep -i 'GET_SIM_STATUS|ICCID|IMSI|RADIO_NOT_AVAILABLE|SIM_STATUS_CHANGED' > "$WORK_DIR/post/logcat_radio_focus.txt" || true
  shell dmesg > "$WORK_DIR/post/dmesg_full.txt" || true
  shell dmesg | egrep -i 'ccci|nvram_io|md exception|ril' > "$WORK_DIR/post/dmesg_modem_focus.txt" || true
}

finalize_success(){
  log "Creating known-good nvdata snapshot after recovery"
  root "tar -czf /sdcard/nvdata_good_${TS}.tar.gz /mnt/vendor/nvdata" || true
  $ADB -s "$DEVICE" pull /sdcard/nvdata_good_${TS}.tar.gz "$WORK_DIR/" 2>/dev/null || true
  log "Recovery complete. See $WORK_DIR"
}

rollback_hint(){
  cat >&2 <<EOF
---
Recovery did NOT meet success criteria within polling window.
You may manually rollback with (example, adjust timestamp):
  su -c 'mv /mnt/vendor/nvdata /mnt/vendor/nvdata.failed_${TS}'
  su -c 'mv /mnt/vendor/nvdata.bak_<orig_ts> /mnt/vendor/nvdata'
Then reboot and re-run diagnostics.
Collected logs remain in: $WORK_DIR
---
EOF
}

main(){
  ensure_device
  check_root
  capture_pre
  if heuristic_failure_detect; then
    log "Failure heuristics MATCH historical NV corruption pattern. Proceeding."
  else
    log "Heuristics did NOT match severe failure; aborting (no action)."
    log "View diagnostics under $WORK_DIR/pre"; exit 0
  fi
  backup_current_nv
  isolate_nvdata
  log "Waiting 8s to allow ADB disconnect..."; sleep 8
  wait_for_device
  if poll_post_state; then
    capture_post
    finalize_success
    exit 0
  else
    capture_post
    rollback_hint
    exit 2
  fi
}

main "$@"
