# A Phoenix application

Phoenix is ordinary OTP code, and the image already has everything a Phoenix
release needs: static ERTS, `:crypto`/`:ssl`, a working `inet` over
virtio-net and a release boot script. Four things differ from a normal
deployment.

## 1. Generate and vendor

```sh
mix phx.new app --no-ecto --no-mailer --install
```

Drop the result into `app/`, then re-add the three pieces from
[Shipping your own application](your-app.md): the `erts()` helper and release
options in `mix.exs`, `ReleaseSteps.prune/1`, and `Cmdline`.

Check `mix.lock` for NIF-based dependencies. The Phoenix defaults
(`bandit`/`cowboy`, `plug`, `jason`, `phoenix_pubsub`, `telemetry`,
`websock_adapter`) are pure BEAM. `bcrypt_elixir` and `argon2_elixir` are not;
use `pbkdf2_elixir`. SQLite via `exqlite` is not; Postgres via `postgrex` is.

## 2. Assets

There is no Node or esbuild in the image, so assets are built in the Docker
`release` stage. The Elixir `esbuild` and `tailwind` packages download an
x86-64 binary and run it; that only works in an x86-64 container. Two options:

- Build assets on the host (or in CI) and commit or `COPY` `priv/static` into
  the builder, removing `assets.deploy` from the release step.
- Add a small x86-64 stage that runs `mix assets.deploy` (slow on arm64 hosts,
  it runs under emulation).

The digested files in `priv/static` are served by `Plug.Static` straight from
the initramfs.

## 3. Configuration

Replace the environment-variable plumbing in `config/runtime.exs`:

```elixir
import Config

if config_env() == :prod do
  port = String.to_integer(Myapp.Cmdline.get("phx.port", "4000"))
  host = Myapp.Cmdline.get("phx.host", "localhost")

  config :myapp, MyappWeb.Endpoint,
    server: true,                       # no bin/server script sets PHX_SERVER
    url: [host: host, port: port],
    http: [ip: {0, 0, 0, 0}, port: port],
    check_origin: false,                # or ["//" <> host]
    secret_key_base: Myapp.Cmdline.get("phx.secret") || raise("phx.secret= missing")
end
```

A secret on the kernel command line is visible to anyone who can read the
VM's configuration, which is the same threat model as an environment variable
in a container. For HTTPS, add `https: [port: 4443, certfile: ..., keyfile:
...]` with the files in `priv/`, or generate a self-signed pair at boot as the
sample's TLS echo server does.

## 4. Forward the port

Add `hostfwd=tcp::14080-:4000` to `QEMU_BASE` in the Makefile, then:

```sh
make initramfs run-m1-app
open http://127.0.0.1:14080
```

## What to expect

- Image size grows by roughly 4 to 6 MB (gzipped) for Phoenix and its
  dependencies, well inside the budget.
- Memory: plan on 256 MB guest RAM; a LiveView app with a few connections sits
  around 90 to 130 MB RSS.
- Ecto works as a client to a database outside the VM. There is no database
  inside the image.
- `mix phx.server`, code reloading, `mix` tasks and `System.cmd/3` do not
  exist at runtime.
- Expect to find one or two socket options that Asterinas does not implement
  yet (`ENOPROTOOPT` in the log). `Bandit` and `Cowboy` tolerate most of
  them; report the ones that break and test on `make run-m0-app` to confirm
  it is kernel-side.
