# Asterinas patches

`scripts/build-asterinas.sh` applies every `builder/asterinas-patches/*.patch`
to the Asterinas checkout before building. The patches are small, were found
by running this image, and should go upstream. Until then they
are documented here so that nobody is surprised that the kernel is not
pristine `3d85cb4`.

## 0001: bind() to the unspecified address

Asterinas `main` (October 2026) resolves the interface for a `bind()` by
looking the address up in the local routing table. `0.0.0.0` is in no table,
so every wildcard bind fails with `EADDRNOTAVAIL`. That breaks
`gen_tcp:listen(Port, [])`, `gen_udp:open(0, [])` and OTP's `inet_res`
resolver, which binds its query socket to `0.0.0.0:0`. (v0.18.1 had the same
behaviour through a different code path.)

The patch (`kernel/core/src/net/socket/ip/common.rs`,
`resolve_bind_iface_and_config`) treats an unspecified address as "the
default interface": the last registered one, which is the virtio NIC, falling
back to loopback. It also rewrites the endpoint address to that interface's
own address, because `aster-bigtcp` dispatches incoming packets by
`(addr, port)` and a socket left bound to `0.0.0.0` never receives anything
(and, as a side effect, exhausted the kernel heap while retrying).

Consequence: a socket bound to `0.0.0.0` on Asterinas receives traffic on the
NIC only, not on loopback. The sample app's self-tests therefore connect to
the NIC address instead of `127.0.0.1`. The proper fix is a socket attached
to all interfaces; this patch is the smallest change that makes OTP work.

## 0002: timerfd_settime must invalidate epoll readiness

Symptom: with QEMU TCG the image sometimes stalled right after `/init`
exec'd `beam.smp`, or later mid-run. With one vCPU it stalled every time,
with two about every second boot, with four about one in six. QEMU monitor
samples showed one vCPU permanently in kernel mode, first apparently in
`handle_pending_signal`, with more samples in `epoll_pwait`,
`ReadySet::poll` and `TimerfdFile::poll`. The console log of a stalled run
contained roughly 500,000 `epoll_pwait` calls: ERTS's poll thread was
spinning at 100 % and starving the schedulers.

ERTS uses a `timerfd` for sub-millisecond timeouts in `erl_poll`: arm it with
`timerfd_settime`, `epoll_wait(-1)`, then disarm with `timerfd_settime(0)`,
without ever `read()`ing the descriptor. Asterinas's `TimerfdFile::set_time`
resets the expiration counter but did not invalidate the `Pollee`'s cached
readiness, so `epoll_wait` kept returning the disarmed timer as readable.

A 30-line C program (`build/clk/init.c` in the repository history; the loop
is "arm 200 ms, `epoll_wait`, disarm, measure") showed 19 of 20 waits
returning in 0 ms on Asterinas and 0 of 20 on Linux. The fix is one line in
`kernel/core/src/time/timerfd.rs`, `set_time`: `self.pollee.invalidate()`
after `ticks.store(0)`. After it: 0 spurious wake-ups, 8 of 8 clean boots at
one and two vCPUs, and the memory floor dropped from 256 MB to 144 MB
because the runaway poll thread no longer exhausted the kernel heap.

Lesson recorded for the next kernel: when a "livelock" log is dominated by
one syscall returning immediately, suspect spurious readiness before locks,
and write the ten-line reproducer first.

## 0003: runtime interface configuration (SIOCSIFADDR and friends)

Symptom: `/init` configures `eth0` the way `ifconfig` does, with
`SIOCSIFADDR`, `SIOCSIFNETMASK`, `SIOCSIFFLAGS` and `SIOCADDRT`. On Asterinas
every one of them returned `ENOTTY`; the kernel only implemented the `GET`
variants and hardcodes `10.0.2.15/24` via `10.0.2.2` for the virtio NIC in
`kernel/core/src/net/iface/init.rs`. That happens to match QEMU's user-mode
network, so nothing visibly broke under QEMU, but on EC2 the address comes
from DHCP and must be set at runtime.

