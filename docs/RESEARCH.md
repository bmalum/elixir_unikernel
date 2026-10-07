# Research: booting Elixir on a Rust kernel

Date: 2026-10-06. Items marked (verified) were checked against upstream source
at the tag/commit listed. Items marked (estimate) are not yet measured.

## 1. Versions (verified)

| Component | Version | Notes |
|---|---|---|
| Erlang/OTP | 29.1.1 (`OTP-29.1.1`, 2026-09-22) | `OTP_VERSION` file in tag = 29.1.1 |
| Elixir | 1.20.4 (`v1.20.4`) | supports OTP 27/28/29 |
| Hermit kernel | 0.13.0 (`main`) | Rust, MIT/Apache-2.0; C via `hermit-c` + `hermit-gcc` (Newlib + pthread-embedded) |
| Asterinas | 0.18.1 (commit 3d85cb4, 2026-10-05) | Rust, MPL-2.0; dev image `asterinas/dev:0.18.1-20260926` |

## 2. What the BEAM needs from an OS

| Need | Why | Avoidable? |
|---|---|---|
| pthreads, futex, SMP | schedulers, dirty schedulers, async threads | no |
| `mmap`/`munmap`, `mremap`, `madvise` | erts_mmap, allocators | `mremap` optional (Nanos disables it) |
| `poll` / `epoll` / `select` | I/O polling | `--disable-kernel-poll` falls back to `poll` |
| BSD sockets incl. `sendmsg`/`recvmsg`, `getifaddrs` (netlink on Linux) | `inet` driver, `socket` NIF | `inet_drv` needs less than esock |
| `fork` + `execve`, `pipe`, `socketpair` | see "forker" below | only by patching ERTS |
| `dlopen` | `crypto`, `asn1` NIFs | `--enable-static-nifs` |
| filesystem | `.beam` files load lazily; boot script, `sys.config` | needs initramfs/ramfs |
| `/dev/urandom` or `getrandom` | crypto seed, OpenSSL | no |
| tty: `isatty`, `ioctl(TIOCGWINSZ)`, termcap | IEx line editing (`prim_tty` NIF) | `--without-termcap` gives the old shell; `-noshell` for app mode |
| signals (`sigaction`, self-pipe) | `erl_signal_server`, SIGCHLD | minimal stubs tolerable |
| OpenSSL 3.x | `crypto` → `ssl`, `public_key` | must be linked statically into `beam.smp` |
| `erlexec`, `epmd` | launcher, distribution | start `beam.smp` directly; no epmd without `-sname`/`-name` |

### Forker and native resolver (verified in OTP-29.1.1 source)

- `erts/emulator/sys/unix/sys_drivers.c:191` opens the `forker` driver
  unconditionally at VM start; it fork+execs the separate binary
  `erts-*/bin/erl_child_setup`. So the image must contain `erl_child_setup`
  and the kernel must support `fork`/`execve`, or ERTS must be patched
  (Nanos patch 0003 turns it into a thread).
- `lib/kernel/src/inet_config.erl:190-197`: the default host lookup on Unix is
  `[native]`, which spawns the port program `inet_gethost` on first lookup.
  To avoid that second binary and the dependency on musl's resolver, ship an
  inetrc with `{lookup, [file, dns]}` plus `{nameserver, ...}` so OTP's pure
  Erlang `inet_res` is used.

### Static NIFs (verified, `erts/configure.ac:395`, `HOWTO/INSTALL.md:406`)

`--enable-static-nifs=yes` links all OTP NIFs into the main binary; external
dependencies must be supplied, e.g. `LIBS="-lcrypto"`. Built-in NIFs that are
always static: `prim_file`, `prim_socket`, `prim_net`, `prim_tty`,
`prim_buffer`, `zlib`, `zstd`, `erl_tracer`. (The earlier draft named a
`--disable-dynamic-ssl-lib` flag for this; for a fully static build the
mechanism that matters is `--enable-static-nifs` + `LIBS`.)

