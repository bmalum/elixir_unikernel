#!/usr/bin/env bash
# assemble-rootfs.sh <docker-out-dir> <rootfs-dir>
# Lays out the initramfs tree:
#   /init                      static C init
#   /rel/...                   mix release (pruned)
#   /etc/ssl/cacert.pem        CA bundle for :ssl verify_peer
#   /dev /proc /sys /tmp       mount points
set -euo pipefail
OUT=$1; ROOT=$2
rm -rf "$ROOT"; mkdir -p "$ROOT"/{dev,proc,sys,tmp,etc/ssl,rel}
cp "$OUT/init" "$ROOT/init"; chmod 755 "$ROOT/init"
cp -a "$OUT/release/." "$ROOT/rel/"
cp "$OUT/etc/ssl/cacert.pem" "$ROOT/etc/ssl/cacert.pem"
cp "$OUT/ERTS_VSN" "$ROOT/.erts_vsn" 2>/dev/null || true
# Belt and braces: nothing but init/beam.smp/erl_child_setup may be an ELF executable.
bad=$(find "$ROOT" -type f -perm -u+x -exec sh -c 'head -c4 "$1" | grep -q ELF && echo "$1"' _ {} \; \
      | grep -vE '/init$|/beam\.smp$|/erl_child_setup$' || true)
if [ -n "$bad" ]; then echo "unexpected ELF binaries in rootfs:"; echo "$bad"; exit 1; fi
echo "rootfs: $(du -sh "$ROOT" | cut -f1) in $ROOT"
