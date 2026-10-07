#!/usr/bin/env bash
# build-asterinas.sh <git-ref> <initramfs.cpio.gz> <build-dir>
#
# Builds the Asterinas kernel inside the upstream dev container with
#   cargo osdk build --release --boot-method qemu-direct --grub-boot-protocol multiboot
# which yields a multiboot ELF that plain QEMU boots with
# `-kernel <elf> -initrd <cpio.gz> -append "<cmdline>"`. (The bzImage/"linux"
# protocol variant did not produce any output under QEMU TCG on a Mac host;
# the multiboot ELF boots in <1 s guest time.)
# Output: <build-dir>/asterinas/aster-nix-osdk-bin
#
# The initramfs is not embedded; the upstream Makefile only needs *an*
# initramfs path to record in the OSDK bundle, so we point it at ours.
set -euo pipefail
REF=$1; INITRAMFS=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); BUILD=$3
SRC=$BUILD/asterinas-src
mkdir -p "$BUILD/asterinas"

if [ ! -d "$SRC/.git" ]; then
  git clone --filter=blob:none https://github.com/asterinas/asterinas.git "$SRC"
fi
git -C "$SRC" fetch -q origin "$REF" 2>/dev/null || git -C "$SRC" fetch -q origin
git -C "$SRC" checkout -q --detach "$REF" || git -C "$SRC" checkout -q --detach FETCH_HEAD
echo "asterinas at $(git -C "$SRC" log -1 --format='%h %ad %s' --date=short)"
DEV_IMAGE="asterinas/dev:$(cat "$SRC/DOCKER_IMAGE_VERSION")"
echo "asterinas $REF, dev image $DEV_IMAGE"

# Persist cargo registry/target between runs (the build is slow).
CACHE=$(mkdir -p "$BUILD/asterinas-cache" && cd "$BUILD/asterinas-cache" && pwd); mkdir -p "$CACHE/cargo-registry" "$CACHE/cargo-bin"

docker run --rm --platform linux/amd64 \
  -v "$(cd "$SRC" && pwd)":/root/asterinas \
  -v "$INITRAMFS":/root/asterinas/test/initramfs/build/initramfs.cpio.gz:ro \
  -v "$CACHE/cargo-registry":/root/.cargo/registry \
  -w /root/asterinas \
  -e RELEASE=1 -e BOOT_METHOD=qemu-direct -e BOOT_PROTOCOL=linux -e ENABLE_KVM=0 \
  -e INITRAMFS=on -e NETDEV=user \
  "$DEV_IMAGE" bash -ec '
    # The upstream "initramfs" target builds busybox/test suites; we bring our own.
    # Touch the marker so make does not rebuild it.
    mkdir -p test/initramfs/build
    make install_osdk 2>&1 | tail -3
    cd kernel && cargo osdk build --release --boot-method qemu-direct --grub-boot-protocol multiboot --strip-elf \
        --initramfs=/root/asterinas/test/initramfs/build/initramfs.cpio.gz \
        --kcmd-args="console=ttyS0" 2>&1 | tail -15
    ls -l /root/asterinas/target/osdk/asterinas/
  '
BIN=$SRC/target/osdk/asterinas/asterinas-osdk-bin.qemu_elf
[ -f "$BIN" ] || { echo "kernel binary not found: $BIN"; ls "$SRC/target/osdk/asterinas/"; exit 1; }
# OSDK already rewrote e_machine to EM_386 so QEMU accepts the 64-bit multiboot ELF.
python3 - "$BIN" <<'PY'
import sys; b=open(sys.argv[1],'rb').read(20); assert b[:4]==b'\x7fELF', "not an ELF"; print("e_machine =", b[18] | (b[19]<<8), "(3 = EM_386 patched for QEMU)")
PY
cp "$BIN" "$BUILD/asterinas/aster-nix-osdk-bin"
ls -l "$BUILD/asterinas/aster-nix-osdk-bin"; file "$BUILD/asterinas/aster-nix-osdk-bin" || true
