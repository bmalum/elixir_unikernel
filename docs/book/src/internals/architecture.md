# Architecture

```text
 QEMU / KVM (x86-64)
 ┌───────────────────────────────────────────────────────────────┐
 │ Asterinas kernel (Rust, Linux ABI)          5.8 MB ELF        │
 │   virtio-net ─ smoltcp TCP/IP   virtio-rng   ramfs (initramfs) │
 ├──────────────── syscalls (Linux ABI) ─────────────────────────┤
 │ /init  (static C, PID 1, 40 KB)                               │
 │   mount, ifconfig, inetrc, env, exec ─┐                       │
 │                                       ▼                       │
 │ beam.smp (static musl, OTP 29.1.1, JIT, OpenSSL 3.5 inside)   │
 │   kernel · stdlib · sasl · crypto · ssl · public_key · asn1   │
 │   elixir · logger · iex · your release                        │
 │   erl_child_setup (idle helper)                               │
 └───────────────────────────────────────────────────────────────┘
```

Three design decisions shape everything else.

## Run the real BEAM

The runtime is an unmodified Erlang/OTP 29.1.1 built from the upstream tag. No
patches to ERTS, no alternative VM. Everything that works in OTP works here,
with the limits that follow from having no other programs and no dynamic
loader (see [Limits](../reference/limits.md)). The price is that the kernel
must speak the Linux ABI well enough for ERTS, which is a few hundred
syscalls including `fork`/`execve` (for `erl_child_setup`), `epoll`,
`timerfd`, `futex`, `socketpair` and the socket API.

## Replace the kernel, keep the ABI

Asterinas implements the Linux ABI in Rust with a small unsafe core. Because
the ABI is the same, the identical initramfs boots on a stock Linux kernel
(`make run-m0`), which gives a reference for every bug: if it works on Linux
it is the kernel. Two Asterinas patches were needed, both small and both
candidates for upstream ([Asterinas patches](asterinas-patches.md)).

## Delete the userland instead of shrinking it

A typical Erlang deployment starts with a shell script (`bin/myapp`) that
runs `erlexec`, which computes an argument vector and `exec`s `beam.smp`.
`/init` does what those two do, in C, with the arguments fixed at build time,
and nothing else. There is no shell to run the script, no `erl` to find the
emulator, no `epmd`, no `inet_gethost` (replaced by configuring OTP's
Erlang-level resolver). `scripts/assemble-rootfs.sh` enforces this: any ELF
other than `/init`, `beam.smp` and `erl_child_setup` fails the build.

## Static everything

`beam.smp` is linked with `-static` against musl, with OpenSSL, zlib, zstd
and OTP's own NIFs (`crypto`, `asn1`) linked in via `--enable-static-nifs`.
Nothing is loaded at runtime except `.beam` files. The same applies to
`erl_child_setup` and `/init`. This is what makes "no dynamic loader in the
image" possible, and it removes an entire class of deployment problems.

## Boot flow

1. The VMM loads the kernel ELF and the initramfs, passes the command line.
2. The kernel initialises devices, unpacks the cpio into its root file
   system, and executes `/init`.
3. `/init` configures the environment ([The init program](init.md)) and
   `exec`s `beam.smp` with the argument vector a release's `bin/myapp start`
   would have produced.
4. ERTS reads `releases/<vsn>/start.boot`, loads the listed applications
   (lazily in `interactive` mode), applies `sys.config` and
   `config/runtime.exs`, and starts the supervision trees. In `iex` mode
   `-user elixir` starts the shell on the serial console.
5. From here it is an ordinary node, minus the things in
   [Limits](../reference/limits.md).

## What is deliberately not here

- An init system, service manager or process supervisor above the BEAM.
  OTP's supervision trees are the supervisor. If the node stops, the VM is
  done; restart it from outside.
- A writable root. Configuration comes in through the kernel command line.
- A shell or any debugging tool other than IEx itself (and `uniapp.mode=erl`,
  `uniapp.eval=` for the cases where IEx is what is broken).
