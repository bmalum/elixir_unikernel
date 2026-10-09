# Kernel command line

`/init` reads `/proc/cmdline` and copies it to the `KERNEL_CMDLINE`
environment variable for the application. Values may be quoted with double
quotes if they contain spaces; a value cannot itself contain a double quote.

| Key | Default | Meaning |
|---|---|---|
| `uniapp.mode=iex\|app\|erl` | `iex` | IEx shell, application only (`-noshell`), or plain Erlang shell |
| `uniapp.code=embedded\|interactive` | `interactive` | ERTS code loading mode. `embedded` loads every module of the boot script at start (the Mix release default) and roughly doubles RSS; `interactive` loads on demand |
| `uniapp.ip=A.B.C.D/N` | DHCP | static address of the first NIC (disables DHCP) |
| `uniapp.gw=A.B.C.D` | from DHCP | default route |
| `uniapp.dns=A.B.C.D` | from DHCP | nameserver, written to `/etc/resolv.conf` |
| `uniapp.tls_host=HOST` | unset | sample app only: enables the DNS and TLS 1.3 client probes against `HOST:443` |
| `uniapp.emu="FLAGS"` | unset | extra `beam.smp` emulator flags, space separated. Note that `erl +X` is spelled `-X` here (`erlexec` does the translation normally), e.g. `uniapp.emu="-S 1 -sbwt none"` |
| `uniapp.eval="EXPR."` | unset | an Erlang expression passed as `-eval`, run during boot. Debugging aid |
| `uniapp.on_exit=reboot\|poweroff\|halt` | `reboot` | what `/init` does when `beam.smp` exits on its own. `reboot` re-runs the image (what an auto-scaling group wants from a crashed node); under QEMU with `-no-reboot` it ends the VM. A power button press always powers off |
| `uniapp.halt_after_first_boot=MS` | unset | sample app, test hook: exit the VM `MS` ms into the first boot of a data volume (`boot_count` 1) so a test can watch the restart path |
| `uniapp.imds=1` | unset | EC2: query IMDSv2 for identity (`EC2_INSTANCE_ID`, `AWS_REGION`, ... in the environment) and user data. User-data lines `key=value` override command-line keys; the raw user data is in `/run/user-data` |
| `uniapp.ntp=A.B.C.D\|off` | Amazon Time Sync when `imds=1`, else off | SNTP server; the clock is set at boot and resynced hourly |
| `uniapp.data=auto\|/dev/X\|off` | unset | mount an ext2 data volume read-write at `/data` (`auto`: the first block device that mounts); exports `UNIAPP_DATA=/data`, crash dumps go to `/data/erl_crash.dump` |
| `uniapp.cloudwatch=1` | unset | sample app: ship the log to CloudWatch Logs and publish EMF metrics using the instance role (needs `imds=1`) |
| `uniapp.log_group=NAME` | `/elixir_unikernel` | CloudWatch log group; the stream is the instance id |
| `uniapp.health_port=N` | `8080` | sample app: port of `/healthz` and `/livez` |
| `uniapp.bench_peer=A.B.C.D` | unset | sample app: after boot, push 8 MB through that host's TCP echo and print `BENCH tcp_echo_peer` (`uniapp.bench_delay_ms`, default 30000) |
| `uniapp.metric_namespace=NAME` | `elixir_unikernel` | CloudWatch namespace for `BootCount`, `Uptime`, `MemoryTotal`, `ProcessCount` |

Keys from EC2 user data are read before the kernel's own line, so
`uniapp.mode=iex` in user data turns an `app` image into an IEx one without
rebuilding the AMI.

Kernel-side keys that matter:

| Key | Linux | Asterinas |
|---|---|---|
| `console=ttyS0` | required for serial output | required |
| `earlycon` | optional | required to see output before the console driver is up |
| `loglevel=N` | kernel verbosity | `error`, `info`, `debug` (a word, not a number) |
| `rdinit=/init` | tells Linux to run our init | default is `/init` already |
| `ip=dhcp` | ignored (`/init` does DHCP itself) | in-kernel DHCP client on `eth0`, lease in `/proc/net/dhcp` |
| `ena.queues=N\|auto` | n/a | ENA queue pairs (default 1; `auto` = one per vCPU, max 8). Kernel parameter: must be on the kernel command line (`ENA_ARGS`), not in user data |
| `ena.offload=0` | n/a | ENA: software checksums instead of offload |
| `ena.test_reset=SECONDS` | n/a | ENA: force one device reset after boot (tests the recovery path) |
| `ena.aenq_irq=1` | n/a | ENA: unmask the admin interrupt (default polled) |
| `quiet` | suppresses boot messages | ignored |

Sample app environment (set in the `release` stage or by `/init`):

| Variable | Meaning |
|---|---|
| `UNIAPP_LOG_LEVEL` | Logger level, read by `config/runtime.exs` |
| `UNIAPP_ECHO_PORT` | TCP echo port (UDP uses port + 1); default 4000 |
| `UNIAPP_CACERTS` | CA bundle path for the TLS client probe; default `/etc/ssl/cacert.pem` |
