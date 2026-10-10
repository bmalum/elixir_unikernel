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
- `scripts/ami-publish.py`, `scripts/smoke-ec2.sh`, `scripts/ec2-console.sh`,
  `scripts/smoke-ec2-iex.sh` (IEx over the EC2 Serial Console) and
  `make ami-publish / smoke-ec2 / ami-clean`; `DISK_MODE=iex` images.
- Manual chapter "Running on EC2"; ENA driver notes in the patches chapter.

### Fixed
- `scripts/build-asterinas.sh` aborts when a patch does not apply and
  cleans stale untracked files first; previously it built silently without
  the failed patches.

- `/init` is now a supervisor: it forks `beam.smp`, reaps orphans and on exit
  reboots (or powers off/halts, `uniapp.on_exit=`) the machine, so a crashed
  node restarts instead of hanging.
- `/init` reads EC2 instance metadata and user data (`uniapp.imds=1`);
  user-data `key=value` lines override the kernel command line. Identity in
  `EC2_*`/`AWS_REGION`, raw user data in `/run/user-data`.
- SNTP in `/init` (`uniapp.ntp=`, Amazon Time Sync by default on EC2): the
  clock is set at boot and resynced hourly.
- Data volume: `uniapp.data=auto` mounts an ext2 EBS volume at `/data`
  (`UNIAPP_DATA`, `erl_crash.dump` there); `scripts/mkdata.sh` builds the
  image, `scripts/ami-publish.py --snapshot-only` publishes it.
- Sample app: `Uniapp.Cloudwatch` ships the log to CloudWatch Logs and
  publishes EMF metrics (`BootCount`, `Uptime`, `MemoryTotal`,
  `ProcessCount`) with SigV4 and instance-role credentials; `Uniapp.Data`
  keeps a boot counter on `/data`.
- Asterinas patch 0006: `reboot(2)` resets the machine on Nitro (triple
  fault fallback), `poweroff` falls back to reset, `clock_settime` and
  `settimeofday` implemented.
- Asterinas patch 0007: NVMe honours `CAP.MQES` and issues Set Features
  (Number of Queues), so EBS volumes work.
- `scripts/smoke-ec2.sh` with `DATA_SNAPSHOT`: IAM role, data volume, user
  data, guest-initiated reboot, boot counter and CloudWatch assertions, then
  timed `aws ec2 reboot-instances` and `stop-instances` (23 in total);
  `make smoke-ec2` wires it up.
- Asterinas patch 0008: ACPI power button (polled `PM1_STS`, delivered as
  `SIGPWR` to PID 1) and S5 power-off from the `_S5` package found in the
  DSDT/SSDTs. `aws ec2 stop-instances` now stops in about 15 s and
  `reboot-instances` reboots in about 45 s instead of EC2's 4-minute hard
  reset. `/init` handles `SIGPWR` (Asterinas) and `KEY_POWER` on evdev
  (Linux) by stopping the VM with `SIGTERM` and powering off; the Linux EC2
  kernel gains `ACPI_BUTTON`.

- Sample app: `Uniapp.Health` serves `/healthz` (503 until ready, then 200
  with JSON details) and `/livez` on 8080 for ALB/ASG health checks, and a
  throughput self-test (`BENCH`), also against a peer (`uniapp.bench_peer`).
- Asterinas patch 0009: ENA AENQ handling with keep-alive watchdog and a
  device reset path, TCP/UDP checksum offload, multiple queue pairs with
  RSS (`ena.queues=`, default one pair per vCPU; Tx steered by flow hash so
  a connection stays on one queue), and health work moved out of the timer
  interrupt.
  `scripts/bench-ec2.sh` measures NIC to NIC: 77 to 108 MB/s round trip
  between two t3.small.
- `scripts/smoke-ec2.sh`: health endpoint, BENCH/BULK, ENA ready and
  keep-alive assertions (29 in total); `QUICK=1` short mode.

### Changed
- `make run-*`/`smoke-*` no longer pass `uniapp.ip=`; both kernels use DHCP.
- `/init` no longer `exec`s `beam.smp`; the VM runs as PID 2 under the
  supervisor. `ERL_CRASH_DUMP` points to `/data` when a volume is mounted.

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
