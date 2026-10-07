# Releasing a bundle

```sh
make dist
```

produces `dist/elixir_unikernel-<version>-x86_64/` and a `.tar.gz` of it:

| File | Contents |
|---|---|
| `asterinas.elf` | the Rust kernel, a multiboot ELF that QEMU boots with `-kernel` |
| `initramfs.cpio.gz` | the Elixir image |
| `run.sh` | boots it with QEMU: `./run.sh iex` or `./run.sh app [extra kernel args]`; honours `MEM` and `SMP` |
| `VERSIONS` | elixir_unikernel version, ERTS version, every pinned upstream tag and the applied kernel patches, build time |
| `SHA256SUMS` | checksums of the above |
| `LICENSE-NOTICE` | licences of the bundled components |

The version comes from the `VERSION` file at the repository root. Bump it,
update `CHANGELOG.md`, tag the commit, and attach the tarball to the release.

## Running the bundle elsewhere

The bundle needs only `qemu-system-x86_64`. On a Linux host with KVM:

```sh
tar xzf elixir_unikernel-0.1.0-x86_64.tar.gz
cd elixir_unikernel-0.1.0-x86_64
sha256sum -c SHA256SUMS
./run.sh app
```

`run.sh` uses QEMU user networking with the same port forwards as the
Makefile. For anything beyond a demo, replace the `-netdev user` line with a
tap or bridge device and pass the real addresses as `uniapp.ip=`, `uniapp.gw=`
and `uniapp.dns=` arguments.

## Other VMMs

The kernel is a multiboot ELF, so it needs a loader that speaks multiboot:
QEMU does, Firecracker and cloud-hypervisor do not. Asterinas can also produce
a Linux `bzImage` (`--grub-boot-protocol linux` in
`scripts/build-asterinas.sh`), which Firecracker accepts; that variant did
not produce console output under QEMU TCG in our tests and is not part of the
smoke test yet. The initramfs itself is a plain gzip newc cpio and works with
any of them.

## Reproducibility

`make smoke` from an empty `build/` rebuilds everything from the pinned tags
and runs both smoke tests. The Docker stages are deterministic in content
(same sources, same flags) but not byte-identical: Rust and C builds embed
paths and timestamps, so two `asterinas.elf` files from the same commit
differ. `VERSIONS` is the record of what went in.
