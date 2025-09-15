#!/usr/bin/env bash
set -euo pipefail

# diff_nvdata.sh - Structural & hash diff of two nvdata tar.gz archives
# Usage: ./toolkit/diff_nvdata.sh <a.tar.gz> <b.tar.gz>

A="$1" 2>/dev/null || { echo "Usage: $0 <a.tar.gz> <b.tar.gz>" >&2; exit 1; }
B="$2" 2>/dev/null || { echo "Usage: $0 <a.tar.gz> <b.tar.gz>" >&2; exit 1; }

[ -f "$A" ] || { echo "File not found: $A" >&2; exit 1; }
[ -f "$B" ] || { echo "File not found: $B" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

extract(){
  local src=$1 dest=$2
  mkdir -p "$dest"
  tar -xzf "$src" -C "$dest" >/dev/null 2>&1 || true
}

extract "$A" "$TMP/a"
extract "$B" "$TMP/b"

echo "--- File Presence Diff (A vs B) ---"
comm -3 <(cd "$TMP/a" && find . -type f -print | sort) <(cd "$TMP/b" && find . -type f -print | sort) | sed 's/^\t/   ONLY_B /;s/^/ONLY_A /'

echo "--- Hash & Size Differences (common files) ---"
common=$(comm -12 <(cd "$TMP/a" && find . -type f -print | sort) <(cd "$TMP/b" && find . -type f -print | sort))
diff_found=0
while IFS= read -r f; do
  ha=$(sha256sum "$TMP/a/$f" | awk '{print $1}')
  hb=$(sha256sum "$TMP/b/$f" | awk '{print $1}')
  sa=$(stat -c %s "$TMP/a/$f")
  sb=$(stat -c %s "$TMP/b/$f")
  if [ "$ha" != "$hb" ] || [ "$sa" != "$sb" ]; then
    echo "DIFF $f sizeA=$sa sizeB=$sb hashA=$ha hashB=$hb"
    diff_found=1
  fi
done <<< "$common"

if [ $diff_found -eq 0 ]; then
  echo "No content diffs in common files."
fi

echo "--- Summary ---"
countA=$(find "$TMP/a" -type f | wc -l | tr -d ' ')
countB=$(find "$TMP/b" -type f | wc -l | tr -d ' ')
echo "Files A: $countA | Files B: $countB"
