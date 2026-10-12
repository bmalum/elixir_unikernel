Add multi-queue RSS, checksum offload and recovery to the ENA driver

Use up to one Tx/Rx queue pair per CPU (at most 8) with Toeplitz RSS over
the IPv4 5-tuple; steer Tx by a hash of the same tuple so that a
connection stays on one queue (round-robin reordered segments and halved
single-flow throughput).

Offload IPv4 TCP/UDP checksums: write the pseudo-header sum, send one
cached meta descriptor per queue and set the partial-checksum flags;
honour the device's Rx verification and adjust smoltcp's checksum caps.
aster-bigtcp gains `TxPacket::data_writer` to patch the checksum field in
place.

Handle the AENQ (link change, fatal error, keep-alive) with a 6 s
keep-alive watchdog and a full reset path. Device access never happens in
the timer interrupt: the tick only sets a flag and the health work runs
in the softirq, because a readless MMIO read takes milliseconds and
stalled the stack when done under the device lock.
