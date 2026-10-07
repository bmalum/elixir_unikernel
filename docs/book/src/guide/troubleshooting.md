# Troubleshooting

Start by deciding which side of the syscall boundary is at fault: boot the
same image on Linux with `make run-m0-app`. If it works there and not on
Asterinas, it is a kernel gap; if it fails on both, it is the image or the
application.

## Nothing after `Booting from ROM..`

Asterinas: the guest has less than 144 MB (`M1_MEM`). The kernel is loaded at
physical 128 MB and needs room above that. Also check that `earlycon` is on
the command line; without it early output is lost.

Linux: with less than 128 MB the kernel OOM-kills `erl_child_setup` and
panics ("System is deadlocked on memory"); the console shows it.

## `[init] execv ... No such file or directory`

The ERTS version compiled into `/init` (`-DERTS_VSN=`) does not match the
release. The Dockerfile derives it from `/opt/otp-x86/ERTS_VSN`; if you
changed OTP versions, rebuild from the `release` stage (`make release`).

## `Environment variable BINDIR is not set`

`/init` was not used (for example the kernel ran `beam.smp` directly). ERTS
needs `BINDIR` to find `erl_child_setup`.

## `Can not execute .../inet_gethost : enoent`

The resolver fell back to `native` lookup. `/etc/inetrc` is missing or
`ERL_INETRC` is not exported. Both are written by `/init`; check the console
for a `write /etc/inetrc` error.

## DNS resolves nothing (`nxdomain` for everything)

`/etc/resolv.conf` is missing. OTP's `inet_db` re-reads it periodically and
clears the nameserver list when the file does not exist, even if `inetrc`
named a server. `/init` writes it from `uniapp.dns=`.

## `{:error, :eaddrnotavail}` from `listen` or `open`

On Asterinas v0.18.1 and unpatched `main`, `bind()` to `0.0.0.0` fails. Make
sure the kernel was built by `scripts/build-asterinas.sh` (it applies
`0001-bind-unspecified-to-default-iface.patch`); the build log prints
`applied 0001-...`.

## The VM is alive but IEx never prints a prompt, or the app stalls

Before patch `0002-timerfd-settime-invalidate-readiness`, Asterinas kept
reporting an already-disarmed `timerfd` as readable, and ERTS's poll thread
spun at 100 % on `epoll_wait`. The symptom was a stall at random points,
always with one vCPU. Check the build log for `applied 0002-...`. The C
reproducer is described in [Asterinas patches](../internals/asterinas-patches.md).

## `make smoke-*` says `host port 14443 is in use`

A previous QEMU is still running, or something else listens on the forwarded
port. `pkill qemu-system-x86_64`, or set `HOST_PORT_TLS=24443` (and the TCP
and UDP variants).

## `TCP False` in the client log while the guest says `LISTEN tcp`

Something on the host already listens on `HOST_PORT_TCP` (a local
`iex -S mix`, for example), so the client connected to it instead of the
guest. The port guard catches TCP and TLS; UDP has no `LISTEN` state and is
not checked.

## `Segmentation fault` while compiling OTP, `collect2` or `cc1` crashes

You are running x86-64 containers under Rosetta (Apple Silicon with
`--platform linux/amd64`). The current Dockerfile does not do that: it builds
natively and cross-compiles only ERTS with clang. If you re-enabled an
emulated path, expect random compiler crashes.

## `beam.smp` segfaults immediately, even on Linux

A `beam.smp` linked with `-static` that still has a `PT_DYNAMIC` segment
(`readelf -l`). OTP's `erts/configure` hardcodes
`LIBZSTD="-Wl,-Bstatic -lzstd -Wl,-Bdynamic"`; the trailing `-Bdynamic` makes
lld link libc dynamically into the "static" binary. The Dockerfile patches it
to `-lzstd` before configure.

## Where to look

- `build/logs/*.log.clean`: console transcripts from the last smoke run.
- `build/asterinas-build.log`, `build/release-build.log`: build output.
- QEMU monitor (`Ctrl-a c`, then `info registers -a`) for a stuck guest.
- `uniapp.mode=erl uniapp.eval="..."`: run an Erlang expression at boot
  without the Elixir CLI, for example
  `uniapp.eval="io:format('~p~n',[inet:getifaddrs()])"` (no double quotes
  inside the value).
