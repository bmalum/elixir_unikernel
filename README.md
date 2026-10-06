# elixir_unikernel

Boot straight into Elixir (IEx or your application) on a Rust kernel.
No Linux userland, no shell, no init system: `/init` is a 300-line static C
program that configures the NIC and `exec`s `beam.smp`.

See [GOALS.md](GOALS.md) for the success criteria and
[docs/RESEARCH.md](docs/RESEARCH.md) for why Asterinas (M1) and Hermit (M3).

## Layout

```
builder/Dockerfile   static-musl OTP 29.1.1 + Elixir 1.20.4 + mix release (linux/amd64)
app/                 sample app: TCP echo server + boot-time probes (udp, tcp, dns, tls, tls_srv)
init/init.c          PID 1: mount, ifconfig from cmdline, inetrc, exec beam.smp
scripts/             rootfs assembly, initramfs, kernels, smoke test, sizes
Makefile             one entry point for everything
.github/workflows    CI: build release -> M0 (Linux) and M1 (Asterinas) smoke tests
```

## Build and run

Requirements on the host: `docker` (buildx), `qemu-system-x86_64`, `make`.
On an Apple Silicon Mac: `brew install colima docker docker-buildx qemu` and
`colima start --vm-type vz --vz-rosetta`; the containers are `linux/amd64`.

```sh
make initramfs            # build/initramfs.cpio.gz  (static OTP + Elixir release)
make run-m0               # stock Linux kernel, IEx on the serial console
make run-m0-app           # same image, application mode (-noshell)
make smoke-m0             # non-interactive assertions (probes, IEx prompt)
make asterinas run-m1     # Rust kernel
make smoke-m1 sizes
```

Exit QEMU with `Ctrl-a x`.

## Kernel command line

| key | default | meaning |
|---|---|---|
| `uniapp.mode=iex\|app` | `iex` | IEx shell or application only (`-noshell`) |
| `uniapp.ip=A.B.C.D/N` | `10.0.2.15/24` | static address for the first NIC |
| `uniapp.gw=A.B.C.D` | `10.0.2.2` | default gateway |
| `uniapp.dns=A.B.C.D` | `10.0.2.3` | nameserver for OTP's `inet_res` |
| `uniapp.tls_host=HOST` | unset | enables the DNS + TLS 1.3 client probes against HOST:443 |

Defaults match QEMU user-mode networking.

## How the boot works

1. Kernel unpacks the initramfs and runs `/init`.
2. `/init` mounts `proc`, `devtmpfs`, `sysfs`; sets `lo` and `eth0` up via
   `SIOCSIFADDR`/`SIOCADDRT`; writes `/etc/inetrc` (`{lookup,[file,dns]}` so
   OTP never spawns `inet_gethost`); exports `BINDIR`, `ROOTDIR`, `RELEASE_*`;
   `exec`s `beam.smp` with the argv `erlexec` would have produced.
3. ERTS boots the release boot script (`-mode embedded`); in IEx mode the
   `-user elixir ... +iex` arguments start the shell on the serial console.

`beam.smp` is the only process. ERTS still spawns its `erl_child_setup`
helper (needed for `Port`s; it is kept and static). Nothing else is in the
image: `scripts/assemble-rootfs.sh` fails if any other ELF is present.