### How Elixir starts (verified, `bin/elixir`, `bin/iex` at v1.20.4)

- app mode: `erl -noshell ... -s elixir start_cli -extra --no-halt`
- IEx mode: `erl -noshell ... -user elixir -extra --no-halt +iex`

A shell-free `/init` must reproduce what `erlexec` + the release script pass to
`beam.smp`. Take the exact argv from `erl -emu_args_exit` in the builder rather
than hand-writing it. Expected shape:

```
beam.smp -- -root /rel -bindir /rel/erts-X/bin -progname erl -- -home / --
  -boot /rel/releases/VSN/start -boot_var RELEASE_LIB /rel/lib -mode embedded
  -config /rel/releases/VSN/sys -noshell
  { -user elixir -extra --no-halt +iex | -s elixir start_cli -extra --no-halt }
```

`config/runtime.exs` is usable: `reboot_system_after_config` defaults to
`false` in v1.20.4 (`mix/release.ex:549`), so no VM restart and no writable
release dir is required unless you opt in.

### Prior art

- nanovms/erlang: 6 patches on OTP 23 for Nanos — embed erlexec and epmd,
  `erl_child_setup` as a thread, node name from ifaddr, skip cookie permission
  check, disable `mremap`. This is the patch set a Hermit port needs.
- OtoloNetworks/rebar3_osv (OSv, C++), LING/Erlang-on-Xen (dead), AtomVM
  (subset VM), GRiSP (RTEMS), portasynthinca3/boss (Erlang VM rewritten in
  Rust, proof of concept).

None runs full OTP on a Rust kernel.

## 3. Candidate Rust kernels

### Hermit (true unikernel; app linked into `libhermit.a`)

121 exported `sys_*` functions on `main` (verified by grep over `src/`).
Present: files (`open read write readv writev lseek fstat getdents64 fcntl
ioctl poll eventfd dup dup2 ...`), tasks (`spawn clone join exit kill
nanosleep ...`), `futex_wait/wake`, `mmap munmap mprotect` (feature `mman`),
clocks, entropy, sockets (`socket bind listen accept connect send sendto recv
recvfrom shutdown getsockopt setsockopt getpeername getsockname
getaddrbyname`). Network: smoltcp (TCP/UDP/DHCPv4/DNS), virtio-net. Also
virtio-fs, virtio-vsock, SMP. Boots via `hermit-loader` on QEMU/KVM or Uhyve.

Absent (verified, none of these exist as `sys_*`): `pipe`, `socketpair`,
`select`, `sendmsg`, `recvmsg`, `mremap`, `madvise`, `fork`, `execve`,
`sigaction`, `epoll`, `getrandom`, `accept4`, `uname`, `sched_*`, `dlopen`.

Consequences: ERTS needs the Nanos-style patches plus emulation of
`pipe`/`socketpair` (ERTS uses them internally for wakeups and the forker);
OTP's `erts/configure` and OpenSSL need an `x86_64-hermit` port; the
filesystem must be populated from an embedded archive by Rust glue before
`main`. Smallest possible artifact, but a multi-month port.

### Asterinas (Rust framekernel, Linux ABI)

245 syscalls in `kernel/core/src/syscall/arch/x86.rs` (verified), including
`fork vfork clone clone3 execve execveat epoll_* futex mremap madvise getrandom
sendmsg recvmsg accept4 socketpair pipe2 poll ppoll select pselect6
rt_sigaction rt_sigprocmask sigaltstack sched_{set,get}affinity timerfd_create
eventfd2 prlimit64 setitimer set_robust_list sendfile sysinfo tgkill uname
wait4 setsid flock fallocate statx fdatasync ioctl`.

- Filesystems: ramfs, tmpfs, ext2, exfat, virtiofs, overlayfs, devtmpfs,
  devpts, procfs, sysfs.
