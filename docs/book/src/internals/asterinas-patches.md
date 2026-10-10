# Asterinas patches

`scripts/build-asterinas.sh` applies every `builder/asterinas-patches/*.patch`
to the Asterinas checkout before building. The patches are small, were found
by running this image, and should go upstream. Until then they
are documented here so that nobody is surprised that the kernel is not
pristine `ec5bb9e`.

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

## 0005: the ENA network driver

EC2 Nitro instances have one NIC, the Elastic Network Adapter (PCI
`1d0f:ec20`, also `0ec2`, `1ec2`, `ec21`). Asterinas has no driver for it,
so the image had no network on EC2 (`[init] no ethernet interface found`).
Patch 0005 adds `kernel/core/comps/ena`, a component crate of about 1000
lines, and teaches `net/iface/init.rs` to use it for `eth0` when there is
no virtio-net.

Design, following `ena_com.c` in Linux so the pieces map one to one:

- `regs.rs`: the BAR0 register map.
- `admin.rs`: device reset, "readless" MMIO (the device answers register
  reads by DMA into a host buffer; direct reads are the fallback), a
  32-entry admin queue polled without interrupts, `GET_FEATURE`,
  `SET_FEATURE`, `CREATE_CQ`, `CREATE_SQ`. The AENQ is allocated and
  registered because the device insists, but no event group is enabled.
- `io.rs`: 16-byte Tx/Rx descriptors, 8/16-byte completion descriptors,
  128-entry rings in `DmaCoherent` memory with phase-bit completion.
- `device.rs`: `AnyNetworkDevice` for one queue pair. Rx buffers are 4 KiB
  pool segments handed to the device by `req_id` and refilled on
  completion; the MTU is set to 1500 so no frame spans two buffers. Tx
  uses one descriptor per packet (no meta descriptor, no offloads: smoltcp
  computes every checksum). Doorbells: Tx on every send, Rx and the CQ
  heads at the end of each poll, then the interrupt is unmasked.
- Interrupts: MSI-X vector 1 for the queue pair (vector 0 would be the
  admin queue and stays masked). Because MSI-X delivery on Nitro had not
  been exercised by this kernel before, the driver also raises the network
  softirqs from the timer tick every 4 ms; both paths are idempotent and
  the tick only bounds latency if a message is lost.
- Diagnostics: `found ...` and `... ready` go through `early_println!`,
  so they appear at `loglevel=error`; if no ENA function is found the
  driver lists every unclaimed PCI function. Per-packet logging is at
  `debug`.

Measured on a t3.small: the lease arrives 1.6 s after power-on, BEAM is up
at 4.4 s, and `scripts/smoke-ec2.sh` passes 8 of 8 twice in a row (TCP and
TLS 1.3 echo from the internet, DNS and TLS client probes). Known limits:
one queue pair, no LLQ, no RSS, no checksum or segmentation offload, no
AENQ handling (link changes and keep-alives are ignored), no device reset
after a fatal error.

Lesson from building it: the ENA loop is build, publish, launch, read the
console, about six minutes per iteration and QEMU cannot shorten it (it
has no ENA model). Two of the five iterations were spent on a tooling
problem rather than the driver: `make ami` had silently rebuilt the kernel
from the patch directory while a stale untracked file made patch 0004
fail to apply, so the image on EC2 lacked both DHCP and ENA.
`scripts/build-asterinas.sh` now cleans the tree and aborts when a patch
does not apply.

## 0006: power-off fallback and `clock_settime`

Two unrelated small changes, both needed to run unattended on EC2.

Restart: `sys_reboot` existed, and the kernel already registered the ACPI
reset register and the i8042 controller as restart handlers (upstream's
`register_restart_handler!` registry, tried in descending priority). On
Nitro neither exists (no reset register in the FADT, no keyboard
controller), so `reboot(2)` fell through to `machine_halt` and the instance
sat there. The patch fills in `ostd::arch::power::try_restart` (upstream
left a TODO there) with a triple fault, the last resort Linux uses too: load
an empty IDT and `int3`. The kernel registers it at `Priority::LOW` and
moves the i8042 reset to `Priority::new(1)` so the order stays ACPI, i8042,
triple fault. A `Priority::LOW` power-off handler falls back to a restart:
without ACPI AML there is no S5 (until patch 0008), and a guest that asks
to power off should reboot instead of hanging with a dead console. Under
QEMU OSTD's `isa-debug-exit` handler is registered at `HIGH` and wins.

Wall clock: there was no `clock_settime`/`settimeofday`; the realtime clock
was boot time (from the RTC) plus the monotonic counter. The patch keeps
that and adds an atomic offset that `set_realtime` stores and all realtime
readers (the `CLOCK_REALTIME*` clocks and the vDSO bases) apply. Monotonic
clocks are untouched, as on Linux. `CAP_SYS_TIME` is required. Verified
with a 40-line C program: after `clock_settime(2000000000)`,
`clock_gettime`, `gettimeofday` (vDSO), `CLOCK_REALTIME_COARSE` and
`time()` all report it and `CLOCK_MONOTONIC` is unchanged. On Nitro the
firmware clock has been 0.4 to 2.7 s off at boot; `/init` corrects it with
SNTP from Amazon Time Sync.

