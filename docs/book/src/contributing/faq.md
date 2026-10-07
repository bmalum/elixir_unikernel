# FAQ

**Is this a unikernel?**
Not strictly. It is a kernel and one process with a syscall boundary between
them. Everything else a Linux distribution ships is gone. A single-binary
version on Hermit is the stretch goal ([Why these kernels](../internals/kernels.md)).

**Why not just use a minimal Linux (Alpine, Nerves, Firecracker)?**
You can, and `make run-m0` shows the same image doing exactly that. The point
of the project is the memory-safe kernel underneath and the discipline of an
image with three static binaries. The Linux path is kept as the control group.

**Why not Nerves?**
Nerves is Linux (Buildroot) plus the BEAM as the main process, with a full
userland underneath (busybox, erlinit). It is production-proven and the right
answer for most embedded Elixir. This project removes the userland and swaps
the kernel.

**Can I run Phoenix?** Yes, see [A Phoenix application](../guide/phoenix.md).
Pure-BEAM dependencies only.

**Can I use NIFs?** Only if they are linked statically into `beam.smp`, the
way `crypto` is. Runtime `dlopen` is not possible.

**Does it do DHCP?** No. The address comes from the kernel command line
(`uniapp.ip=`), and on Asterinas it is currently compiled into the kernel.

**Can two images talk over Erlang distribution?** Not yet: there is no
`epmd`, and distribution is a non-goal of the MVP. `-proto_dist` with a
custom EPMD module would be the way.

**How do I get logs out?** The console is the only output. Ship logs over the
network from the application.

**Why does IEx have no colours?** `TERM=dumb`, because there is no terminfo
database in the image.

**How big is it really?** 9.4 MB image plus 5.8 MB kernel. The VM needs 144 MB
of RAM on Asterinas (kernel load address), 128 MB on Linux. `beam.smp` uses
about 62 MB RSS idle.

**Why is boot 3 to 4 seconds here when the goal says 2?** Those numbers are
from QEMU TCG on an Apple Silicon host, emulating x86-64 instruction by
instruction. With KVM the BEAM's JIT warm-up is a fraction of that; not yet
measured.

**Does it run on real hardware?** Untested. Asterinas boots on x86-64 machines
with virtio or supported NICs; nothing in the image cares.

**Why Alpine for the toolchain?** musl, and `apk --arch x86_64 --root` gives a
complete x86-64 sysroot with static OpenSSL in one command, which is what
makes the native-plus-cross build simple.

**Can I build on an x86-64 machine?** Yes; the same Dockerfile runs natively
there and the "cross" step is a no-op in spirit (it still produces a static
build against the sysroot).