The patch adds the setters:

- `aster-bigtcp`: `Iface::set_ipv4_cidr` and `Iface::set_ipv4_gateway`
  update smoltcp's `ip_addrs` and default route under the interface lock.
- `kernel/core/src/net/route`: the two route managers move into an
  `RwLock` and `route::reload()` rebuilds the local/main tables from the
  interfaces' current addresses, so `bind()` and output-interface lookups
  see the new address immediately.
- `kernel/core/src/net/socket/ip/ioctl.rs`: `SIOCSIFADDR`, `SIOCSIFNETMASK`,
  `SIOCSIFBRDADDR` (accepted; broadcast is derived), `SIOCADDRT` and
  `SIOCDELRT` for the default route (`struct rtentry`, gateway only).
- `kernel/core/src/net/socket/util/ioctl.rs`: `SIOCSIFFLAGS` is accepted
  (interfaces are always up).

Verified by booting with `uniapp.ip=10.0.9.77/24 uniapp.gw=10.0.9.2` on a
QEMU user network `10.0.9.0/24`: the guest answers on the new address and
the DNS and TLS probes pass, which they cannot with the compiled-in
`10.0.2.15`. Limits: one IPv4 address per interface, default route only.

## 0004: in-kernel DHCPv4 client (`ip=dhcp`)

Asterinas has no `AF_PACKET` sockets, so the DHCP client in `/init` cannot
run there, and on EC2 the address is only available via DHCP. smoltcp, the
network stack inside `aster-bigtcp`, ships a DHCPv4 client socket; this patch
wires it in:

- `Cargo.toml`: enables smoltcp's `socket-dhcpv4` feature.
- `aster-bigtcp`: `EtherIface::new_dhcp` creates an interface without an
  IPv4 address and a `Dhcpv4Socket` next to it. Ingress UDP from port 67 to
  68 is fed to the client, the client's DISCOVER/REQUEST packets are emitted
  through the normal UDP path (so broadcast and the unspecified source work),
  and the client's retry timers take part in `next_poll_at_ms`. While no
  address is set, unicast UDP to a not-yet-owned address is accepted,
  because servers may unicast the OFFER to `yiaddr`. On `Configured` the
  lease is applied with the setters from patch 0003, and
  `CONFIG_GENERATION` is bumped.
- `kernel/core/src/net/route`: the route tables rebuild lazily on the next
  lookup when `CONFIG_GENERATION` changed, since the lease arrives in the
  poll path, where the route lock cannot be taken.
- `kernel/core/src/net/iface/init.rs`: `ip=dhcp` on the command line selects
  `new_dhcp` for the virtio NIC; otherwise behaviour is unchanged.
- `/proc/net/dhcp`: one line per DHCP-configured interface,
  `eth0 10.0.2.15/24 10.0.2.2 dns 10.0.2.3`, or `eth0 pending`. Linux has no
  such file (it has no in-kernel DHCP client); it is how `/init` learns the
  nameserver.

Measured under QEMU: the lease arrives 33 ms after boot, `/init` logs
`net: eth0 10.0.2.15/24 gw 10.0.2.2 dns 10.0.2.3 (kernel dhcp)`, and `make
smoke-m1` passes without any `uniapp.ip=` parameter.

## Reporting upstream

The patches are `git diff` output against `3d85cb4`, apply in order with
`git apply`, and each depends on the previous ones. To send them: open issues on
[asterinas/asterinas](https://github.com/asterinas/asterinas) with the C
reproducer for 0002 and the `gen_tcp:listen` reproducer for 0001; the
project's `CONTRIBUTING` asks for a regression test under
`test/initramfs/src/regression`. If upstream fixes land, bump `ASTERINAS_REF`
and delete the patch; `build-asterinas.sh` fails loudly if a patch no longer
applies.
