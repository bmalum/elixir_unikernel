#!/usr/bin/env bash
# build-linux-ec2.sh <build-dir>
# Builds a Linux bzImage for the EC2 reference AMI: the Firecracker CI config
# (known to boot our image) plus ENA, NVMe and the EFI stub, all built in, no
# modules. Cross-compiled for x86-64 with LLVM inside a native Alpine
# container (works on arm64 and x86-64 hosts). Output: <build-dir>/vmlinux-ec2
# (a bzImage despite the name, for the Makefile's KERNEL=linux path) and
# <build-dir>/vmlinux-ec2.config.
set -euo pipefail
BUILD=$(mkdir -p "$1" && cd "$1" && pwd)
VER=${LINUX_VERSION:-6.1.155}
SRC=$BUILD/linux-src; mkdir -p "$SRC"
BASECFG=$BUILD/vmlinux-m0.config
[ -f "$BASECFG" ] || scripts/fetch-m0-kernel.sh "$BUILD" >/dev/null

if [ ! -f "$SRC/linux-$VER/Makefile" ]; then
  echo "fetching linux-$VER"
  curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.xz" | tar xJ -C "$SRC"
fi

cat > "$BUILD/linux-ec2.fragment" <<'EOF'
# EC2 Nitro hardware
CONFIG_ETHERNET=y
CONFIG_NET_VENDOR_AMAZON=y
CONFIG_ENA_ETHERNET=y
CONFIG_BLK_DEV_NVME=y
CONFIG_NVME_CORE=y
CONFIG_PCI_MSI=y
# UEFI boot via GRUB's linux command / EFI stub
CONFIG_EFI=y
CONFIG_EFI_STUB=y
CONFIG_EFI_PARTITION=y
# keep it quiet and small
CONFIG_RANDOMIZE_BASE=n
# CONFIG_DEBUG_INFO is not set
EOF

docker run --rm -v "$BUILD":/b -w /b/linux-src/linux-$VER alpine:3.22 sh -ec '
  apk add --no-cache clang lld llvm make bison flex bc elfutils-dev openssl-dev perl python3 linux-headers musl-dev gcc rsync >/dev/null 2>&1
  export ARCH=x86_64 LLVM=1 LLVM_IAS=1 KCFLAGS=-Wno-error
  cp /b/vmlinux-m0.config .config
  scripts/kconfig/merge_config.sh -m .config /b/linux-ec2.fragment >/dev/null
  make olddefconfig >/dev/null
  for k in ENA_ETHERNET BLK_DEV_NVME EFI_STUB VIRTIO_NET SERIAL_8250_CONSOLE; do grep -q "^CONFIG_$k=y" .config || { echo "CONFIG_$k not enabled"; exit 1; }; done
  make -j'"${JOBS:-8}"' bzImage 2>&1 | grep -E "error|Error|warning: unmet|bzImage" | grep -v "^  " | tail -5
  cp arch/x86/boot/bzImage /b/vmlinux-ec2
  cp .config /b/vmlinux-ec2.config
  ls -l /b/vmlinux-ec2
'
echo "linux $VER (firecracker config + ENA/NVMe/EFI)" > "$BUILD/vmlinux-ec2.version"
