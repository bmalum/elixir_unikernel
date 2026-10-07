# Why these kernels

The research behind the kernel choice is in `docs/RESEARCH.md` in the
repository; this is the short version.

## What ERTS needs from a kernel

Threads with futexes, `mmap`/`munmap` (and optionally `mremap`), `epoll` or
`poll`, `timerfd`, `eventfd`, pipes, Unix socket pairs, `fork`+`execve` for
the `erl_child_setup` helper that ERTS starts unconditionally, BSD sockets
with `sendmsg`/`recvmsg`, `getrandom` or `/dev/urandom`, a file system to
load `.beam` files from, signals, and a tty for the shell. It does not need
`dlopen` when NIFs are linked statically.

## Asterinas (chosen)

A Linux-ABI compatible kernel written in Rust with a small unsafe core
("framekernel"), 245 syscalls on x86-64 at the pinned commit, virtio-net with
a TCP/IP stack, initramfs, ramfs, ext2, SMP. An unmodified static musl
`beam.smp` runs on it as PID 1. The project ships a Docker development
container and a build tool (`cargo osdk`), moves fast, and the two gaps we
hit were fixable with a few lines each. MPL-2.0.

Trade-offs: it is a kernel/user split, not a single binary; its memory floor
is set by the fixed load address (128 MB) rather than by our image; it is
pre-1.0 and some socket options and ioctls are missing.

## Hermit (future, M3)

A true unikernel in Rust: the application is linked into `libhermit.a` and
boots as one image. It has threads, futexes, `mmap`, `poll`, sockets over
smoltcp and virtio-net, but no `fork`/`execve`, no `pipe`/`socketpair`, no
`select`, no `sigaction`, and a Newlib-based libc. Running ERTS on it means
patching ERTS (the `erl_child_setup` forker as a thread, pipe emulation, no
`mremap`), porting OTP's and OpenSSL's configure to an `x86_64-hermit` target,
and populating its memfs from an embedded archive. The nanovms/erlang patch
set for the Nanos unikernel is the closest prior art. Months, not weeks.
Everything in this repository (release layout, `/init` semantics, smoke tests)
carries over and becomes the regression baseline.

## Considered and rejected

Theseus (no POSIX), Redox (microkernel with relibc, a different porting
effort), kerla and maestro (stale or immature), Unikraft, Nanos and OSv (not
Rust). A BEAM reimplemented in Rust (BOSS, enigma, AtomVM-style) is a
different project: it gives up unmodified OTP, which is the point here.

## The Linux reference kernel

`make run-m0` boots the same initramfs on a stock Linux 6.1 built by the
Firecracker project for its CI (virtio, serial console and initramfs support
compiled in, no modules). It is only a debugging aid: anything that works on
Linux and fails on Asterinas is a kernel issue, and vice versa. Alpine's
`linux-virt` was tried first and rejected because it ships `virtio_net` as a
module, which would have forced Linux-only files into the image.
