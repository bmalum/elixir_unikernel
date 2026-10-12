Fix `bind()` to the unspecified address failing with `EADDRNOTAVAIL`

`resolve_bind_iface_and_config` looks the bind address up in the local
route table, where 0.0.0.0 never appears, so binding to `INADDR_ANY`
failed before an interface could be chosen. Every plain `listen()` in
Erlang/OTP and the resolver's query socket hit this.

Treat an unspecified address as "the default interface" and rewrite the
endpoint to that interface's address, since aster-bigtcp dispatches by
(address, port) and a socket left bound to 0.0.0.0 receives nothing. A
socket bound this way only sees traffic on the chosen interface, which is
noted as a FIXME; attaching to all interfaces is a larger change.
