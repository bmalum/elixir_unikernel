# Development workflow

## Layout

```text
app/            sample release (echo servers, boot probes)
builder/        Dockerfile, OTP cross config, kernel patches
docs/           this manual (docs/book) and the original research notes
init/           /init
scripts/        rootfs assembly, initramfs, kernel fetch/build, smoke test, dist
site/           landing page
.github/        CI: smoke tests, GitHub Pages
```

## Edit, build, boot

| You changed | Run | Time |
|---|---|---|
| `app/` | `make initramfs run-m1-app` | ~1 min |
| `init/init.c` | `make initramfs run-m1` | ~1 min |
| `builder/asterinas-patches/` or `ASTERINAS_REF` | `make asterinas run-m1` | 10 s to 4 min |
| `builder/Dockerfile`, `OTP_TAG`, `ELIXIR_TAG` | `make release initramfs` | ~6 min |
| `scripts/smoke.sh` | `make smoke-m0` (fast, Linux) then `smoke-m1` | 3 min each |
| `docs/book/` | `make docs-serve`, open http://localhost:3000 | live |
| `site/` | `make site`, open `build/site/index.html` | 1 s |

Before a pull request: `make smoke` from a clean `build/` (`make clean`
first), and `make docs` if you touched the manual (broken links fail the
build).

## Debugging a boot

- `uniapp.mode=erl` gives a plain Erlang shell without Elixir's CLI.
- `uniapp.eval="io:format('~p~n',[inet:getifaddrs()])"` runs an expression at
  boot (single quotes only inside the value).
- `uniapp.code=embedded` reproduces the Mix release default if lazy loading
  is suspected.
- `loglevel=debug` on Asterinas logs every syscall with its thread id; it is
  verbose (500k lines for a boot) but `grep -c SYS_` per syscall tells you
  what the VM is doing when it looks stuck.
- `Ctrl-a c` enters the QEMU monitor; `info registers -a` shows where each
  vCPU is; `addr2line -e target/x86_64-unknown-none/release/asterinas-osdk-bin`
  inside the dev container maps kernel addresses to functions.
- Boot the same image with `make run-m0` to see whether Linux agrees.

## Updating upstreams

OTP: change `OTP_TAG`, check `erts/configure` still has the `LIBZSTD`
line the Dockerfile patches (the `sed` is followed by a `grep` that fails if
not), rebuild, run `make smoke`. Elixir: change `ELIXIR_TAG`, confirm
`bin/elixir` still passes `-user elixir` and `-s elixir start_cli` (that is
what `/init` hardcodes). Asterinas: change `ASTERINAS_REF`, rebuild; if a
patch no longer applies, check whether it was merged upstream and delete it,
otherwise rebase it.

## Style

Shell scripts are `bash` with `set -euo pipefail` where they can be, and run
on macOS's bash 3.2 (no `local x=$1` combined declarations, no `mapfile`). C
is C11, warnings clean with `-Wall -Wextra`. Elixir follows `mix format`.
Commit messages say what changed and why in the first line.
