#!/usr/bin/env bash
# fetch-m0-kernel.sh <build-dir>
# Downloads the Firecracker CI guest kernel (stock Linux, virtio-net/blk/rng,
# 8250 console and initramfs support all built in - no modules) for the M0
# rehearsal. Alpine's linux-virt was tried first but ships virtio_net as a
# module, which would force Linux-only module files into the initramfs.
set -euo pipefail
BUILD=$1; mkdir -p "$BUILD"
VER=${M0_KERNEL_VERSION:-6.1.155}
BASE=https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.15/x86_64
OUT=$BUILD/vmlinux-m0
if [ ! -s "$OUT" ]; then
  curl -fsSL -o "$OUT.tmp" "$BASE/vmlinux-$VER" && mv "$OUT.tmp" "$OUT"
  curl -fsSL -o "$OUT.config" "$BASE/vmlinux-$VER.config" || true
fi
echo "linux $VER" > "$OUT.version"
ls -l "$OUT"
