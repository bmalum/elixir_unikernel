# Booting and the console

The image boots in one of three modes, chosen on the kernel command line.

| `uniapp.mode=` | What starts | Use |
|---|---|---|
| `iex` (default) | the release's applications, then IEx on the serial console | development, inspection |
| `app` | the release's applications with `-noshell` | production |
| `erl` | the applications, then a plain Erlang shell | debugging when Elixir's CLI itself is the problem |

The boot sequence is the same in every mode:

1. The kernel unpacks the initramfs into its root file system and runs
   `/init` as PID 1.
2. `/init` mounts `proc`, `devtmpfs` and `sysfs` where the kernel supports
   them, reads `/proc/cmdline`, configures `lo` and the first ethernet
   interface, writes `/etc/inetrc`, `/etc/resolv.conf` and `/etc/hosts`,
   exports the environment ERTS expects (`BINDIR`, `ROOTDIR`, `RELEASE_*`,
   `LANG=C.UTF-8`, `TERM=dumb`), and `exec`s `beam.smp`.
3. ERTS loads the release boot script (`releases/<vsn>/start.boot`) and
   `sys.config`, starts the applications, and in `iex` mode starts
   `user_drv` with Elixir's shell.

There is no process other than the BEAM. ERTS does spawn its `erl_child_setup`
helper at start (it is needed for `Port`s); it is the only other binary in the
image and it idles.

## The serial console

All output goes to the first serial port (`console=ttyS0`), which QEMU
connects to your terminal with `-nographic`. Input works the same way, so IEx
is fully usable: history, tab completion and line editing work because
`prim_tty` sees a tty.

`TERM` is set to `dumb` because the image contains no terminfo database.
Colours and the fancy prompt are therefore off; set `uniapp.term=xterm` is not
supported yet.

`Ctrl-C` does not open the BREAK menu (ERTS runs with `+Bd`). `Ctrl-a x` exits
QEMU. `Ctrl-a c` switches to the QEMU monitor, where `info registers` or
`system_powerdown` are available.

## Logs

The release's `Logger` writes to standard output, which is the console. In
`app` mode that is the only output channel. If you need logs elsewhere, ship
them over the network from your application; there is no syslog and no disk.

The log level can be set at boot with the `UNIAPP_LOG_LEVEL` environment
variable, which the sample `config/runtime.exs` reads; `/init` does not set
it, so add a command-line switch if you need one (see
[The init program](../internals/init.md)).

## Exit and reboot

`System.stop/0` or `:init.stop/0` halts the VM. Because `beam.smp` is PID 1,
the kernel then has no init process: Linux panics with "Attempted to kill
init", Asterinas prints a message and halts. Either way QEMU stays running
until you quit it (the Makefile passes `-no-reboot`). A clean power-off from
inside the guest is not implemented yet.

Crash dumps are disabled (`ERL_CRASH_DUMP=/dev/null`): there is nowhere to
write them and a crash on a read-only initramfs would otherwise stall for the
dump. The crash reason is still printed to the console.
