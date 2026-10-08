All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

Work towards running on EC2 (docs/GOALS-EC2.md).

### Added
- `scripts/mkdisk.sh` and `make ami`: a GPT disk image with an EFI system
  partition (GRUB, kernel, initramfs) that boots via OVMF from an NVMe
  drive; `make smoke-disk` runs the assertions on it. `KERNEL=linux` builds
  the same image around a Linux kernel.
- `scripts/build-linux-ec2.sh`: Linux 6.1 with ENA, NVMe and EFI stub for
  the Linux-kernel AMI.
- DHCPv4 client in `/init` (Linux, `AF_PACKET`), used whenever `uniapp.ip=`
  is absent; falls back to the QEMU defaults.
- Asterinas patch 0003: `SIOCSIFADDR`, `SIOCSIFNETMASK`, `SIOCSIFFLAGS`,
  `SIOCADDRT`/`SIOCDELRT` so the address can be set at runtime.
- Asterinas patch 0004: in-kernel DHCPv4 client (`ip=dhcp`) with the lease
  published in `/proc/net/dhcp`.
- Asterinas patch 0005: `aster-ena`, a driver for the EC2 Elastic Network
  Adapter (one queue pair, MSI-X plus timer-tick polling, polled admin
  queue). The Asterinas image boots on a t3.small, gets its address from
  the VPC's DHCP, and passes the TCP, TLS 1.3, DNS and TLS-client checks
  from the internet.
- `scripts/ami-publish.py`, `scripts/smoke-ec2.sh`, `scripts/ec2-console.sh`
  and `make ami-publish / smoke-ec2 / ami-clean`.

### Changed
- `make run-*`/`smoke-*` no longer pass `uniapp.ip=`; both kernels use DHCP.

## [0.1.0] - 2026-10-07

First working release: milestones M0 (stock Linux), M1 (Asterinas) and M2
(TLS, size budget, CI) of GOALS.md.

### Added
- Static x86-64 Erlang/OTP 29.1.1 (`beam.smp` with OpenSSL 3.5, zlib, zstd
  and the `crypto`/`asn1` NIFs linked in) and Elixir 1.20.4, built natively
  with only ERTS cross-compiled; about 6 minutes cold.
- `/init`: a 300-line static C program replacing the release shell script,
  `erlexec` and an init system. Modes `iex`, `app`, `erl`; network, DNS and
  code-loading mode from the kernel command line.
- Sample release with TCP, UDP and TLS 1.3 echo servers and boot-time DNS and
  TLS client probes.
- Asterinas kernel build (`3d85cb4`, multiboot ELF) with two local patches:
  wildcard `bind()` and a `timerfd_settime` readiness fix.
- Stock Linux 6.1 reference kernel target for A/B debugging.
- `scripts/smoke.sh`: boots both modes on both kernels and asserts the
  GOALS.md criteria, including host-side TCP/UDP/TLS clients; GitHub Actions
  workflow running it.
- `make check`, `make dist` (versioned, checksummed bundle with `run.sh`),
  `make help`, `make docs`, `make site`.
- Manual (mdBook) and landing page, published to GitHub Pages.

### Measurements
- Image 9.4 MB, kernel 5.8 MB, total 15.2 MB (budget 40 MB).
- Runs with 128 MB RAM on Linux, 144 MB on Asterinas.
- Kernel entry to `/init` 0.45 s (Asterinas) / 1.0 s (Linux) under QEMU TCG;
  application start 3 to 4 s under TCG.

[Unreleased]: https://github.com/bmalum/elixir_unikernel/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bmalum/elixir_unikernel/releases/tag/v0.1.0
