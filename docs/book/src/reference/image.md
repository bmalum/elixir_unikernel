# Image contents

`build/rootfs/` after `make release`:

```text
/init                                static, 40 KB
/rel/erts-17.1/bin/beam.smp          static, 9.9 MB, JIT, OpenSSL 3.5 + zlib + zstd + crypto/asn1 NIFs linked in
/rel/erts-17.1/bin/erl_child_setup   static, 59 KB
/rel/lib/asn1-5.5.2/ebin
/rel/lib/compiler-10.0.6/ebin
/rel/lib/crypto-5.10/ebin
/rel/lib/elixir-1.20.4/ebin
/rel/lib/iex-1.20.4/ebin
/rel/lib/kernel-11.0.4/ebin
/rel/lib/logger-1.20.4/ebin
/rel/lib/public_key-1.21.7/ebin
/rel/lib/sasl-4.4/ebin
/rel/lib/ssl-11.7.7/ebin
/rel/lib/stdlib-8.1/ebin
/rel/lib/uniapp-0.1.0/ebin
/rel/releases/0.1.0/{start,start_clean}.{boot,script}, sys.config, vm.args, uniapp.rel, consolidated/
/rel/releases/RELEASES, start_erl.data
/etc/ssl/cacert.pem                  Alpine CA bundle, 230 KB
/dev /proc /sys /tmp                 empty mount points
```

Written by `/init` at boot: `/etc/inetrc`, `/etc/resolv.conf`, `/etc/hosts`.

Not present, by construction: `sh`, `erl`, `erlexec`, `epmd`, `inet_gethost`,
`heart`, `erl_call`, `escript`, `run_erl`, `to_erl`, any `.so`, any dynamic
loader, any Erlang source, include or documentation file.
`scripts/assemble-rootfs.sh` fails the build if any ELF other than the three
listed is found.

## Sizes

| | Bytes | |
|---|---|---|
| rootfs, uncompressed | 22 MB | |
| `initramfs.cpio.gz` | 9.4 MB | gzip -9 |
| Asterinas kernel ELF | 5.8 MB | release profile, stripped |
| total shipped | 15.2 MB | budget 40 MB |
| Linux reference kernel | 44 MB | `vmlinux` with debug info, not shipped |

## OTP applications excluded from the build

Configured out with `--without-*` in the Dockerfile and therefore absent from
both the cross and the native OTP: `wx`, `odbc`, `debugger`, `observer`,
`et`, `megaco`, `jinterface`, `cdv`, `dialyzer`, `diameter`, `eldap`,
`erl_docgen`, `ftp`, `mnesia`, `os_mon`, `reltool`, `snmp`, `tftp`,
`common_test`, `edoc`, `ssh`, `runtime_tools`, `syntax_tools`. `tools`,
`eunit`, `inets`, `xmerl`, `parsetools` and `erl_interface` are built (Elixir
needs some of them at compile time) but only enter the image if your release
lists them.
