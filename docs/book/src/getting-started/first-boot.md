# Build and first boot

```sh
git clone https://github.com/mkarrer/elixir_unikernel.git
cd elixir_unikernel
make check          # host prerequisites
make initramfs      # ~6 min cold, ~1 min when OTP/Elixir layers are cached
make run-m1         # build the Asterinas kernel (~4 min cold) and boot into IEx
```

`make initramfs` builds four Docker stages: an x86-64 Alpine sysroot, a
cross-compiled OTP tree, a native OTP (so Elixir and Mix run at full speed),
and the release. The output is `build/initramfs.cpio.gz`.

`make run-m1` compiles Asterinas inside its upstream development container,
applies the two patches from `builder/asterinas-patches/`, and starts QEMU:

```text
Booting from ROM..OSTD initialized. Preparing components.
...
[kernel] unpacking initramfs.cpio.gz to rootfs ...
[kernel] running /init as the init process
[init] elixir_unikernel init, uptime 0.450 s
[init] net: eth0 10.0.2.15/24 gw 10.0.2.2
[init] exec /rel/erts-17.1/bin/beam.smp (iex mode)
Erlang/OTP 29 [erts-17.1] [source] [64-bit] [smp:2:2] [ds:2:2:10] [async-threads:1] [jit:ns]
Interactive Elixir (1.20.4) - press Ctrl+C to exit (type h() ENTER for help)
iex(1)>
```

Type an expression:

```elixir
iex(1)> :inet.getifaddrs()
iex(2)> :ssl.connect(~c"www.erlang.org", 443, [verify: :verify_peer, cacertfile: ~c"/etc/ssl/cacert.pem"])
```

Leave QEMU with `Ctrl-a` followed by `x`.

The `[init]` lines about `Not a tty` on Asterinas are expected: that kernel
does not implement the interface-configuration ioctls and configures
10.0.2.15/24 itself. `/init` logs and continues. See
[Networking](../guide/networking.md).

## Application mode

```sh
make run-m1-app
```

boots the same image with `uniapp.mode=app`: no shell, the release's
application starts under its supervision tree, and the sample app prints a
few self-test lines:

```text
LISTEN udp 4001
LISTEN tcp 4000
LISTEN tls 4443
PROBE dns ok
PROBE tls ok
PROBE done
```

While it runs, talk to it from another terminal:

```sh
printf 'hello\n' | nc 127.0.0.1 14000                                   # TCP echo
printf 'ping' | nc -u -w1 127.0.0.1 14001                               # UDP echo
(echo tls-hello; sleep 1) | openssl s_client -connect 127.0.0.1:14443 -tls1_3 -quiet
```

QEMU forwards host ports 14000, 14001 and 14443 to the guest's 4000, 4001 and
4443.

## The same image on Linux

```sh
make run-m0
```

boots `build/initramfs.cpio.gz` on a stock Linux 6.1 kernel (the Firecracker
CI build, which has virtio and the serial console compiled in). Nothing in the
image is Linux specific; this target exists so that a failure can be blamed on
the right side of the syscall boundary.
