Add ACPI power button handling and S5 power-off without AML

`aws ec2 stop-instances` and `reboot-instances` press the ACPI power
button and wait for the guest to power off; without support for either,
the instance stayed in `stopping` until the hypervisor hard-reset it four
minutes later.

OSTD collects the PM1 event and control ports from the FADT and scans the
DSDT and SSDTs for the `_S5_` package to obtain the sleep type constants.
The kernel enables `PWRBTN_EN`, polls `PWRBTN_STS` from the timer tick
every 50 ms and sends `SIGPWR` to the init process (debounced to one per
5 s), and registers a `Priority::FIRMWARE` poweroff handler that writes
`SLP_TYP | SLP_EN` to PM1_CNT. Polling avoids depending on SCI routing;
the status bit latches regardless.

The QEMU detection accepted the `KVMKVMKVM` signature, which Nitro also
presents, so the isa-debug-exit handler shadowed the real power-off path
on EC2; require the firmware OEM ID "BOCHS " as well.
