Add triple-fault restart fallback and `clock_settime` on x86

On EC2 Nitro neither an ACPI reset register nor an i8042 controller
exists, so `reboot(2)` fell through to `machine_halt` and the instance
hung with a dead console. Implement `ostd::arch::power::try_restart` as a
triple fault (empty IDT, `int3`), the last resort Linux uses too, and
register it at `Priority::LOW`; move the i8042 reset to `Priority::new(1)`
to keep the order ACPI, i8042, triple fault. A `Priority::LOW` poweroff
handler falls back to a restart so that a guest asking to power off does
not hang where S5 is unavailable.

There was also no `clock_settime`/`settimeofday`. Keep the realtime clock
as boot time plus the monotonic counter and add an atomic offset that
`set_realtime` stores and every realtime reader, including the vDSO,
applies. Monotonic clocks are unaffected; `CAP_SYS_TIME` is required.
