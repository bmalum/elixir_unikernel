Add a driver for the Amazon Elastic Network Adapter (ENA)

ENA is the NIC on EC2 Nitro instances. The driver implements the admin
queue (device reset, "readless" MMIO, polled admin commands, feature
get/set, queue creation), one Tx/Rx queue pair on an MSI-X vector, 4 KiB
Rx buffers with the MTU set to 1500 so that no frame spans two of them,
and registers as `eth0` when no virtio-net device is present.
