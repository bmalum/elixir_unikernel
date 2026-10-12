Fix NVMe initialization on controllers with small queues

The EBS controller on EC2 advertises `CAP.MQES` = 31, but the driver
always created 64-entry I/O queues and got "Invalid Field in Command" on
Create I/O Completion Queue. Cap the I/O queue size at `MQES` and give the
rings a `depth` so that head, tail and phase wrap at the negotiated size.

Issue Set Features (Number of Queues) before creating I/O queues, as the
specification requires.

The device advances the submission queue head when it fetches a command,
before the completion arrives, so `free_slots()` can report a slot whose
request is still outstanding and `submit_with_items` panicked on it. Let
it enqueue what fits and hand the rest back; the caller requeues them and
waits for completions.
