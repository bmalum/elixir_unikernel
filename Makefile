# elixir_unikernel: build, boot and test with `make`.
# Run `make help` for the target list. Everything compiles inside Docker
# containers; the host needs docker (buildx), qemu-system-x86_64 and make.

VERSION      := $(shell cat VERSION)
OTP_TAG      ?= OTP-29.1.1
ELIXIR_TAG   ?= v1.20.4
ALPINE       ?= 3.22
# v0.18.1 cannot bind INADDR_ANY (EADDRNOTAVAIL); fixed on main after Aug 2026.
ASTERINAS_REF ?= 3d85cb4
JOBS         ?= 8

DOCKER       ?= docker
PLATFORM     ?= $(shell docker version -f "{{.Server.Os}}/{{.Server.Arch}}" 2>/dev/null || echo linux/amd64)
QEMU         ?= qemu-system-x86_64
# Measured floors (TCG, this image): Linux passes all probes at 128M; Asterinas
# at 144M (its kernel is loaded at physical 128M, so 128M is impossible by
# construction, see docs/book/src/reference/limits.md). 160M leaves some margin.
M0_MEM       ?= 128M
M1_MEM       ?= 160M
QEMU_SMP     ?= 2
M1_SMP       ?= 2
QEMU_ACCEL   ?= $(shell if [ "$$(uname -s)" = Linux ] && [ -w /dev/kvm ]; then echo kvm; else echo tcg; fi)

BUILD        := build
ROOTFS       := $(BUILD)/rootfs
INITRAMFS    := $(BUILD)/initramfs.cpio.gz
KERNEL_M1    := $(BUILD)/asterinas/aster-nix-osdk-bin
TLS_HOST     ?= www.erlang.org
# Both kernels obtain the address via DHCP from QEMU's user-mode network:
# Linux through the client in /init, Asterinas through the in-kernel client
# enabled by `ip=dhcp` (patch 0004). Pass uniapp.ip=/gw=/dns= for static setup.
NET_ARGS     := uniapp.tls_host=$(TLS_HOST)

# Host-side ports forwarded to the guest's echo servers (tcp 4000, udp 4001, tls 4443).
# High numbers so a developer's local `iex -S mix` on 4000 never collides with the smoke test.
HOST_PORT_TCP ?= 14000
HOST_PORT_UDP ?= 14001
HOST_PORT_TLS ?= 14443
export HOST_PORT_TCP HOST_PORT_UDP HOST_PORT_TLS

.DEFAULT_GOAL := help
.PHONY: help check all release initramfs m0-kernel run-m0 run-m0-app smoke-m0 \
        asterinas run-m1 run-m1-app smoke-m1 smoke sizes dist docs docs-serve site clean \
        ami run-disk smoke-disk

## help:        list targets
help:
	@echo "elixir_unikernel $(VERSION)  (OTP $(OTP_TAG), Elixir $(ELIXIR_TAG), Asterinas $(ASTERINAS_REF))"
	@echo
	@grep -E '^## [a-z0-9-]+:' $(MAKEFILE_LIST) | sed -E 's/^## /  /' | sort
	@echo
	@echo "Variables (override with make VAR=value): M1_MEM=$(M1_MEM) M1_SMP=$(M1_SMP) QEMU_ACCEL=$(QEMU_ACCEL) TLS_HOST=$(TLS_HOST)"
	@echo "Manual: docs/book  (make docs; or https://<pages-url>/book/)"

## check:       verify host prerequisites (docker buildx, qemu, make, coreutils)
check:
	@scripts/check-prereqs.sh

## all:         build the initramfs (release + rootfs + cpio)
all: initramfs

## smoke:       everything end to end: release, both kernels, both smoke tests, sizes
smoke: smoke-m0 smoke-m1 sizes

