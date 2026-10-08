# Make targets and variables

`make help` prints this list from the Makefile itself.

## Targets

| Target | Produces | Notes |
|---|---|---|
| `check` | | verifies host tools, prints install hints |
| `release` | `build/out`, `build/rootfs` | Docker: sysroot, cross OTP, native OTP, Elixir, mix release, `/init` |
| `initramfs` (`all`) | `build/initramfs.cpio.gz` | gzip newc cpio of the rootfs, owner root |
| `m0-kernel` | `build/vmlinux-m0` | downloads the Firecracker CI Linux 6.1 kernel |
| `asterinas` | `build/asterinas/aster-nix-osdk-bin` | clones Asterinas at `ASTERINAS_REF`, applies `builder/asterinas-patches/*.patch`, builds in the upstream dev container |
| `run-m0`, `run-m0-app` | | boot on Linux into IEx / the app |
| `run-m1`, `run-m1-app` | | boot on Asterinas into IEx / the app |
| `smoke-m0`, `smoke-m1` | `build/logs/` | automated assertions |
| `smoke` | | `smoke-m0 smoke-m1 sizes` |
| `ec2-kernel` | `build/vmlinux-ec2` | Linux 6.1 with ENA, NVMe and EFI stub for the Linux AMI |
| `ami` | `build/disk-<KERNEL>[-iex].raw` | 1 GiB GPT disk with an EFI partition: GRUB, kernel, initramfs, command line |
| `run-disk`, `smoke-disk` | | boot / test the disk under OVMF with an NVMe root |
| `ami-publish` | an AMI id | EBS direct upload and `register-image` (UEFI, ENA); idempotent by name |
| `smoke-ec2` | `build/logs/ec2-*.log` | publish, launch a `t3.small`, assert, terminate |
| `ami-clean` | | deregister this version's AMIs and delete their snapshots |
| `sizes` | | image sizes against the 40 MB budget |
| `dist` | `dist/` | versioned bundle with checksums |
| `docs`, `docs-serve` | `build/book/` | the manual via mdBook in Docker |
| `site` | `build/site/` | landing page plus manual |
| `clean` | | removes `build/` and `dist/` |

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `OTP_TAG` | `OTP-29.1.1` | Erlang/OTP git tag |
| `ELIXIR_TAG` | `v1.20.4` | Elixir git tag |
| `ASTERINAS_REF` | `3d85cb4` | Asterinas commit or tag |
| `ALPINE` | `3.22` | Alpine version for the builder and the x86-64 sysroot (OpenSSL, zstd, musl versions follow from it) |
| `JOBS` | 8 | parallelism inside the builder |
| `PLATFORM` | Docker server's | container platform; the build is native on arm64 and x86-64 |
| `QEMU_ACCEL` | `kvm` if `/dev/kvm` is writable, else `tcg` | |
| `M0_MEM`, `M1_MEM` | `128M`, `160M` | guest RAM for the two kernels |
| `QEMU_SMP`, `M1_SMP` | 2, 2 | vCPUs |
| `TLS_HOST` | `www.erlang.org` | DNS and TLS probe target |
| `HOST_PORT_TCP/UDP/TLS` | 14000/14001/14443 | host side of the port forwards |
| `SMOKE_TIMEOUT`, `SMOKE_BOOT_TIMEOUT`, `SMOKE_ATTEMPTS` | 240, 60, 5 | smoke test timing (environment variables) |
| `KERNEL` | `asterinas` | kernel for `ami`, `run-disk`, `smoke-disk`, `ami-publish`, `smoke-ec2` (`asterinas` or `linux`) |
| `DISK_MODE` | `app` | `uniapp.mode` baked into the disk image (`app` or `iex`) |
| `DISK_LOGLEVEL` | `error` | Asterinas log level baked into the disk image |
| `DISK_MEM` | `256M` | guest RAM for the OVMF boot (GRUB needs more than the kernels) |
| `OVMF` | auto-detected | path to `edk2-x86_64-code.fd` |
| `AMI_FLAGS` | | extra flags for `ami-publish`, e.g. `--force` |
| `AWS_PROFILE`, `AWS_REGION` | from the environment | credentials and region for the EC2 targets |

## Files

| Path | Role |
|---|---|
| `VERSION` | project version, used by `dist` and `help` |
| `builder/Dockerfile` | the whole toolchain and release build |
| `builder/xcomp/erl-xcomp-x86_64-alpine-linux-musl.conf` | OTP cross-compilation config |
| `builder/cross-smoke.sh` | runs the cross-built `beam.smp` under qemu-user as a build check |
| `builder/asterinas-patches/` | kernel patches applied before building Asterinas |
| `init/init.c` | PID 1 |
| `app/` | the sample release |
| `scripts/` | rootfs assembly, initramfs, kernel fetch/build, smoke test, dist, disk image, EC2 publish and smoke |
