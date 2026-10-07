# Goals — Elixir on a Rust kernel

## Vision

A single bootable image, built from a `mix release`, that runs on a memory-safe
Rust kernel and starts directly into an Elixir application (or IEx) with
working TCP/UDP and TLS. No Linux, no shell, no init system; the only userland
is ERTS itself.

## Status (2026-10-07)

M0, M1 and M2 are done; `make smoke` is green on this machine (Apple Silicon,
QEMU TCG). Measured against the criteria below:

| # | criterion | result |
|---|---|---|
| 1 | IEx prompt on serial, OTP 29.1.1 + Elixir 1.20.4 | yes, on Linux and Asterinas. Boot time under TCG (x86 emulated on arm64): kernel entry to `/init` 0.5 s (Asterinas) / 1.0 s (Linux); to application start 3–4 s; the 2 s target is not met under emulation and is not yet measured on KVM |
| 2 | app mode via `uniapp.mode=app`, no shell | yes |
| 3 | `:gen_tcp`/`:gen_udp` listen + connect over virtio-net, `:ssl.connect` TLS 1.3 with CA verification, `:ssl.listen` accepting a client, `inet_res` DNS | yes on both kernels; servers are exercised from the host through QEMU port forwards, TLS client against www.erlang.org |
| 4 | kernel + initramfs ≤ 40 MB, 128 MB RAM | 9.4 MB initramfs + 5.8 MB Asterinas kernel = 15.2 MB. Linux passes everything at 128 MB; Asterinas needs 256 MB (its kernel is linked at physical 128 MB, floor measured at 192–224 MB) |
| 5 | userland = ERTS only | 3 ELFs in the image (`/init`, `beam.smp`, `erl_child_setup`), all static; `scripts/assemble-rootfs.sh` enforces it |
| 6 | one `make`, pinned tags, CI smoke | `make smoke` from an empty `build/`; `.github/workflows/smoke.yml` |

Known issue: Asterinas (upstream `main`, with and without our patch) occasionally
livelocks in the kernel (`handle_pending_signal`) while ERTS starts; the smoke
test retries stalled boots and reports it. See docs/RESEARCH.md.

## MVP success criteria

1. Under QEMU/KVM, the image boots to an IEx prompt on the serial console on
   Erlang/OTP 29.1.1 and Elixir 1.20.4. Target: under 2 s from kernel entry to
   prompt (target, to be baselined in M0).
2. The same image, booted with a kernel command-line switch, starts straight
   into the Elixir application's supervision tree with no shell.
3. Networking over virtio-net (static IP or DHCP): `:gen_tcp` and `:gen_udp`
   connect and listen; `:ssl.connect/3` completes a TLS 1.3 handshake with an
   external host using a bundled CA store; `:ssl.listen/2` accepts a TLS
   client. Hostname resolution works via `inet_res` (inetrc
   `{lookup, [file, dns]}`).
4. Kernel + initramfs at most 40 MB; runs with at most 256 MB guest RAM
   (target 128 MB; Asterinas 0.18.1 is linked at physical 128 MB and needs
   >= 144 MB to boot at all, see RESEARCH.md).
5. Userland is limited to ERTS: the initramfs contains only `/init`,
   `beam.smp`, `erl_child_setup` (started unconditionally by ERTS), the release
   files and config. No `sh`, no `erl`/`erlexec`, no `epmd`, no
   `inet_gethost`, no dynamic loader; every ELF is statically linked.
6. Reproducible: one `make` from pinned OTP, Elixir and kernel git tags, plus a
   CI smoke test that boots the image and asserts (1)–(3).

## Non-goals for the MVP

- Erlang distribution / `epmd`
- User-level `Port` spawning, `System.cmd/3`, `os:cmd/1` (may work on
  Asterinas, but not required or tested)
- Persistent storage, hot code upgrades
- ARM64, Firecracker, bare-metal hardware (QEMU/KVM x86-64 only)
- Third-party NIFs beyond OTP's own

## Milestones

| | Milestone | Done when |
|---|---|---|
| M0 | Shell-free release on a stock Linux kernel | Static-musl OTP 29.1.1 + Elixir 1.20.4 release with a static `/init`, boots to IEx and to app mode under QEMU with a stock Linux kernel (Firecracker CI build; Alpine `linux-virt` ships virtio-net as a module). Baselines size, RAM and boot time. |
| M1 | Same initramfs on Asterinas | IEx prompt on serial; `:gen_tcp` over virtio-net. |
| M2 | TLS, budgets, CI | `:ssl` client + server pass; ≤ 40 MB; 128 MB RAM; CI smoke test green. |
| M3 (stretch) | Hermit unikernel port | OTP + OpenSSL cross-built for `x86_64-hermit`; patches for forker-as-thread, `pipe`/`socketpair` emulation, no `mremap`; same smoke tests pass. |

## Risks

- Asterinas maturity (0.18.x): expect missing ioctls or socket options. Its
  default VM is 8 GB; measured floor on 0.18.1 is 144 MB (kernel load address
  is 0x8000000 = 128 MB, so 128 MB cannot work without relinking the kernel).
- `erl_child_setup` relies on `fork`/`execve` + `socketpair`; any gap there
  blocks VM start, not just `Port`s.
- Static OpenSSL + static `beam.smp` on musl is a less-trodden configure path;
  check with `file beam.smp`.
- Build host: Asterinas and Hermit toolchains need x86-64 Linux with Docker.
  This Mac has no Docker or QEMU installed yet.
