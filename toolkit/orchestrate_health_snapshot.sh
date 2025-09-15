#!/usr/bin/env bash
set -euo pipefail

# Orchestrator: perform (1) health check snapshot, (2) backup (if healthy or forced),
# and (3) optional diff against previous snapshot.
#
# Usage:
#   ./toolkit/orchestrate_health_snapshot.sh [--force-backup] [--prev <backup_dir>] \
#        [--tag note] [--radio-lines 300]
#
# Exit Codes:
#   0 success (healthy + backup done)
#   10 anomalies detected (no backup unless --force-backup)
#   2 usage / argument errors
#
FORCE=0
PREV=""
TAG=""
RADIO_LINES=300

while [ $# -gt 0 ]; do
  case "$1" in
    --force-backup) FORCE=1; shift;;
    --prev) PREV="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    --radio-lines) RADIO_LINES="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TOOLKIT="$ROOT_DIR/toolkit"
LOG_DIR="$ROOT_DIR/orchestrator_logs"
mkdir -p "$LOG_DIR"

timestamp(){ date +%Y-%m-%dT%H:%M:%S; }
log(){ printf '[%s] %s\n' "$(timestamp)" "$*" | tee -a "$LOG_DIR/orchestrator.log"; }

HC_OUT="$LOG_DIR/health_$(date +%Y%m%d_%H%M%S).txt"

run_health(){
  chmod +x "$TOOLKIT/health_check.sh"
  RADIO_LINES="$RADIO_LINES" ADB="${ADB:-adb}" "$TOOLKIT/health_check.sh" --radio-lines "$RADIO_LINES" > "$HC_OUT" 2>&1 || true
}

anomaly_detected(){ grep -q '\[!\]' "$HC_OUT"; }

perform_backup(){
  chmod +x "$TOOLKIT/backup_modem_nv.sh"
  ( cd "$ROOT_DIR" && ./toolkit/backup_modem_nv.sh ) | tee -a "$LOG_DIR/orchestrator.log"
}

maybe_diff_prev(){
  local latest
  latest=$(ls -1d "$ROOT_DIR"/backups/modem_nv_* 2>/dev/null | sort | tail -n1)
  [ -z "$PREV" ] && return 0
  [ -d "$PREV" ] || { log "Prev $PREV not found"; return 0; }
  local a="$PREV/nv/$(ls -1 "$PREV"/nv/ 2>/dev/null | grep nvdata | head -n1)"
  local b="$latest/nv/$(ls -1 "$latest"/nv/ 2>/dev/null | grep nvdata | head -n1)"
  if [ -f "$a" ] && [ -f "$b" ]; then
    chmod +x "$TOOLKIT/diff_nvdata.sh"
    log "Diffing nvdata archives: $a VS $b"
    "$TOOLKIT/diff_nvdata.sh" "$a" "$b" > "$LOG_DIR/diff_$(date +%Y%m%d_%H%M%S).txt" 2>&1 || true
  else
    log "Skipping diff (archives missing)"
  fi
}

tag_snapshot(){
  [ -n "$TAG" ] || return 0
  local latest
  latest=$(ls -1d "$ROOT_DIR"/backups/modem_nv_* 2>/dev/null | sort | tail -n1)
  [ -d "$latest" ] || return 0
  echo "$TAG" > "$latest/TAG" || true
}

log "Starting orchestrator (force=$FORCE prev='$PREV' tag='$TAG')"
run_health

if anomaly_detected; then
  log "Health check detected anomalies. See $HC_OUT"
  if [ $FORCE -eq 1 ]; then
    log "--force-backup specified; proceeding with backup despite anomalies"
    perform_backup
    tag_snapshot
    maybe_diff_prev
    exit 10
  else
    log "Skipping backup (use --force-backup to override)."
    exit 10
  fi
else
  log "Health OK; performing backup"
  perform_backup
  tag_snapshot
  maybe_diff_prev
  log "Completed successfully"
fi

exit 0