- Network: virtio-net on smoltcp, TCP/UDP, unix sockets, netlink with a
  `route` family (needed by musl `getifaddrs`), vsock.
- Init (verified, `book/.../kernel-parameters.md`, `fs/initramfs.rs`): accepts
  `initramfs.cpio` or `initramfs.cpio.gz`, runs `/init` or `rdinit=<path>`.
  Also supports `root=/dev/vdX rootfstype=ext2` + `init=`.
- Boot (verified, `OSDK.toml`, `Makefile`): default is a GRUB rescue ISO with
  multiboot2; the `microvm` scheme uses `vmm-direct` (QEMU `-kernel`); a
  `linux-efi-handover64` protocol also exists. The initramfs is bundled by
  `cargo osdk --initramfs=...`.
- Default `MEM ?= 8G` in the Makefile. Behaviour at 128 MB is not verified.

Verdict: an unmodified static-musl `beam.smp` should run as PID 1 with no ERTS
patches (to be proven in M1). Not a unikernel in the strict sense (kernel/user
split, ELF loader), but a single-purpose image whose userland is only ERTS.

### Ruled out

Theseus (no POSIX), Redox (relibc, microkernel), kerla / maestro (stale or
immature), Unikraft / Nanos / OSv (not Rust).

## 4. Recommendation

- Track A (weeks): Asterinas + static-musl OTP 29.1.1 + Elixir 1.20.4 release.
- Track B (months, optional): Hermit port with the Nanos-style patch set,
  `pipe`/`socketpair` emulation and OpenSSL on Newlib. Track A is the
  regression baseline.

M0 rehearses Track A on a stock Linux kernel so the kernel swap in M1 is the
only variable.

## 5. Build findings (verified while implementing M0/M1, 2026-10-06)

- `erts/configure` hardcodes `LIBZSTD="-Wl,-Bstatic -lzstd -Wl,-Bdynamic"`
  (configure.ac:1330). With `make LDFLAGS=-static` the trailing `-Bdynamic`
  makes lld silently link libc/libstdc++ dynamically into the "static"
  `beam.smp`; bfd fails with "attempted static link of dynamic object". The
  binary gets a `PT_DYNAMIC` and segfaults before `main` (reproduced on real
  x86 under QEMU TCG, not a Rosetta artefact). Fix: `sed` it to `-lzstd`.
- `-static` must be passed to `make`, not `configure`: the DED conftests link
  with `-shared` and fail on `-static -shared`.
- `--enable-static-nifs=yes` links `asn1rt_nif.a` and `crypto.a` into
  `beam.smp` automatically (`erts/emulator/Makefile.in:229-236`);
  `--enable-static-drivers=yes` expands to an empty list and is pointless.
- On Apple Silicon (colima + Rosetta), Alpine's gcc 14 `cc1`/`collect2`
  segfault intermittently on large compiles/links. clang 20 + lld are stable.
- Asterinas v0.18.1 under QEMU TCG: the `qemu-direct` + `linux` (bzImage)
  protocol produced no output in 150 s; the `multiboot` ELF (e_machine
  patched to EM_386 by OSDK) boots to initramfs unpacking in ~0.5 s guest
  time. Needs `earlycon` on the command line to see early output, `-cpu`
  with x2APIC (Icelake-Server works), modern-only virtio
  (`disable-legacy=on`), and `-device isa-debug-exit` to power off.
- Asterinas v0.18.1 is loaded at physical 0x8000000 (128 MB) and occupies
  ~13 MB above that; `-m 128M` prints nothing, `-m 144M` and up boot. Kernel
  ELF is 5.3 MB (release, stripped).

### M1 findings on Asterinas (2026-10-07)

- v0.18.1 boots our initramfs and runs the static `beam.smp` as PID 1; OTP 29
  + Elixir 1.20.4 start, the Erlang shell works on the serial console.
