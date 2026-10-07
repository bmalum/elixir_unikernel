# Limits and measurements

All numbers from 2026-10-07, QEMU 11.1 with TCG on an Apple M-series host
(x86-64 emulated), 2 vCPUs. KVM numbers will be considerably better.

## Memory

| Kernel | Minimum guest RAM for all probes | Notes |
|---|---|---|
| Linux 6.1 | 128 MB | OOM below that |
| Asterinas | 144 MB | the kernel is loaded at physical 0x8000000 (128 MB); a 128 MB guest cannot hold it. 136 MB prints nothing |

`beam.smp` RSS with the sample app, `-mode interactive` (default): 62 MB, 234
modules loaded. With `-mode embedded`: 116 MB, 742 modules. `erlang:memory(total)`
is 38 MB versus 63 MB.

## Boot time

| | Linux | Asterinas |
|---|---|---|
| kernel entry to `/init` | 1.04 s | 0.45 s |
| `/init` to application start, interactive mode | ~3.2 s | ~2.6 s |
| `/init` to application start, embedded mode | ~8 s | ~5.5 s |

Under TCG every instruction is emulated; most of the application-start time
is the JIT compiling modules on first load. The GOALS.md target of 2 s from
kernel entry to prompt has not been measured with KVM yet.

## Size

Shipped image 15.2 MB (9.4 MB initramfs + 5.8 MB kernel) against a 40 MB
budget. Adding Phoenix costs 4 to 6 MB compressed.

## Not supported

- Erlang distribution and `epmd`: nothing in the image, no `-name`/`-sname`.
- `Port.open/2` with external programs, `System.cmd/3`, `os:cmd/1`: there are
  no programs. `erl_child_setup` is present, so the mechanism works; there is
  just nothing to execute.
- NIFs loaded at runtime: no `dlopen`. OTP's `crypto` and `asn1` are linked
  statically.
- Persistent storage: the initramfs is read-only; `/tmp` is RAM.
- Hot code upgrades: no writable release directory (and `-mode interactive`
  loads from the read-only tree anyway).
- Terminfo: `TERM=dumb`, no colours in IEx.
- IPv6: untested. DHCP: not implemented; addresses come from the command line.
- Clean power-off from the guest: stopping the node leaves the kernel without
  an init process; QEMU keeps running.
- Asterinas only: interface configuration from the command line (the address
  is compiled into the kernel), binding a socket to `0.0.0.0` and reaching it
  over loopback, hardware other than virtio.
