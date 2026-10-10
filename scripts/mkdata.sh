#!/usr/bin/env bash
# Create an empty ext2 data volume image for the guest's /data.
#
#   scripts/mkdata.sh <out.raw> [size_mb] [label]      (default 64, uniapp-data)
#
# Mount by label from the guest with uniapp.data=LABEL=<label> or
# uniapp.mounts=LABEL=<label>:/dir. Growing a volume: ext2 has no online
# resize and the image has no resize2fs; make a bigger image, copy the data
# over inside the guest (or on a Linux box with both attached), swap volumes.
#
# ext2 because that is what the Asterinas kernel mounts read-write (its ext2
# driver is the one it runs its own tests on); Linux mounts it too. No journal
# means an unclean power-off can lose the last writes; the app writes small
# files and calls fsync, which is what the volume is for (boot counters, crash
# dumps, caches). Runs mkfs in a Linux container because macOS has no mkfs.ext2.
set -euo pipefail
OUT=$1; MB=${2:-64}; LABEL=${3:-uniapp-data}
WORK=$(dirname "$OUT")/.mkdata; mkdir -p "$WORK"
docker run --rm --platform linux/amd64 -v "$(cd "$(dirname "$OUT")" && pwd)":/out -w /out alpine:3.22 sh -ec '
  apk add --no-cache e2fsprogs >/dev/null 2>&1
  rm -f "/out/'"$(basename "$OUT")"'"
  truncate -s '"$MB"'M "/out/'"$(basename "$OUT")"'"
  # 4096-byte blocks (the only size Asterinas ext2 mounts); features limited to
  # what it accepts: filetype, sparse_super, large_file.
  mkfs.ext2 -q -F -b 4096 -L '"$LABEL"' -O ^dir_index,^resize_inode,^ext_attr "/out/'"$(basename "$OUT")"'"
  dumpe2fs -h "/out/'"$(basename "$OUT")"'" 2>/dev/null | grep -E "volume name|Block count|Features"
'
rmdir "$WORK" 2>/dev/null || true
echo "data volume: $OUT (${MB} MB, ext2, label $LABEL)"
