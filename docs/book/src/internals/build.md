# Build pipeline

Everything runs in `builder/Dockerfile`, natively on the Docker host's
architecture. Only the final ERTS binaries are cross-compiled for x86-64.
This matters on Apple Silicon: an earlier version of the pipeline ran x86-64
containers under Rosetta, took 40 minutes, and crashed randomly in `cc1` and
`collect2`. The native pipeline takes about 6 minutes cold.

```text
base       Alpine + clang + lld + an x86-64 Alpine sysroot (apk --arch x86_64 --root /sysroot)
   │          musl, gcc/g++ runtime, static OpenSSL 3.5, zlib, zstd, ncurses
   ├─ otp-src    clone OTP at $OTP_TAG, patch erts/configure (LIBZSTD -Bdynamic)
   │     ├─ otp-cross   otp_build configure --xcomp-conf=... ; boot -a ; release -a /opt/otp-x86
   │     │              relink beam.smp + erl_child_setup with -static ; run under qemu-user
   │     └─ otp-native  ./configure ; make ; install to /opt/otp        (for Elixir and Mix)
   ├─ elixir     clone at $ELIXIR_TAG, make, install (native OTP)
   ├─ release    mix release with UNIAPP_ERTS=/opt/otp-x86 ; cross-compile /init ; CA bundle
   └─ out        scratch image with /release, /init, /etc/ssl/cacert.pem, ERTS_VSN
```

`make release` exports the `out` stage to `build/out` and
`scripts/assemble-rootfs.sh` lays out `build/rootfs`.

## Cross-compiling OTP

OTP supports cross builds through `otp_build configure --xcomp-conf=FILE`;
`builder/xcomp/erl-xcomp-x86_64-alpine-linux-musl.conf` sets
`CC="clang --target=x86_64-alpine-linux-musl --sysroot=/sysroot"`, lld as the
linker, `LIBS="-lcrypto -lssl -lz -lzstd"` for the static NIFs, and the
feature answers configure cannot test when cross compiling (`erl_xcomp_*`).
`otp_build boot -a` builds a native bootstrap compiler, cross-compiles ERTS
and the C parts of the libraries, and compiles all `.erl` files with the
bootstrap. `otp_build release -a` installs the result.

`.beam` files are architecture independent, which is why the native OTP can
run Elixir and Mix, and Mix can still assemble an x86-64 release: `mix.exs`
points `include_erts` at the cross tree and Mix copies both ERTS and the OTP
applications from there.

## Three non-obvious fixes

`LIBZSTD`. `erts/configure` hardcodes
`LIBZSTD="-Wl,-Bstatic -lzstd -Wl,-Bdynamic"`. With `-static`, the trailing
`-Bdynamic` makes lld link libc dynamically anyway; the result has a
`PT_DYNAMIC` segment and segfaults before `main`. (bfd refuses with
"attempted static link of dynamic object".) The Dockerfile replaces it with
`-lzstd`.

`-static` placement. Passing `LDFLAGS=-static` to configure breaks its
dynamic-driver (`-shared`) conftests. It is passed to `make` instead, and only
for the `emulator` target, then the two shipped binaries are relinked and
copied over the installed PIE versions.

Static NIFs. `--enable-static-nifs=yes` links `asn1rt_nif.a` and `crypto.a`
into `beam.smp`; their dependencies (OpenSSL etc.) must be in `LIBS`. The
`.so` variants are still built and are deleted by the release's `prune` step.

## Verification inside the build

- `file`/`readelf` assert that `beam.smp` and `erl_child_setup` are x86-64,
  statically linked and have no `INTERP`.
- `builder/cross-smoke.sh` runs the cross-built `beam.smp` under
  `qemu-x86_64` (user-mode emulation), boots the OTP `start` script, starts
  `ssl` and prints `crypto:info_lib()`. The build fails if OTP 29 or OpenSSL
  do not come up.
- `scripts/assemble-rootfs.sh` fails on any unexpected ELF.

## The kernel build

`scripts/build-asterinas.sh` clones Asterinas at `ASTERINAS_REF`, applies
every `builder/asterinas-patches/*.patch`, and runs
`cargo osdk build --release --boot-method vmm-direct --grub-boot-protocol multiboot --strip-elf`
inside the upstream `asterinas/dev` container (the exact tag is read from the
checkout's `DOCKER_IMAGE_VERSION`). OSDK rewrites `e_machine` to `EM_386` so
QEMU accepts the 64-bit multiboot ELF. The cargo registry is cached under
`build/asterinas-cache`. About 4 minutes cold, 10 seconds for a rebuild
after a one-line patch.

## Caching

Each Docker stage is a cached layer keyed on its inputs. Changing `app/`
rebuilds only the `release` stage (about a minute). Changing `OTP_TAG`
rebuilds `otp-cross` and `otp-native` (about 6 minutes). CI uses
`cache-from/to: type=gha`.
