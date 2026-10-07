# Networking

The guest has one virtio-net interface. `/init` gives it a static address;
there is no DHCP client in the image.

| Command line | Default | Meaning |
|---|---|---|
| `uniapp.ip=A.B.C.D/N` | `10.0.2.15/24` | address and prefix for the first NIC |
| `uniapp.gw=A.B.C.D` | `10.0.2.2` | default route |
| `uniapp.dns=A.B.C.D` | `10.0.2.3` | nameserver |

The defaults match QEMU user-mode networking (`-netdev user`), where the
guest is 10.0.2.15, the gateway 10.0.2.2 and the DNS forwarder 10.0.2.3.

## How the interface is configured

On Linux `/init` uses the classic ioctls: `SIOCSIFADDR`, `SIOCSIFNETMASK`,
`SIOCSIFFLAGS` and `SIOCADDRT`. The interface name is discovered from
`/sys/class/net`, falling back to `eth0`.

Asterinas does not implement the set-ioctls (they return `ENOTTY`, logged as
`Not a tty`); its network stack configures 10.0.2.15/24 with gateway 10.0.2.2
at boot, in `kernel/core/src/net/iface/init.rs`. `/init` logs the failures and
continues. If you need another address on Asterinas today, change that file
and rebuild the kernel; command-line configuration is upstream work.

## Name resolution

OTP's default lookup method on Unix is `native`, which spawns the port program
`inet_gethost`. That binary is not in the image, so `/init` writes
`/etc/inetrc`:

```erlang
{lookup, [file, dns]}.
{host, {127,0,0,1}, ["localhost"]}.
{edns, 0}.
```

and points `ERL_INETRC` at it. Lookups then go through `inet_res`, OTP's
resolver written in Erlang, which reads nameservers from `/etc/resolv.conf`.
`/init` writes that file from `uniapp.dns`. Keep both files: `inet_db`
re-reads `resolv.conf` periodically and a missing file clears the nameserver
list.

`:inet.gethostbyname/1`, `:gen_tcp.connect(~c"host", ...)`, `:httpc`,
`Req`, `Finch` and friends all work through this path.

## TLS

OpenSSL 3.5 is statically linked into `beam.smp`, so `:crypto`, `:ssl` and
`:public_key` are available without any files. For verifying servers, the
image ships Alpine's CA bundle at `/etc/ssl/cacert.pem`:

```elixir
:ssl.connect(~c"www.erlang.org", 443,
  verify: :verify_peer,
  cacertfile: ~c"/etc/ssl/cacert.pem",
  versions: [:"tlsv1.3"],
  server_name_indication: ~c"www.erlang.org")
```

For a TLS server, generate a certificate at boot (the sample app uses
`:public_key.pkix_test_data/1` with `digest: :sha256`; SHA-1 signed test
certificates are rejected by modern clients) or ship a certificate and key in
`priv/` of your release.

## Reaching the guest from the host

With QEMU user networking the guest is not routable from the host; use port
forwards. The Makefile forwards host 14000, 14001 and 14443 to guest 4000
(TCP), 4001 (UDP) and 4443 (TCP). Add more in `QEMU_BASE`, or switch to a tap
device for a real bridged network.

## Known gaps on Asterinas

- Binding to `0.0.0.0` attaches the socket to the NIC only, so traffic to
  `127.0.0.1` does not reach a socket bound to the wildcard address. Bind
  explicitly to `127.0.0.1` for loopback-only servers. This comes from the
  local patch that makes wildcard binds work at all; see
  [Asterinas patches](../internals/asterinas-patches.md).
- `:inet.getifaddrs/0` works on Asterinas `main` but returned
  `{:error, :eaddrnotavail}` on v0.18.1.
- IPv6 is untested.