# ---------------------------------------------------------------- release
## release:     static x86-64 OTP + Elixir + mix release        -> build/rootfs
release:
	rm -rf $(ROOTFS) && mkdir -p $(ROOTFS)
	$(DOCKER) buildx build --platform $(PLATFORM) \
	  --build-arg OTP_TAG=$(OTP_TAG) --build-arg ELIXIR_TAG=$(ELIXIR_TAG) \
	  --build-arg ALPINE_VERSION=$(ALPINE) --build-arg JOBS=$(JOBS) \
	  --target out --output type=local,dest=$(BUILD)/out -f builder/Dockerfile .
	scripts/assemble-rootfs.sh $(BUILD)/out $(ROOTFS)

## initramfs:   gzip cpio of the rootfs                          -> build/initramfs.cpio.gz
initramfs: $(INITRAMFS)
$(INITRAMFS): $(ROOTFS)/init
	scripts/mkinitramfs.sh $(ROOTFS) $@
	@ls -l $@

$(ROOTFS)/init:
	$(MAKE) release

# ---------------------------------------------------------------- M0: stock Linux
## m0-kernel:   fetch the stock Linux reference kernel         -> build/vmlinux-m0
m0-kernel: $(BUILD)/vmlinux-m0
$(BUILD)/vmlinux-m0:
	scripts/fetch-m0-kernel.sh $(BUILD)

# -cpu Icelake-Server: Asterinas requires x2APIC and a modern CPU model; works for Linux too.
# disable-legacy=on: Asterinas only speaks modern virtio (also fine for Linux).
QEMU_BASE = $(QEMU) -machine q35,kernel-irqchip=split,accel=$(QEMU_ACCEL) -cpu Icelake-Server,+x2apic \
  -nographic -no-reboot \
  -netdev user,id=n0,hostfwd=tcp::$(HOST_PORT_TCP)-:4000,hostfwd=udp::$(HOST_PORT_UDP)-:4001,hostfwd=tcp::$(HOST_PORT_TLS)-:4443 \
  -device virtio-net-pci,netdev=n0,disable-legacy=on,disable-modern=off \
  -device virtio-rng-pci,disable-legacy=on,disable-modern=off \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04

M0_CMDLINE = console=ttyS0 quiet loglevel=3 rdinit=/init $(NET_ARGS)
## ec2-kernel:  build Linux 6.1 with ENA/NVMe/EFI for the Linux AMI  -> build/vmlinux-ec2
ec2-kernel: $(BUILD)/vmlinux-ec2
$(BUILD)/vmlinux-ec2: scripts/build-linux-ec2.sh $(BUILD)/vmlinux-m0
	scripts/build-linux-ec2.sh $(BUILD)

QEMU_M0 = $(QEMU_BASE) -smp $(QEMU_SMP) -m $(M0_MEM) -kernel $(BUILD)/vmlinux-m0 -initrd $(INITRAMFS)

## run-m0:      boot on Linux into IEx (exit QEMU: Ctrl-a x)
run-m0: $(INITRAMFS) $(BUILD)/vmlinux-m0
	$(QEMU_M0) -append "$(M0_CMDLINE) uniapp.mode=iex"

## run-m0-app:  boot on Linux into the application (no shell)
run-m0-app: $(INITRAMFS) $(BUILD)/vmlinux-m0
	$(QEMU_M0) -append "$(M0_CMDLINE) uniapp.mode=app"

## smoke-m0:    automated assertions on Linux
smoke-m0: $(INITRAMFS) $(BUILD)/vmlinux-m0
	scripts/smoke.sh m0 "$(QEMU_M0)" "$(M0_CMDLINE)"

