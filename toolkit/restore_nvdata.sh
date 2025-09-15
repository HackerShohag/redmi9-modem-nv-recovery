#!/usr/bin/env bash
set -euo pipefail

# restore_nvdata.sh - Guided nvdata/nvcfg restore from a backup snapshot directory
#
# WARNING: Restores ONLY nvdata/nvcfg (no partition flashing). Ensure IMEI legality.
# Usage:
#   ./toolkit/restore_nvdata.sh backups/modem_nv_20250914_123045 nvdata_good_20250914_123045.tar.gz
# If only directory passed, will prompt to choose *.tar.gz inside nv/.

SNAPSHOT_DIR="$1" 2>/dev/null || { echo "Usage: $0 <snapshot_dir> [nvdata_archive.tar.gz]" >&2; exit 1; }
ARCHIVE="$2" 2>/dev/null || ARCHIVE=""
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

ensure_root(){ $ADB -s "$DEVICE" shell su -c id | grep -q 'uid=0' || { echo "Root required" >&2; exit 1; }; }

[ -d "$SNAPSHOT_DIR" ] || { echo "Snapshot dir not found" >&2; exit 1; }
if [ -z "$ARCHIVE" ]; then
  echo "Available nv archives:" >&2
  ls -1 "$SNAPSHOT_DIR"/nv/*.tar.gz 2>/dev/null || { echo "No nv archives found" >&2; exit 1; }
  echo -n "Enter archive filename (basename only): "
  read -r choice
  ARCHIVE="$SNAPSHOT_DIR/nv/$choice"
else
  case "$ARCHIVE" in
    */*) : ;; # path provided
    *) ARCHIVE="$SNAPSHOT_DIR/nv/$ARCHIVE" ;;
  esac
fi

[ -f "$ARCHIVE" ] || { echo "Archive $ARCHIVE not found" >&2; exit 1; }

echo "About to restore nvdata from: $ARCHIVE"
echo "This will overwrite current /mnt/vendor/nvdata contents. Continue? (yes/NO)"
read -r confirm
[ "$confirm" = "yes" ] || { echo "Abort."; exit 0; }

pick
ensure_root

TS=$(date +%s)
echo "Backing up current nvdata to /sdcard/nvdata_before_restore_${TS}.tar.gz"
$ADB -s "$DEVICE" shell su -c "tar -czf /sdcard/nvdata_before_restore_${TS}.tar.gz /mnt/vendor/nvdata" || echo "(backup warning)"
$ADB -s "$DEVICE" pull /sdcard/nvdata_before_restore_${TS}.tar.gz "$SNAPSHOT_DIR" >/dev/null 2>&1 || true

echo "Pushing archive to device /sdcard/_restore_nvdata.tar.gz"
$ADB -s "$DEVICE" push "$ARCHIVE" /sdcard/_restore_nvdata.tar.gz >/dev/null

echo "Applying restore..."
$ADB -s "$DEVICE" shell su -c 'rm -rf /mnt/vendor/nvdata.new && mkdir /mnt/vendor/nvdata.new'
$ADB -s "$DEVICE" shell su -c 'cd /mnt/vendor/nvdata.new && tar -xzf /sdcard/_restore_nvdata.tar.gz --strip-components=1 || exit 1'
$ADB -s "$DEVICE" shell su -c 'chown -R root:system /mnt/vendor/nvdata.new; find /mnt/vendor/nvdata.new -type d -exec chmod 771 {} \; ; find /mnt/vendor/nvdata.new -type f -exec chmod 660 {} \;'
$ADB -s "$DEVICE" shell su -c 'mv /mnt/vendor/nvdata /mnt/vendor/nvdata.prev_$((RANDOM)) && mv /mnt/vendor/nvdata.new /mnt/vendor/nvdata'

echo "Reboot to load restored nvdata? (yes/NO)"
read -r rb
if [ "$rb" = "yes" ]; then
  $ADB -s "$DEVICE" shell reboot || true
  echo "Reboot issued."
else
  echo "Restore staged; reboot manually to apply."
fi

echo "Done."
