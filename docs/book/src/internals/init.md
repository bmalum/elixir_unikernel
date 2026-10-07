# The init program

`init/init.c` is PID 1. It is about 300 lines of C, statically linked against
musl, compiled for x86-64 with clang in the `release` Docker stage. It
replaces the release's shell script, `erlexec`, and an init system.

## Steps

1. `mount` `proc` on `/proc`, `devtmpfs` on `/dev`, `sysfs` on `/sys`.
   Failures are logged and ignored (Asterinas has no `devtmpfs`; it populates
   `/dev` itself).
2. Read `/proc/cmdline`. `param(key)` returns the value of `key=value`,
   honouring double quotes.
3. Network: bring `lo` up with 127.0.0.1, find the first non-`lo` interface
   (`SIOCGIFCONF`, then `/sys/class/net`, then common names), set address,
   netmask and flags (`SIOCSIFADDR`, `SIOCSIFNETMASK`, `SIOCSIFFLAGS`), add
   the default route (`SIOCADDRT`). Each ioctl failure is logged with its
   `errno` and ignored, because Asterinas configures the interface itself.
4. Write `/etc/inetrc` (`{lookup,[file,dns]}`, so OTP never looks for
   `inet_gethost`), `/etc/resolv.conf` (the nameserver; `inet_db` reads this
   file and clears nameservers if it is missing) and `/etc/hosts`.
5. Export the environment: `ROOTDIR`, `BINDIR` (ERTS uses it to locate
   `erl_child_setup`; a missing `BINDIR` is fatal), `EMU`, `PROGNAME`,
   `HOME`, `LANG=C.UTF-8`, `TERM=dumb`, `RELEASE_ROOT`, `RELEASE_NAME`,
   `RELEASE_VSN`, `RELEASE_MODE`, `RELEASE_NODE`, `RELEASE_SYS_CONFIG`,
   `ERL_CRASH_DUMP=/dev/null`, `KERNEL_CMDLINE`.
6. Build the argument vector and `execv` `beam.smp`. If `exec` fails, log,
   sleep 5 s, power off.

## The argument vector

`erlexec` normally produces this; the layout matters because `beam.smp` and
`init` parse different sections.

```text
beam.smp
  -Bd                      emulator flags (erl's +X flags are -X here)
  [uniapp.emu flags]
  --                       end of emulator flags
  -root /rel -bindir /rel/erts-17.1/bin -progname erl
  --
  -home /
  --                       end of system flags, start of init flags
  -boot /rel/releases/0.1.0/start
  -boot_var RELEASE_LIB /rel/lib
  -mode interactive|embedded
  -config /rel/releases/0.1.0/sys
  -noshell                 (not in erl mode)
  [-eval EXPR]
  -user elixir -extra --no-halt +iex          iex mode
  -s elixir start_cli -extra --no-halt         app mode
```

`+Bd` disables the BREAK handler so `Ctrl-C` on the serial console does not
open the menu. `-user elixir` is what `bin/iex` passes; `-s elixir start_cli`
is what `bin/elixir` passes. Both were read from Elixir's `bin/elixir`
script at the pinned tag.

## Compile-time constants

`RELEASE_ROOT` (`/rel`), `RELEASE_NAME` (`uniapp`), `RELEASE_VSN` (`0.1.0`)
have defaults in the source; `ERTS_VSN` must be passed with `-D` and the
Dockerfile reads it from the cross OTP tree so it always matches the shipped
`beam.smp`.

## Why C and not Rust or Erlang

It is 300 lines that do five ioctls and an `exec`. A static C binary is 40
KB, builds in a second with the cross clang that is already in the image, and
has no runtime of its own to debug. Rust would be equally fine and larger;
Erlang cannot run before `beam.smp` is running.
