# Shipping your own application

The image embeds whatever `mix release` produces from `app/`. Replace the
sample with your project and rebuild.

## What to keep from the sample

Three small pieces in `app/` are worth copying into your project:

`mix.exs` release options:

```elixir
releases: [
  myapp: [
    include_executables_for: [],      # no bin/myapp shell script, /init starts beam.smp
    include_erts: erts(),             # cross-compiled ERTS from the builder, see below
    strip_beams: true,
    steps: [:assemble, &Myapp.ReleaseSteps.prune/1]
  ]
]

defp erts do
  case System.get_env("UNIAPP_ERTS") do
    nil -> true
    root -> root |> Path.join("erts-*") |> Path.wildcard() |> List.first()
  end
end
```

`UNIAPP_ERTS` is set by the Dockerfile to `/opt/otp-x86`, the cross-compiled
OTP tree. Mix then takes both ERTS and the OTP applications from there, which
is what makes the release x86-64 even though Mix itself runs natively.

`lib/.../release_steps.ex` (`prune/1`) deletes everything the shell-free boot
does not need: the release's `bin/`, all ERTS binaries except `beam.smp` and
`erl_child_setup`, sources, includes and docs. `scripts/assemble-rootfs.sh`
refuses to build an image that contains any other ELF file, so keep this
step.

`lib/.../cmdline.ex` reads `key=value` pairs from the kernel command line
(`/init` copies it into `KERNEL_CMDLINE`). Use it for runtime configuration
instead of environment variables.

## Dependencies

Pure Elixir and Erlang dependencies work unchanged. Add the Hex steps to the
`release` stage of `builder/Dockerfile`:

```dockerfile
COPY app/mix.exs app/mix.lock ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get --only prod
COPY app/config config
COPY app/lib lib
COPY app/priv priv
RUN mix release --overwrite --path /out/release
```

Dependencies with NIFs do not work: a NIF is a shared object loaded with
`dlopen`, and the image has no dynamic loader. Prefer the pure-Elixir
alternative (`pbkdf2_elixir` instead of `bcrypt_elixir`, `postgrex` is fine,
`exqlite` is not) or link the NIF statically into `beam.smp` the way OTP's
own `crypto` and `asn1` are. The latter means building the NIF as a `.a`
archive and adding it to `--enable-static-nifs` in the cross OTP stage; it is
real work but has been done for OTP's NIFs already.

## Configuration

`config/runtime.exs` is evaluated at boot inside the image. Keep
`reboot_system_after_config` at its default (`false`): the release directory
is read-only and a reboot would need to write a new `sys.config`.

Environment variables are what `/init` sets (`RELEASE_*`, `LANG`, `TERM`,
`KERNEL_CMDLINE`). Anything else must come from the command line via
`Cmdline.get/2` or be baked into `config/config.exs`.

## Starting without a shell

In `app` mode the release boots with `-noshell` and the applications listed in
`mix.exs` start under `application_controller`. If an application exits,
`init` stops the node, which ends the VM (there is no supervisor above
`beam.smp`). The sample's echo server therefore retries a failed `listen`
instead of crashing, so that a kernel limitation never takes the image down.
Do the same for anything that touches the OS at start.

## Build and boot

```sh
make initramfs      # ~1 min once OTP and Elixir are cached
make run-m1-app
```

The release name and version are read by `/init` from `RELEASE_NAME` and
`RELEASE_VSN` compile-time defines; if you rename the app from `uniapp`,
update the two `#define`s at the top of `init/init.c` (or pass them as
`-DRELEASE_NAME=...` in the Dockerfile).
