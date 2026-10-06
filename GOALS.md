# Goals — Elixir on a Rust kernel

## Vision

A single bootable image, built from a `mix release`, that runs on a memory-safe
Rust kernel and starts directly into an Elixir application (or IEx) with
working TCP/UDP and TLS. No Linux, no shell, no init system; the only userland
is ERTS itself.

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
| M0 | Shell-free release on a stock Linux kernel | Static-musl OTP 29.1.1 + Elixir 1.20.4 release with a static `/init`, boots to IEx and to app mode under QEMU with Alpine `linux-virt`. Baselines size, RAM and boot time. |
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
