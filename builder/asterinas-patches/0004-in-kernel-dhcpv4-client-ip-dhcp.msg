Add an in-kernel DHCPv4 client behind `ip=dhcp`

Asterinas has no `AF_PACKET` sockets, so a userspace DHCP client cannot
run, and anything outside QEMU user networking (EC2, for one) needs a
lease. smoltcp ships a `dhcpv4` socket; wire it in.

`EtherIface::new_dhcp` creates the interface without an address and with
a `Dhcpv4Socket`. UDP 67 to 68 is fed to it on ingress, its requests go
out through the normal UDP emit path, and its timers take part in
`next_poll_at_ms`. When the lease arrives it is applied with the ioctl
setters; the route tables rebuild lazily on the next lookup because the
route lock cannot be taken in the poll path. `/proc/net/dhcp` reports the
lease (address, gateway, DNS) so that init can learn the nameserver.