# ---------------------------------------------------------------- M1: Asterinas
## asterinas:   build the Asterinas kernel (+ local patches)    -> build/asterinas/
asterinas: $(KERNEL_M1)
$(KERNEL_M1): scripts/build-asterinas.sh $(wildcard builder/asterinas-patches/*.patch) | $(INITRAMFS)
	scripts/build-asterinas.sh $(ASTERINAS_REF) $(abspath $(INITRAMFS)) $(abspath $(BUILD))

M1_CMDLINE = console=ttyS0 earlycon loglevel=error ip=dhcp $(NET_ARGS)
QEMU_M1 = $(QEMU_BASE) -smp $(M1_SMP) -m $(M1_MEM) -kernel $(KERNEL_M1) -initrd $(INITRAMFS)

## run-m1:      boot on Asterinas into IEx (exit QEMU: Ctrl-a x)
run-m1: asterinas
	$(QEMU_M1) -append "$(M1_CMDLINE) uniapp.mode=iex"

## run-m1-app:  boot on Asterinas into the application (no shell)
run-m1-app: asterinas
	$(QEMU_M1) -append "$(M1_CMDLINE) uniapp.mode=app"

## smoke-m1:    automated assertions on Asterinas
smoke-m1: asterinas
	scripts/smoke.sh m1 "$(QEMU_M1)" "$(M1_CMDLINE)"

# ---------------------------------------------------------------- disk image (EC2 / UEFI)
# KERNEL=asterinas (default) or KERNEL=linux (reference kernel with ENA+NVMe).
KERNEL      ?= asterinas
# DISK_MODE=app|iex is baked into the image (an EC2 instance has no -append).
DISK_MODE   ?= app
DISK        := $(BUILD)/disk-$(KERNEL)$(if $(filter-out app,$(DISK_MODE)),-$(DISK_MODE),).raw
OVMF        ?= $(firstword $(wildcard /opt/homebrew/share/qemu/edk2-x86_64-code.fd /usr/share/qemu/edk2-x86_64-code.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd))
DISK_CMDLINE_asterinas = console=ttyS0 earlycon loglevel=$(DISK_LOGLEVEL) ip=dhcp
DISK_CMDLINE_linux     = console=ttyS0 quiet loglevel=3 rdinit=/init
DISK_KERNEL_asterinas  = $(KERNEL_M1)
DISK_KERNEL_linux      = $(BUILD)/vmlinux-ec2

## ami:         UEFI/GPT disk image with GRUB, kernel and initramfs -> build/disk-<KERNEL>.raw
ami: $(DISK)
$(DISK): $(INITRAMFS) $(DISK_KERNEL_$(KERNEL)) scripts/mkdisk.sh
	DISK_MB=1024 ESP_MB=94 KERNEL_KIND=$(KERNEL) scripts/mkdisk.sh $(DISK_KERNEL_$(KERNEL)) $(INITRAMFS) $@ "$(DISK_CMDLINE_$(KERNEL)) $(NET_ARGS) uniapp.mode=$(DISK_MODE)"

# A copy is booted so QEMU's firmware never writes into the artefact.
# GRUB needs room for kernel + initramfs + the multiboot2 copy below the kernel's
# 128 MB load address: "error: out of memory" at 160M, fine at 256M. EC2's smallest
# instances have 512 MB+ anyway.
DISK_MEM    ?= 256M
# Asterinas log level baked into the disk image. `info` logs every syscall and
# overflows the 64 KB EC2 console buffer within seconds; keep `error` for images.
DISK_LOGLEVEL ?= error
QEMU_DISK = $(QEMU_BASE) -smp $(M1_SMP) -m $(DISK_MEM) \
  -drive if=pflash,format=raw,readonly=on,file=$(OVMF) \
  -drive if=none,id=d0,format=raw,file=$(BUILD)/disk-boot.raw -device nvme,drive=d0,serial=eu0001

## run-disk:    boot the disk image in QEMU (UEFI + NVMe), app mode
run-disk: $(DISK)
	@test -n "$(OVMF)" || { echo "OVMF firmware not found; set OVMF=/path/to/edk2-x86_64-code.fd"; exit 1; }
	cp $(DISK) $(BUILD)/disk-boot.raw
	$(QEMU_DISK)

## smoke-disk:  smoke test of the disk image (UEFI + NVMe); mode is baked into the image, so
##              the script rebuilds it per mode
smoke-disk: $(INITRAMFS) $(DISK_KERNEL_$(KERNEL))
	@test -n "$(OVMF)" || { echo "OVMF firmware not found; set OVMF=..."; exit 1; }
	KERNEL_KIND=$(KERNEL) SMOKE_DISK=1 scripts/smoke.sh disk-$(KERNEL) "$(QEMU_DISK)" "$(DISK_CMDLINE_$(KERNEL)) $(NET_ARGS)" \
	  "scripts/mkdisk.sh $(DISK_KERNEL_$(KERNEL)) $(INITRAMFS) $(BUILD)/disk-boot.raw"

# EC2. Credentials and region come from the environment (AWS_PROFILE, AWS_REGION).
AMI_NAME = elixir_unikernel-$(VERSION)-$(KERNEL)$(if $(filter-out app,$(DISK_MODE)),-$(DISK_MODE),)
## ami-publish: upload build/disk-$(KERNEL).raw as an AMI (EBS direct API, ~15 s); prints the id
ami-publish: $(DISK)
	scripts/ami-publish.py $(DISK) --name $(AMI_NAME) --version $(VERSION) --kernel $(KERNEL) $(AMI_FLAGS)

## smoke-ec2:   publish (or reuse) the AMI, boot a t3.small, run the assertions, terminate
smoke-ec2: $(DISK)
	scripts/smoke-ec2.sh $$(scripts/ami-publish.py $(DISK) --name $(AMI_NAME) --version $(VERSION) --kernel $(KERNEL) $(AMI_FLAGS)) $(KERNEL)

## ami-clean:   deregister this version's AMIs and delete their snapshots (both kernels)
ami-clean:
	@for k in linux asterinas; do \
	  for ami in $$(aws ec2 describe-images --owners self --filters Name=name,Values=elixir_unikernel-$(VERSION)-$$k --query 'Images[].ImageId' --output text); do \
	    snaps=$$(aws ec2 describe-images --image-ids $$ami --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text); \
	    aws ec2 deregister-image --image-id $$ami && echo "deregistered $$ami"; \
	    for s in $$snaps; do aws ec2 delete-snapshot --snapshot-id $$s && echo "deleted $$s"; done; \
	  done; \
	done

# ---------------------------------------------------------------- dist, docs, misc
## sizes:       print image sizes against the 40 MB budget
sizes: $(INITRAMFS)
	@scripts/sizes.sh $(BUILD)

## dist:        versioned bundle (kernel, initramfs, run.sh, SHA256SUMS) -> dist/
dist: $(INITRAMFS) $(KERNEL_M1)
	scripts/dist.sh $(VERSION) $(BUILD) dist

## docs:        build the manual with mdBook (Docker)          -> build/book/
docs:
	$(DOCKER) run --rm -v "$(CURDIR)":/repo -w /repo/docs/book peaceiris/mdbook:v0.5.0 build -d /repo/build/book
	@echo "open build/book/index.html"

## docs-serve:  serve the manual on http://localhost:3000 with live reload
docs-serve:
	$(DOCKER) run --rm -it -p 3000:3000 -v "$(CURDIR)":/repo -w /repo/docs/book peaceiris/mdbook:v0.5.0 serve -n 0.0.0.0

## site:        assemble the website (landing page + manual)   -> build/site/
site: docs
	@test -n "$(BUILD)" && test "$(BUILD)/site" != "site"   # never touch the source dir
	rm -rf $(BUILD)/site && mkdir -p $(BUILD)/site
	cp -R site/. $(BUILD)/site/
	cp -R $(BUILD)/book $(BUILD)/site/book
	@echo "open build/site/index.html"

## clean:       remove build/ and dist/
clean:
	rm -rf $(BUILD) dist
