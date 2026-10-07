# Kernel command line

`/init` reads `/proc/cmdline` and copies it to the `KERNEL_CMDLINE`
environment variable for the application. Values may be quoted with double
quotes if they contain spaces; a value cannot itself contain a double quote.

| Key | Default | Meaning |
|---|---|---|
| `uniapp.mode=iex\|app\|erl` | `iex` | IEx shell, application only (`-noshell`), or plain Erlang shell |
| `uniapp.code=embedded\|interactive` | `interactive` | ERTS code loading mode. `embedded` loads every module of the boot script at start (the Mix release default) and roughly doubles RSS; `interactive` loads on demand |
| `uniapp.ip=A.B.C.D/N` | `10.0.2.15/24` | address of the first NIC |
| `uniapp.gw=A.B.C.D` | `10.0.2.2` | default route |
| `uniapp.dns=A.B.C.D` | `10.0.2.3` | nameserver, written to `/etc/resolv.conf` |
| `uniapp.tls_host=HOST` | unset | sample app only: enables the DNS and TLS 1.3 client probes against `HOST:443` |
| `uniapp.emu="FLAGS"` | unset | extra `beam.smp` emulator flags, space separated. Note that `erl +X` is spelled `-X` here (`erlexec` does the translation normally), e.g. `uniapp.emu="-S 1 -sbwt none"` |
| `uniapp.eval="EXPR."` | unset | an Erlang expression passed as `-eval`, run during boot. Debugging aid |

Kernel-side keys that matter:

| Key | Linux | Asterinas |
|---|---|---|
| `console=ttyS0` | required for serial output | required |
| `earlycon` | optional | required to see output before the console driver is up |
| `loglevel=N` | kernel verbosity | `error`, `info`, `debug` (a word, not a number) |
| `rdinit=/init` | tells Linux to run our init | default is `/init` already |
| `quiet` | suppresses boot messages | ignored |

Sample app environment (set in the `release` stage or by `/init`):

| Variable | Meaning |
|---|---|
| `UNIAPP_LOG_LEVEL` | Logger level, read by `config/runtime.exs` |
| `UNIAPP_ECHO_PORT` | TCP echo port (UDP uses port + 1); default 4000 |
| `UNIAPP_CACERTS` | CA bundle path for the TLS client probe; default `/etc/ssl/cacert.pem` |
