# elixir_unikernel — build everything with `make`.
#
# Targets
#   make release      static x86-64 OTP + Elixir + mix release -> build/rootfs
#   make initramfs    cpio.gz of rootfs                        -> build/initramfs.cpio.gz
#   make m0-kernel    stock Linux (Firecracker CI build) for M0   -> build/vmlinux-m0
#   make run-m0       boot M0 under QEMU into IEx
#   make run-m0-app   boot M0 under QEMU into the app (-noshell)
#   make smoke-m0     non-interactive smoke test (app mode, probes)
#   make asterinas    build the Asterinas kernel with our initramfs
#   make run-m1       boot Asterinas into IEx
#   make smoke-m1     Asterinas smoke test
#   make sizes        print image sizes vs budget
#   make smoke        all of the above: release, both kernels, both smoke tests
#
# All compilation happens in linux/amd64 containers; the host only needs
# docker and qemu-system-x86_64.

OTP_TAG      ?= OTP-29.1.1
ELIXIR_TAG   ?= v1.20.4
ALPINE       ?= 3.22
# v0.18.1 cannot bind INADDR_ANY (EADDRNOTAVAIL); fixed on main after Aug 2026.
ASTERINAS_REF ?= 3d85cb4
JOBS         ?= 8

DOCKER       ?= docker
PLATFORM     ?= $(shell docker version -f "{{.Server.Os}}/{{.Server.Arch}}" 2>/dev/null || echo linux/amd64)
QEMU         ?= qemu-system-x86_64
# Measured floors (TCG, this image): Linux boots and passes all probes at 128M;
# Asterinas needs more: 192M is marginal (boot sometimes hangs), 256M is reliable
# (its kernel is linked at physical 128M, see RESEARCH.md).
M0_MEM       ?= 128M
M1_MEM       ?= 256M
QEMU_SMP     ?= 2
# Asterinas occasionally livelocks in the kernel (handle_pending_signal) while
# ERTS starts its threads; more vCPUs make it rare (1 CPU: always, 2: ~50%,
# 4: ~15%). The smoke test retries stalled boots. See docs/RESEARCH.md.
M1_SMP       ?= 4
QEMU_ACCEL   ?= $(shell if [ "$$(uname -s)" = Linux ] && [ -w /dev/kvm ]; then echo kvm; else echo tcg; fi)

BUILD        := build
ROOTFS       := $(BUILD)/rootfs
INITRAMFS    := $(BUILD)/initramfs.cpio.gz
TLS_HOST     ?= www.erlang.org
NET_ARGS     := uniapp.ip=10.0.2.15/24 uniapp.gw=10.0.2.2 uniapp.dns=10.0.2.3 uniapp.tls_host=$(TLS_HOST)

.PHONY: all release initramfs m0-kernel run-m0 run-m0-app smoke-m0 asterinas run-m1 run-m1-app smoke-m1 sizes clean builder-image smoke

all: initramfs

# Everything, end to end: release -> initramfs -> both kernels -> both smoke tests.
smoke: smoke-m0 smoke-m1 sizes

# ---------------------------------------------------------------- release
release:
	rm -rf $(ROOTFS) && mkdir -p $(ROOTFS)
	$(DOCKER) buildx build --platform $(PLATFORM) \
	  --build-arg OTP_TAG=$(OTP_TAG) --build-arg ELIXIR_TAG=$(ELIXIR_TAG) \
	  --build-arg ALPINE_VERSION=$(ALPINE) --build-arg JOBS=$(JOBS) \
	  --target out --output type=local,dest=$(BUILD)/out -f builder/Dockerfile .
	scripts/assemble-rootfs.sh $(BUILD)/out $(ROOTFS)

initramfs: $(INITRAMFS)
$(INITRAMFS): $(ROOTFS)/init
	scripts/mkinitramfs.sh $(ROOTFS) $@
	@ls -l $@

$(ROOTFS)/init:
	$(MAKE) release

# ---------------------------------------------------------------- M0: stock Linux
m0-kernel: $(BUILD)/vmlinux-m0
$(BUILD)/vmlinux-m0:
	scripts/fetch-m0-kernel.sh $(BUILD)

# -cpu Icelake-Server: Asterinas requires x2APIC and a modern CPU model; works for Linux too.
# disable-legacy=on: Asterinas only speaks modern virtio (also fine for Linux).
QEMU_BASE = $(QEMU) -machine q35,kernel-irqchip=split,accel=$(QEMU_ACCEL) -cpu Icelake-Server,+x2apic \
  -nographic -no-reboot \
  -netdev user,id=n0,hostfwd=tcp::4000-:4000,hostfwd=udp::4001-:4001,hostfwd=tcp::4443-:4443 \
  -device virtio-net-pci,netdev=n0,disable-legacy=on,disable-modern=off \
  -device virtio-rng-pci,disable-legacy=on,disable-modern=off \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04

M0_CMDLINE = console=ttyS0 quiet loglevel=3 rdinit=/init $(NET_ARGS)

run-m0: $(INITRAMFS) $(BUILD)/vmlinux-m0
	$(QEMU_BASE) -smp $(QEMU_SMP) -m $(M0_MEM) -kernel $(BUILD)/vmlinux-m0 -initrd $(INITRAMFS) -append "$(M0_CMDLINE) uniapp.mode=iex"

run-m0-app: $(INITRAMFS) $(BUILD)/vmlinux-m0
	$(QEMU_BASE) -smp $(QEMU_SMP) -m $(M0_MEM) -kernel $(BUILD)/vmlinux-m0 -initrd $(INITRAMFS) -append "$(M0_CMDLINE) uniapp.mode=app"

smoke-m0: $(INITRAMFS) $(BUILD)/vmlinux-m0
	scripts/smoke.sh m0 "$(QEMU_BASE) -smp $(QEMU_SMP) -m $(M0_MEM) -kernel $(BUILD)/vmlinux-m0 -initrd $(INITRAMFS)" "$(M0_CMDLINE)"

# ---------------------------------------------------------------- M1: Asterinas
asterinas: $(BUILD)/asterinas/aster-nix-osdk-bin
$(BUILD)/asterinas/aster-nix-osdk-bin: scripts/build-asterinas.sh $(wildcard builder/asterinas-patches/*.patch) | $(INITRAMFS)
	scripts/build-asterinas.sh $(ASTERINAS_REF) $(abspath $(INITRAMFS)) $(abspath $(BUILD))

M1_CMDLINE = console=ttyS0 earlycon loglevel=error $(NET_ARGS)

run-m1: asterinas
	$(QEMU_BASE) -smp $(M1_SMP) -m $(M1_MEM) -kernel $(BUILD)/asterinas/aster-nix-osdk-bin -initrd $(INITRAMFS) -append "$(M1_CMDLINE) uniapp.mode=iex"

run-m1-app: asterinas
	$(QEMU_BASE) -smp $(M1_SMP) -m $(M1_MEM) -kernel $(BUILD)/asterinas/aster-nix-osdk-bin -initrd $(INITRAMFS) -append "$(M1_CMDLINE) uniapp.mode=app"

smoke-m1: asterinas
	scripts/smoke.sh m1 "$(QEMU_BASE) -smp $(M1_SMP) -m $(M1_MEM) -kernel $(BUILD)/asterinas/aster-nix-osdk-bin -initrd $(INITRAMFS)" "$(M1_CMDLINE)"

# ---------------------------------------------------------------- misc
sizes: $(INITRAMFS)
	@scripts/sizes.sh $(BUILD)

clean:
	rm -rf $(BUILD)