- `bind()` to `INADDR_ANY` (0.0.0.0) fails with `EADDRNOTAVAIL` on v0.18.1
  (`net/socket/ip/common.rs:get_iface_to_bind` only matches an interface
  address); binding 10.0.2.15 or 127.0.0.1 works. `gen_tcp:listen(Port, [])`
  therefore fails and, with a permanent app, takes the VM down. Upstream
  `main` (Oct 2026) adds a regression test that binds `INADDR_ANY`
  (`test/.../tcp_err.c`), so we pin `3d85cb4` instead of the tag.
- No interface SET ioctls (`SIOCSIFADDR`, `SIOCSIFFLAGS`, `SIOCADDRT` return
  `ENOTTY`); addresses are configured in-kernel (`net/iface/init.rs`:
  10.0.2.15/24 on eth0, gateway 10.0.2.2, 127.0.0.1 on lo). `/init` logs and
  continues. `inet:getifaddrs/0` returns `{error, eaddrnotavail}` on v0.18.1.
- `/dev` is populated by the kernel; `mount -t devtmpfs` returns `ENODEV`
  (harmless). `clock_getres` (syscall 229) is unimplemented (musl falls back).
- `-user elixir` (IEx) produced no output on v0.18.1 only because the app
  crash-loop halted the VM first; the Erlang shell path itself works.

### Asterinas "livelock" during ERTS start (2026-10-07, root-caused, patched)

Symptom: with QEMU TCG the image sometimes stalled after `/init` exec'd
`beam.smp`, or later mid-run; 1 vCPU always, 2 vCPUs ~50 %, 4 vCPUs ~15 %.
QEMU monitor samples first pointed at `handle_pending_signal`, but with more
samples the hot path is `epoll_pwait` → `ReadySet::poll` → `TimerfdFile::poll`:
ERTS's poll thread was looping on `epoll_wait` at 100 % CPU, starving the
schedulers.

Root cause (reproduced with a 30-line C program, `build/clk/init.c`): ERTS
arms a `timerfd` with `timerfd_settime`, calls `epoll_wait(-1)`, then disarms
with `timerfd_settime(0)` and never `read()`s the fd. On Asterinas
`TimerfdFile::set_time` resets the expiration counter but does not invalidate
the `Pollee`'s cached readiness, so epoll keeps reporting `IN` for an already
disarmed timer: 19 of 20 `epoll_wait` calls returned in 0 ms (Linux: 0 of
20). Fix: `self.pollee.invalidate()` after `ticks.store(0)`
(`builder/asterinas-patches/0002-timerfd-settime-invalidate-readiness.patch`,
one line). After the patch: 0 spurious wake-ups, 8/8 clean boots at 1 and 2
vCPUs, and the Asterinas memory floor drops from 256 MB to 144 MB because the
runaway poll thread no longer exhausts the kernel heap.

### Memory and boot time (2026-10-07)

- `-mode embedded` loads all 742 modules at boot: `beam.smp` RSS 116 MB.
  `-mode interactive` (now the default in `/init`, `uniapp.code=embedded`
  restores the old behaviour) loads 234 and halves RSS to 62 MB; application
  start moves from ~9 s to ~4 s of guest time under TCG.
- Linux: boots and passes all probes at 128 MB; OOM at 128 MB with embedded
  mode. Asterinas (with patch 0002): all probes pass at 144 MB; 136 MB prints
  nothing because the kernel is loaded at physical 0x8000000 (128 MB).
- `+Meamin` (minimal allocators) only saves ~3 MB here; not used.

## 6. Size (measured 2026-10-07)

initramfs.cpio.gz 9.4 MB (rootfs 22 MB uncompressed: ERTS 9.9 MB static
`beam.smp` + 12 OTP/Elixir apps with stripped beams + 0.2 MB CA bundle);
Asterinas kernel 5.8 MB (release, stripped); total 15.2 MB against the 40 MB
budget. The Linux reference kernel is 44 MB (uncompressed vmlinux, debug
info) and not part of the product.
