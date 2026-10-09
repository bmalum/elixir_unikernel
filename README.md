# elixir_unikernel

Boot straight into Elixir on a Rust kernel. A `mix release` becomes a 15 MB
machine image: the [Asterinas](https://asterinas.github.io) kernel, a 300-line
static `/init`, and the Erlang VM. No shell, no init system, no dynamic loader.
TCP, UDP, TLS 1.3 and DNS work on the first boot, under QEMU and as an EC2
AMI on a t3.small (with an ENA driver written for it).

```text
[kernel] running /init as the init process
[init] elixir_unikernel init, uptime 0.560 s
[init] net: eth0 10.0.2.15/24 gw 10.0.2.2 dns 10.0.2.3 (kernel dhcp)
[init] exec /rel/erts-17.1/bin/beam.smp (iex mode)
Erlang/OTP 29 [erts-17.1] [source] [64-bit] [smp:2:2] [ds:2:2:10] [async-threads:1] [jit:ns]
Interactive Elixir (1.20.4) - press Ctrl+C to exit (type h() ENTER for help)
iex(1)>
```

Website and manual: https://bmalum.github.io/elixir_unikernel/ (built from
`site/` and `docs/book/`; `make site` builds it locally).

## Quick start

```sh
make check        # host prerequisites: docker buildx, qemu-system-x86_64, coreutils
make run-m1       # build everything (~15 min cold) and boot into IEx. Ctrl-a x exits QEMU.
make run-m1-app   # application mode, no shell
make smoke        # rebuild from pinned tags and run all assertions on both kernels
make smoke-ec2    # publish the AMI and run the assertions on a t3.small (AWS_PROFILE, AWS_REGION)
make help         # every target
```

While a VM runs, the guest's echo servers are reachable from the host:
`printf 'hi\n' | nc 127.0.0.1 14000` (TCP), port 14001 (UDP), port 14443
(TLS 1.3). See the manual's
[first boot](docs/book/src/getting-started/first-boot.md) chapter.

## What is here

| Path | |
|---|---|
| `builder/Dockerfile` | static x86-64 OTP 29.1.1 + Elixir 1.20.4 + release; native build, ERTS cross-compiled with clang |
| `builder/asterinas-patches/` | seven kernel patches: wildcard `bind()`, `timerfd` readiness, runtime `ifconfig` ioctls, in-kernel DHCP (`ip=dhcp`), the ENA driver, reboot/`clock_settime`, NVMe on EBS |
| `init/init.c` | PID 1: mount, DHCP or static NIC config, inetrc, IMDS user data, SNTP, data volume, supervise `beam.smp`, reboot on exit |
| `app/` | sample release: TCP/UDP/TLS echo servers, DNS and TLS client probes |
| `scripts/` | rootfs assembly, initramfs, kernel fetch/build, smoke test, dist bundle, disk image, AMI publish and EC2 smoke |
| `docs/book/` | the manual (mdBook); `docs/RESEARCH.md` has the original research notes |
| `site/` | landing page |
| `GOALS.md` | success criteria and measured status |

## Status

0.1.0. Milestones M0 (stock Linux), M1 (Asterinas), M2 (TLS, size and
memory budgets, CI) and the EC2 goal ([docs/GOALS-EC2.md](docs/GOALS-EC2.md):
UEFI AMI, in-kernel DHCP, ENA driver, IEx over the Serial Console) are done;
the stretch goal M3 (a true unikernel on Hermit) is not started. Measured: 9.4 MB image + 5.8 MB kernel; 128 MB RAM on
Linux, 144 MB on Asterinas; 3 to 4 s to the IEx prompt under QEMU TCG. See
[GOALS.md](GOALS.md) and the manual's
[limits](docs/book/src/reference/limits.md) page.

## Contributing and licence

[CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md),
[CHANGELOG.md](CHANGELOG.md). Apache 2.0 for this repository; bundled
components keep their licences, listed in [NOTICE](NOTICE).
