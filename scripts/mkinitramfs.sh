#!/usr/bin/env bash
# mkinitramfs.sh <rootfs-dir> <out.cpio.gz>
# newc cpio, gzip -9. Runs inside a container so ownership is root:root and
# the cpio implementation is GNU/busybox (macOS cpio lacks --owner).
set -euo pipefail
ROOT=$(cd "$1" && pwd); OUT=$2
mkdir -p "$(dirname "$OUT")"
docker run --rm --platform linux/amd64 -v "$ROOT":/rootfs:ro -v "$(cd "$(dirname "$OUT")" && pwd)":/out alpine:3.22 \
  sh -ec 'cd /rootfs && find . | sort | cpio --quiet -o -H newc -R 0:0 | gzip -9n > /out/'"$(basename "$OUT")"
