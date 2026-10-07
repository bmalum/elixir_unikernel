#!/usr/bin/env bash
# dist.sh <version> <build-dir> <dist-dir>
# Packages a release bundle:
#   dist/elixir_unikernel-<version>-x86_64/
#     asterinas.elf          Rust kernel (multiboot ELF for QEMU -kernel)
#     initramfs.cpio.gz      the Elixir image
#     run.sh                 boots it with QEMU (iex or app mode)
#     SHA256SUMS, VERSIONS, LICENSE-NOTICE
#   dist/elixir_unikernel-<version>-x86_64.tar.gz
set -euo pipefail
VERSION=$1; BUILD=$2; DIST=$3
NAME=elixir_unikernel-$VERSION-x86_64
OUT=$DIST/$NAME
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$BUILD/asterinas/aster-nix-osdk-bin" "$OUT/asterinas.elf"
cp "$BUILD/initramfs.cpio.gz" "$OUT/initramfs.cpio.gz"
cp NOTICE "$OUT/LICENSE-NOTICE"
{
  echo "elixir_unikernel $VERSION"
  echo "erts $(cat "$BUILD/out/ERTS_VSN" 2>/dev/null || echo unknown)"
  grep -E '^(OTP_TAG|ELIXIR_TAG|ASTERINAS_REF|ALPINE) ' Makefile | sed -E 's/ *\?= */ /'
  echo "asterinas-patches $(ls builder/asterinas-patches/*.patch 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/VERSIONS"
cat > "$OUT/run.sh" <<'RUN'
#!/usr/bin/env sh
# run.sh [iex|app] [extra kernel args...]
# Boots the image with QEMU. Needs qemu-system-x86_64; uses KVM when /dev/kvm is writable.
cd "$(dirname "$0")"
MODE=${1:-iex}; shift 2>/dev/null || true
ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
exec qemu-system-x86_64 \
  -machine q35,kernel-irqchip=split,accel=$ACCEL -cpu Icelake-Server,+x2apic \
  -m "${MEM:-160M}" -smp "${SMP:-2}" -nographic -no-reboot \
  -netdev user,id=n0,hostfwd=tcp::14000-:4000,hostfwd=udp::14001-:4001,hostfwd=tcp::14443-:4443 \
  -device virtio-net-pci,netdev=n0,disable-legacy=on,disable-modern=off \
  -device virtio-rng-pci,disable-legacy=on,disable-modern=off \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  -kernel asterinas.elf -initrd initramfs.cpio.gz \
  -append "console=ttyS0 earlycon loglevel=error uniapp.ip=10.0.2.15/24 uniapp.gw=10.0.2.2 uniapp.dns=10.0.2.3 uniapp.mode=$MODE $*"
RUN
chmod +x "$OUT/run.sh"
( cd "$OUT" && files=$(ls | grep -v SHA256SUMS) && (sha256sum $files 2>/dev/null || shasum -a 256 $files) > SHA256SUMS )
( cd "$DIST" && tar czf "$NAME.tar.gz" "$NAME" )
ls -l "$OUT" "$DIST/$NAME.tar.gz"
