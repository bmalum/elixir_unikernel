#!/usr/bin/env bash
set -euo pipefail
B=$1
budget=$((40*1024*1024))
total=0
for f in "$B"/initramfs.cpio.gz "$B"/vmlinux-m0 "$B"/asterinas/aster-nix-osdk-bin; do
  [ -f "$f" ] || continue
  s=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
  printf '%10d  %s\n' "$s" "$f"
done
ir=$(stat -f%z "$B/initramfs.cpio.gz" 2>/dev/null || stat -c%s "$B/initramfs.cpio.gz")
k=0; [ -f "$B/asterinas/aster-nix-osdk-bin" ] && k=$(stat -f%z "$B/asterinas/aster-nix-osdk-bin" 2>/dev/null || stat -c%s "$B/asterinas/aster-nix-osdk-bin")
total=$((ir+k))
printf 'initramfs + asterinas kernel: %d bytes (%.1f MB), budget 40 MB -> %s\n' "$total" "$(echo "$total/1048576" | bc -l)" "$([ $total -le $budget ] && echo OK || echo OVER)"