## 0007: NVMe on EBS

Symptom: `nvme: Device initialization error: Err(CommandFailed)` on every
Nitro instance, after `Create I/O Completion Queue` (the third admin
command). The driver worked under QEMU.

Cause: the EBS controller advertises `CAP.MQES = 31` (32 queue entries);
the driver asked for 64, the controller answered "Invalid Field in Command"
(status `0x4205`, SC `0x02`). QEMU's model allows 2048. The driver also never
issued `Set Features (Number of Queues)`, which the spec requires before
creating I/O queues; EBS tolerates that, but the patch adds it since Linux
does it and other controllers enforce it.

Fix: read `CAP.MQES`, cap the I/O queue size at it, give each ring a
`depth` field so head/tail/phase wrap at the negotiated size while the
storage stays `QUEUE_DEPTH`, and log `CAP` plus any rejected admin command
through `early_println!` so the next controller quirk is visible at
`loglevel=error`. Result: `/dev/nvme1n1` (a data volume on `/dev/sdf`)
mounts as ext2 on a t3.small and the boot counter survives a reboot.

A second fix landed in the same patch later: under write load (`File.write`
plus a concurrent `sync`) the driver panicked with "SQ `free_slots`
indicated space for this `submit_with_items`". The device advances the SQ
head when it *fetches* a command, before the completion arrives, so
`free_slots()` can report a slot whose request is still outstanding;
`submit_with_items` then refused it and the caller `expect`ed success.
It now enqueues what fits, hands the rest back, and the caller waits for
completions. The driver keeps one I/O queue: EBS limits the depth (32),
not the count, and gp3's baseline IOPS are served fine by it.

## 0008: ACPI power button and S5

Symptom: `aws ec2 stop-instances` left the instance in `stopping` for four
minutes and `reboot-instances` took as long; both only completed when EC2
gave up and hard-reset. EC2 implements both by pressing the ACPI power
button; the kernel had no idea the button existed, and `poweroff` could at
best reset the machine (patch 0006), which `stop-instances` does not accept.

The patch adds two things, both without an AML interpreter:

- `ostd` collects the PM1a/PM1b event and control ports from the FADT and
  scans the DSDT and every SSDT for `Name (_S5_, Package {...})`, reading
  the two sleep-type constants. Nitro keeps `_S5` in an SSDT with sleep type
  `(0, 0)`; QEMU has it in the DSDT, also `(0, 0)`. Unparsed or missing
  encodings are printed as raw bytes so the next firmware can be added.
- `kernel/core/src/arch/x86/power.rs` enables `PWRBTN_EN`, polls
  `PM1_STS.PWRBTN_STS` from the timer tick every 50 ms (the SCI stays masked
  at the IOAPIC, so no interrupt routing is needed), clears it and sends
  `SIGPWR` to PID 1, at most once per 5 s. A power-off handler at
  `Priority::FIRMWARE` writes `SLP_TYP` and
  `SLP_EN` to the PM1 control registers before falling back to a reset.

A side fix in `ostd`: the "running in QEMU" check accepted the `KVMKVMKVM`
hypervisor signature, which Nitro also presents, so the QEMU
`isa-debug-exit` handler was installed on EC2 and shadowed the ACPI path.
It now also requires the firmware OEM ID `BOCHS `.

`/init` handles `SIGPWR` by sending `SIGTERM` to `beam.smp` (ERTS runs
`init:stop/0`), waiting up to 20 s, then powering off; on Linux it watches
`/dev/input/event*` for `KEY_POWER` instead, since that kernel reports the
button as an input event. Measured on a t3.small: `stop-instances` reaches
`stopped` in 14 to 20 s, `reboot-instances` is back with the next boot in
41 to 48 s, on both kernels.

## 0009: ENA driver, second round

Patch 0005 was the minimum that passes traffic. 0009 adds what a service
behind a load balancer needs; all of it in `kernel/core/comps/ena`.

