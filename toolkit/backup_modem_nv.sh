#!/usr/bin/env bash
set -euo pipefail

# Redmi 9 (lancelot MTK) modem & NV backup helper
# Creates timestamped directory under backups/ with:
#  - Raw partition dumps (if accessible via adb shell su + dd)
#  - nvdata & nvcfg tarballs
#  - getprop focus snapshot
#  - SHA256SUMS manifest
#  - manifest.json (structured metadata)
#
# Requirements:
#  - adb in PATH
#  - Device connected, USB debugging enabled
#  - Root (su) available on device for raw block & /mnt/vendor access
#
# Usage:
#   ./toolkit/backup_modem_nv.sh            # default (all artifacts)
#   DRY_RUN=1 ./toolkit/backup_modem_nv.sh  # show what would run
#
# Safe Restore NOTE: Restoring preloader / lk blindly can brick device.
# Only restore nvdata/nvcfg or modem images if regression occurs and
# versions match. Keep backups off-device.

DEVICE=""  # leave empty to auto-pick single device
ADB="adb"
DATE_TS="$(date +%Y%m%d_%H%M%S)"
OUT_BASE="backups/modem_nv_${DATE_TS}"
DRY_RUN="${DRY_RUN:-0}"
RESUME_DIR="${RESUME_DIR:-}"   # set to existing backup dir to append missing artifacts
DD_TIMEOUT="${DD_TIMEOUT:-40}"  # seconds per partition dump before aborting that partition

PARTITIONS=(
  md1img
  md1dsp
  scp
  sspm
  spmfw
  tee1
  tee2
  lk
  vbmeta
  preloader
)

log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" ; }
run(){ if [ "$DRY_RUN" = "1" ]; then echo "DRY: $*"; else eval "$@"; fi }

fatal(){ echo "ERROR: $*" >&2; exit 1; }

ensure_adb(){
  command -v "$ADB" >/dev/null 2>&1 || fatal "adb not found in PATH"
  local devices
  devices=$($ADB devices | awk 'NR>1 && $2=="device" {print $1}')
  if [ -n "$DEVICE" ]; then
    echo "$devices" | grep -q "^${DEVICE}$" || fatal "Specified device $DEVICE not connected"
  else
    local count
    count=$(echo "$devices" | awk 'NF' | wc -l | tr -d ' ')
    [ "$count" = "1" ] || fatal "Expected exactly one device (got $count). Set DEVICE=serial to choose."
    DEVICE=$(echo "$devices" | awk 'NF')
  fi
  log "Using device $DEVICE"
}

adb_shell(){ run "$ADB -s $DEVICE shell \"$*\""; }
adb_pull(){ run "$ADB -s $DEVICE pull $1 $2"; }

prepare_out(){ run "mkdir -p '$OUT_BASE/parts' '$OUT_BASE/nv'"; }

init_out_dir(){
  if [ -n "$RESUME_DIR" ]; then
    [ -d "$RESUME_DIR" ] || fatal "RESUME_DIR '$RESUME_DIR' not found"
    OUT_BASE="$RESUME_DIR"
    DATE_TS="$(echo "$RESUME_DIR" | sed -E 's/.*modem_nv_([0-9_]+)/\1/')"
    log "Resume mode: appending to $OUT_BASE"
  else
    prepare_out
  fi
}

root_check(){
  local id_out
  id_out=$($ADB -s $DEVICE shell su -c id 2>/dev/null || true)
  echo "$id_out" | grep -q "uid=0" || fatal "Root (su) required. id_out=$id_out"
  log "Root access confirmed"
}

dump_partition(){
  local part=$1
  local dest="$OUT_BASE/parts/${part}.img"
  log "Dumping $part"
  local path
  path=$($ADB -s $DEVICE shell "ls -1 /dev/block/by-name/${part} 2>/dev/null" | tr -d '\r')
  if [ -z "$path" ]; then
    log "Skipping $part (not found)"
    return 0
  fi
  if [ -s "$dest" ]; then
    log "Skipping $part (already exists, size $(stat -c %s "$dest"))"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: would dump $part from $path"
    return 0
  fi
  # Timeout wrapper: kill dd if it hangs
  if ! timeout "$DD_TIMEOUT" $ADB -s $DEVICE shell su -c "dd if=$path bs=4M" > "$dest" 2>"$OUT_BASE/parts/${part}.log"; then
    log "Warning: dd timeout/fail for $part (>$DD_TIMEOUT s). Partial file kept if non-zero."
  fi
  if [ ! -s "$dest" ]; then
    log "Warning: $part dump empty; removing"
    rm -f "$dest"
  fi
}

