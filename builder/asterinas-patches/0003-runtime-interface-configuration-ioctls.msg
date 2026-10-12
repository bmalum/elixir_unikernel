Add `SIOCSIFADDR`, `SIOCSIFNETMASK`, `SIOCADDRT` and related ioctls

Only the `SIOCGIF*` getters existed; every setter returned `ENOTTY`, so a
network interface could not be configured at runtime and `eth0` stayed
hardwired to the QEMU user-network address.

Add `Iface::set_ipv4_cidr` and `set_ipv4_gateway` to aster-bigtcp, which
update smoltcp's addresses and default route under the interface lock, and
move the route managers behind an `RwLock` with a `reload()` that rebuilds
the local and main tables from the interfaces, so `bind()` and output
interface lookups see the new address immediately. `SIOCSIFBRDADDR` is
accepted and ignored (the broadcast address is derived), `SIOCSIFFLAGS` is
accepted (interfaces are always up), one IPv4 address per interface.
