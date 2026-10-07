# Running the tests

```sh
make smoke-m0     # Linux, ~3 min under TCG
make smoke-m1     # Asterinas, ~3 min
make smoke        # release + both kernels + both smoke tests + sizes, ~12 min cold
```

`scripts/smoke.sh` boots the image twice per kernel and checks the GOALS.md
criteria:

Application mode

- `/init` exec'd `beam.smp`, the application started, no shell appeared
- the TCP, UDP and TLS echo servers report `LISTEN`
- from the host, through the QEMU port forwards: a TCP echo round trip, a UDP
  echo round trip, and a TLS 1.3 session with `openssl s_client` that echoes a
  line
- inside the guest: `PROBE dns ok` (a lookup through OTP's pure-Erlang
  resolver `inet_res`) and `PROBE tls ok` (`:ssl.connect` with
  `verify_peer` against the bundled CA store to `TLS_HOST`, default
  `www.erlang.org`)
- no crash dump, kernel panic or `erl_child_setup` error in the console log

IEx mode

- the `Interactive Elixir (1.20...)` banner and an `iex(1)>` prompt
- two expressions are typed on the serial console and their output is checked

Console logs are kept in `build/logs/<label>-<mode>.log` (raw) and
`.log.clean` (ANSI stripped). The host-side client results are in
`<label>-clients.log`.

## Options

| Variable | Default | Meaning |
|---|---|---|
| `SMOKE_TIMEOUT` | 240 | seconds per QEMU run |
| `SMOKE_BOOT_TIMEOUT` | 45 | a run that has not printed `uniapp starting` by then is killed and retried |
| `SMOKE_ATTEMPTS` | 5 | retries per run |
| `TLS_HOST` | `www.erlang.org` | target of the DNS and TLS client probes |
| `HOST_PORT_TCP/UDP/TLS` | 14000/14001/14443 | host ports; the script refuses to start if one is taken |
| `QEMU_ACCEL` | auto | `kvm` or `tcg` |

The retry logic exists because QEMU TCG on a loaded laptop occasionally
starts slowly; a retry is reported with an `info:` line and does not fail the
test. Before the `timerfd` fix in
[Asterinas patches](../internals/asterinas-patches.md) it also masked a real
kernel bug, so if you see retries on every run, look at the console log.

## Continuous integration

`.github/workflows/smoke.yml` runs the same three steps on GitHub Actions:
build the release (cached with `type=gha`), then M0 and M1 in parallel jobs
under TCG. Logs are uploaded as artefacts.
