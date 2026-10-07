# elixir_unikernel

elixir_unikernel turns a `mix release` into a bootable machine image that runs
on a memory-safe kernel written in Rust. There is no Linux userland in the
image: no shell, no init system, no dynamic loader. The kernel starts a 300
line static C program, `/init`, which configures the network interface and
`exec`s `beam.smp`. From then on the Erlang VM is the only process.

```text
Booting from ROM..
[kernel] running /init as the init process
[init] elixir_unikernel init, uptime 0.450 s
[init] net: eth0 10.0.2.15/24 gw 10.0.2.2
[init] exec /rel/erts-17.1/bin/beam.smp (iex mode)
Erlang/OTP 29 [erts-17.1] [source] [64-bit] [smp:2:2] [ds:2:2:10] [async-threads:1] [jit:ns]
13:01:08.809 [info] uniapp starting (otp 29, elixir 1.20.4, uptime 3.80s)
Interactive Elixir (1.20.4) - press Ctrl+C to exit (type h() ENTER for help)
iex(1)>
```

## What you get

- A 9.4 MB `initramfs.cpio.gz` containing Erlang/OTP 29.1.1 with a fully
  static `beam.smp`, Elixir 1.20.4, and your release. OpenSSL 3.5 is linked
  into the VM, so `:crypto`, `:ssl` and `:public_key` work out of the box.
- A 5.8 MB [Asterinas](https://asterinas.github.io) kernel: Linux-ABI
  compatible, written in Rust, with virtio-net and a TCP/IP stack.
- A `make` based build that pins every upstream by git tag and a smoke test
  that boots the image and checks TCP, UDP, TLS 1.3 (client and server) and
  DNS over virtio-net.
- The same image also boots on a stock Linux kernel, which is useful for
  telling kernel problems from application problems.

## What it is not

It is not a unikernel in the strict sense. The kernel and the BEAM are two
binaries with a syscall boundary between them. What is removed is everything
else: the image is a kernel plus one process. If you want a single linked
binary, see [Why these kernels](internals/kernels.md) for the Hermit track.

It also is not a general purpose OS. There is no persistent storage, no
distribution/`epmd`, and no way to spawn external programs because there are
none. See [Limits](reference/limits.md).

## Where to go next

- [Prerequisites](getting-started/prerequisites.md) and
  [Build and first boot](getting-started/first-boot.md) get you to an IEx
  prompt in about 15 minutes on a cold cache.
- [Shipping your own application](guide/your-app.md) replaces the sample app.
- [Architecture](internals/architecture.md) explains how the pieces fit.