archive_nv(){
  for dir in /mnt/vendor/nvdata /mnt/vendor/nvcfg; do
    local base=$(basename "$dir")
    local tar_remote="/sdcard/${base}_${DATE_TS}.tar.gz"
    log "Archiving $dir -> $tar_remote"
    adb_shell "su -c 'tar -czf $tar_remote $dir'" || log "Warning: tar of $dir failed"
    if [ "$DRY_RUN" != "1" ]; then
      if [ -s "$OUT_BASE/nv/${base}_${DATE_TS}.tar.gz" ]; then
        log "NV archive for $base already exists; skipping pull (resume mode)"
      else
        adb_pull "$tar_remote" "$OUT_BASE/nv/" || log "Warning: pull of $tar_remote failed"
      fi
    fi
  done
}

capture_props(){
  log "Capturing focused getprop"
  adb_shell "getprop | egrep 'gsm.sim.state|operator.numeric|vendor.ril.md_status_from_ccci|vendor.mtk.md1.status|uicc.applications.enable.state'" > "$OUT_BASE/getprop_focus.txt" || true
  adb_shell "getprop" > "$OUT_BASE/getprop_all.txt" || true
}

write_manifest(){
  log "Writing manifest.json"
  local manifest="$OUT_BASE/manifest.json"
  if [ "$DRY_RUN" = "1" ]; then echo "DRY: would write manifest"; return 0; fi
  {
    echo '{'
    echo "  \"device\": \"$DEVICE\"," 
    echo "  \"timestamp\": \"$DATE_TS\"," 
    echo '  "partitions": ['
    local first=1
    for p in "${PARTITIONS[@]}"; do
      local f="parts/${p}.img"
      [ -f "$OUT_BASE/$f" ] || continue
      local sz=$(stat -c %s "$OUT_BASE/$f")
      if [ $first -eq 0 ]; then echo ','; fi
      first=0
      printf '    {"name":"%s","file":"%s","size":%s}' "$p" "$f" "$sz"
    done
    echo ''
    echo '  ],'
    echo '  "nv_archives": ['
    first=1
    for nv in "$OUT_BASE"/nv/*.tar.gz; do
      [ -e "$nv" ] || continue
      local base=$(basename "$nv")
      local sz=$(stat -c %s "$nv")
      if [ $first -eq 0 ]; then echo ','; fi
      first=0
      printf '    {"file":"nv/%s","size":%s}' "$base" "$sz"
    done
    echo ''
    echo '  ]'
    echo '}'
  } > "$manifest"
}

hash_files(){
  log "Computing SHA256 sums"
  ( cd "$OUT_BASE" && find . -type f ! -name SHA256SUMS -exec sha256sum {} + | sort -k2 > SHA256SUMS )
}

pre_scan_partitions(){
  log "Pre-scan: filtering partition list to existing entries"
  local existing=()
  for p in "${PARTITIONS[@]}"; do
    local path
    path=$($ADB -s $DEVICE shell "ls -1 /dev/block/by-name/${p} 2>/dev/null" | tr -d '\r')
    [ -n "$path" ] && existing+=("$p") || log "Partition missing: $p (will skip)"
  done
  PARTITIONS=("${existing[@]}")
  log "Partitions to dump: ${PARTITIONS[*]}"
}

main(){
  ensure_adb
  init_out_dir
  root_check
  capture_props
  pre_scan_partitions
  for p in "${PARTITIONS[@]}"; do dump_partition "$p"; done
  archive_nv
  write_manifest
  hash_files
  log "Backup complete: $OUT_BASE"
  log "Review SHA256SUMS and consider off-device archival."
}

main "$@"