- **AENQ.** Link change, fatal error, warning, notification and keep-alive
  groups are enabled; the queue is drained every 100 ms. A keep-alive
  arrives every second; after 6 s without one (Linux's `KALIVE_TIMEOUT`)
  the driver resets the device. The admin interrupt stays masked and the
  AENQ is polled (`ena.aenq_irq=1` unmasks it; with it unmasked the guest
  hung after a reset, see below).
- **Reset path.** `AdminQueue::reinit` resets the device and re-programs
  the admin queue; the queue pairs, Rx buffers, RSS and AENQ are then
  rebuilt. Resets are *requested* from the health check and *performed* in
  the network softirq. `ena.test_reset=SECONDS` forces one. Measured on a
  t3.small: 2 ms for the reset, and the device's own counters (`GET_STATS`)
  start moving again within 10 s, after which TCP from the internet works.
  If they do not move while the stack is sending, the driver reboots the
  machine, which is known to restore service.
- **Checksum offload.** `STATELESS_OFFLOAD_CONFIG` is queried; for IPv4
  TCP/UDP frames the driver writes the pseudo-header sum into the L4
  checksum field (Linux's `CHECKSUM_PARTIAL`), sends one cached meta
  descriptor per queue with the header geometry and sets
  `L4_CSUM_EN|L4_CSUM_PARTIAL`. smoltcp's checksum capabilities are set to
  `None` for TCP/UDP when the device also verifies on Rx; frames the device
  flags bad are dropped. Getting the pseudo-header right mattered: with the
  full checksum left in place the device produced wrong sums and every TLS
  handshake stalled.
- **Queue pairs and RSS.** `ena.queues=N|auto` (default `auto`: one per
  vCPU, max 8). Each pair has its own MSI-X vector; Rx is drained round
  robin; Tx is steered by a hash of the IPv4 5-tuple so one connection
  stays on one queue. RSS: Toeplitz over the same tuple, 128-entry
  indirection table over the Rx completion queues. The first version
  alternated Tx queues per packet, which reorders a flow's segments on the
  wire and halved single-flow throughput (34 to 51 MB/s with two pairs vs
  77 to 108 with one); with flow steering two pairs measure 77 to 95 MB/s,
  one pair 70 to 108, on t3.small and t3.medium, so multi-queue is the
  default. The echo benchmark is BEAM-bound at that level (1 KiB lines),
  the NIC has headroom.
- **Tx completion accounting** counts the descriptors each request used
  (meta + data) instead of trusting `sq_head_idx`.

Two things learnt the expensive way. First: never do MMIO reads or admin
commands from the timer interrupt. The first version polled the AENQ and
read `DEV_STS` from the tick while holding the device lock; a readless MMIO
read can take milliseconds, and about one boot in five stalled right after
DHCP with the network softirq locked out. Moving the health work into the
softirq (the tick only sets a flag and raises it) fixed it. Second: a
device that passes no traffic after a reset is not necessarily broken; the
Nitro ENA needs a few seconds before its data path is live again, and
hammering it with `GET_STATS` in that window made it worse.

`aster-bigtcp` gains `TxPacket::data_writer` for the in-place checksum
patch.

## Reporting upstream

The patches are `git diff` output against `ec5bb9e`, apply in order with
`git apply`, and some depend on earlier ones (0004 on 0003, 0005 and 0009
on 0003/0004, 0008 on 0006). `scripts/upstream-branches.sh` turns them into
commits on the fork `github.com/bmalum/asterinas`, one topic branch per
upstreamable unit (`fix/bind-unspecified-address`,
`fix/timerfd-settime-readiness`, `feat/net-runtime-ifconfig-dhcp`,
`feat/ena-driver`, `feat/x86-poweroff-clock-settime`,
`fix/nvme-mqes-number-of-queues`, `feat/acpi-power-button-s5`) plus
`elixir-unikernel-all`; the commit messages are these sections.

Pull requests against `asterinas/asterinas`, opened 2026-10-10:

| Patches | PR |
|---|---|
| 0001 | [#3983](https://github.com/asterinas/asterinas/pull/3983) bind() to 0.0.0.0 |
| 0002 | [#3984](https://github.com/asterinas/asterinas/pull/3984) timerfd readiness |
| 0003, 0004 | [#3988](https://github.com/asterinas/asterinas/pull/3988) runtime ifconfig, DHCP |
| 0005, 0009 | [#3989](https://github.com/asterinas/asterinas/pull/3989) ENA driver (on top of #3988) |
| 0006 | [#3986](https://github.com/asterinas/asterinas/pull/3986) reboot fallback, clock_settime |
| 0007 | [#3985](https://github.com/asterinas/asterinas/pull/3985) NVMe on EBS |
| 0008 | [#3987](https://github.com/asterinas/asterinas/pull/3987) ACPI power button, S5 (on top of #3986) |

Upstream CI (`make check`) runs rustfmt and clippy with warnings as errors;
the patches are formatted with `tools/format_all.sh` and clippy-clean as of
the 2026-07-21 nightly (`is_multiple_of`, let chains, `while let`). Two
tests in that CI are known flaky and unrelated to these changes:
`ostd::arch::vm::vmx::vmcs::test::switch_and_reuse_vmcs` (ktest) and LTP
`epoll_wait04` (a 5 ms timing bound under TCG).

When one is merged upstream, bump `ASTERINAS_REF` and delete the patch;
`build-asterinas.sh` fails loudly if a remaining patch no longer applies. 0005 is a new crate
rather than a fix and would go upstream as a pull request adding
`kernel/core/comps/ena` plus the two-driver selection in `iface/init.rs`. To send them: open issues on
[asterinas/asterinas](https://github.com/asterinas/asterinas) with the C
reproducer for 0002 and the `gen_tcp:listen` reproducer for 0001; the
project's `CONTRIBUTING` asks for a regression test under
`test/initramfs/src/regression`. If upstream fixes land, bump `ASTERINAS_REF`
and delete the patch; `build-asterinas.sh` fails loudly if a patch no longer
applies.
