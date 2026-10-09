# Running on EC2

The image boots as an EC2 AMI on Nitro x86-64 instances: the same GPT disk
that `make smoke-disk` boots under OVMF, uploaded as an EBS snapshot and
registered as a UEFI, ENA-enabled machine image. Both kernels work. With
Asterinas the guest contains no Linux at all: GRUB, the Asterinas kernel
with the ENA driver from patch 0005, `/init`, `beam.smp` and the release.

```text
[kernel] ena: found 1d0f:ec20 rev 0 at PciDeviceLocation { bus: 0, device: 5, function: 0 }
[kernel] ena: 0a-ff-cf-04-ad-1f ready, 127 Rx buffers of 4096 bytes, 128 Tx slots, MSI-X vector 1
[kernel] running /init as the init process
[init] elixir_unikernel init, uptime 1.641 s
[init] net: eth0 172.31.12.217/20 gw 172.31.0.1 dns 172.31.0.2 (kernel dhcp)
[init] exec /rel/erts-17.1/bin/beam.smp (app mode)
10:33:45.369 [info] uniapp starting (otp 29, elixir 1.20.4, uptime 4.36s)
```

That is the EC2 Serial Console of a t3.small. Nothing in the image is
EC2-specific except the ENA driver; the address comes from the VPC's DHCP.

## Prerequisites

- An AWS account and credentials in the environment (`AWS_PROFILE`,
  `AWS_REGION`). The scripts never read a region from the repository.
- `aws` CLI v2, `python3` with `boto3`, `openssl`, `curl`.
- IAM permissions for EC2 (`ebs:StartSnapshot`, `ebs:PutSnapshotBlock`,
  `ebs:CompleteSnapshot`, `ec2:RegisterImage`, `ec2:RunInstances`,
  security groups, `ec2:GetConsoleOutput`) and, for the serial console,
  `ec2-instance-connect:SendSerialConsoleSSHPublicKey`.
- For the serial console, once per account:
  `aws ec2 enable-serial-console-access`.

Everything the scripts create is tagged `Project=elixir_unikernel` and
`Version=<VERSION>`; the smoke tests terminate their instance and delete
their security group in an `EXIT` trap, including on Ctrl-C.

## Build and publish

```sh
make ami                       # build/disk-asterinas.raw: 1 GiB GPT, 94 MB EFI partition
make ami-publish               # -> ami-0a9c33776357b6a40 (prints the id)
make ami KERNEL=linux          # the same disk around Linux 6.1 with ENA + NVMe
make ami-publish KERNEL=linux
```

`scripts/ami-publish.py` uses the EBS direct APIs: it starts a snapshot of
a 1 GiB volume, uploads only the non-zero 512 KiB blocks (about 45 of
2048), completes it and registers the image with `BootMode=uefi`,
`EnaSupport=true`, `SriovNetSupport=simple`, root device `/dev/xvda`. No
S3 bucket and no `vmimport` role are needed, and the whole step takes
about 12 seconds. The AMI name is `elixir_unikernel-<VERSION>-<kernel>`
(plus `-iex` for `DISK_MODE=iex`); an existing image of that name is
reused, `AMI_FLAGS=--force` replaces it.

The command line is baked into the image (`DISK_CMDLINE_asterinas` in the
Makefile): `console=ttyS0 earlycon loglevel=error ip=dhcp
uniapp.tls_host=... uniapp.mode=app`. Keep `loglevel=error`: `info` logs
every syscall and overruns the 64 KB console buffer within seconds.
`DISK_MODE=iex` builds an image that drops into IEx on the serial console.

## Launch and verify

```sh
make smoke-ec2                 # publish (or reuse), launch t3.small, assert, terminate
scripts/smoke-ec2.sh <ami-id> [label]
```

The script creates a security group that allows 4000/tcp and 4443/tcp from
the caller's `/24` (`CLIENT_CIDR` overrides it; NAT pools rotate the source
address between connections), launches one `t3.small` (`INSTANCE_TYPE`) in
the default VPC, polls `GetConsoleOutput` for `uniapp starting` (limit
`BOOT_TIMEOUT`, default 120 s), echoes through TCP 4000 and TLS 1.3 4443
from the internet and checks the `PROBE dns ok` and `PROBE tls ok` lines.
With a data snapshot (`make smoke-ec2` builds one from `scripts/mkdata.sh`
and passes it as `DATA_SNAPSHOT`) the launch also gets a 1 GiB EBS data
volume on `/dev/sdf`, the IAM role `elixir_unikernel-smoke` (created on first
use; CloudWatch Logs permissions only) and user data that turns on
`uniapp.cloudwatch=1`, `uniapp.data=auto` and a VM exit 75 s after boot. The
script then checks ten more things: IMDS identity, user-data overrides, NTP
sync, `/data` mounted, `boot_count 1`, the CloudWatch shipper, the
guest-initiated reboot, `boot_count 2` on the second boot, log events in
`/elixir_unikernel/smoke/<instance-id>`, the `BootCount` EMF document, and
then times `aws ec2 reboot-instances` (next boot visible within 180 s) and
`aws ec2 stop-instances` (`stopped` within 150 s). Both kernels pass all 23
(Asterinas `ami-0b7ba8bda566dc68c`, Linux `ami-058539254c3af3853`).

`KEEP=1` leaves the instance running. The console is saved to
`build/logs/ec2-<label>.log`.

A run on the Asterinas AMI:

```text
instance i-01ac1400270175f66 (t3.small, ami-0a9c33776357b6a40)
public ip 3.73.65.60, running after 17 s
  PASS uniapp starting on the console after 45s (limit 120s)
  PASS init configured the NIC: net: eth0 172.31.12.217/20 gw 172.31.0.1 dns 172.31.0.2 (kernel dhcp)
  PASS address came from DHCP
  PASS internet -> instance TCP 4000 echo
  PASS internet -> instance TLS 1.3 4443 echo
  PASS PROBE dns ok
  PASS PROBE tls ok
  PASS no crash
SMOKE asterinas (ami-0a9c33776357b6a40 on t3.small): 8 passed, 0 failed
```

"45 s" is measured from the instance entering `running` until the line is
visible through `GetConsoleOutput`, which lags by tens of seconds. The
guest itself reports BEAM up 4.4 s after the kernel started and the DHCP
lease at 1.6 s; the firmware and GRUB account for most of the rest.

## The serial console

```sh
scripts/ec2-console.sh <instance-id>            # GetConsoleOutput, read-only
scripts/ec2-console.sh <instance-id> --attach   # interactive, via EC2 Instance Connect
scripts/smoke-ec2-iex.sh <ami-id>               # launches a DISK_MODE=iex image and types 1 + 2
```

`--attach` pushes a one-off SSH key with `SendSerialConsoleSSHPublicKey`
and connects to `serial-console.ec2-instance-connect.<region>.aws`. There
is no login prompt: the serial line is the Erlang VM's stdio, so an
`uniapp.mode=iex` image shows `iex(1)>` and an `app` image shows the log.
One session per instance; `~.` detaches, and EC2 needs about 30 s before
it accepts the next one.

## Cleaning up

```sh
make ami-clean                 # deregister this version's AMIs and delete their snapshots
aws ec2 describe-instances --filters Name=tag:Project,Values=elixir_unikernel \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text
```

A `t3.small` costs about 18 USD per month if left running; the snapshot of
a 1 GiB volume is cents.

## Health checks and throughput

The sample app serves `GET /healthz` on port 8080 (`uniapp.health_port=`):
503 `{"status":"starting"}` until the echo servers listen, then 200 with
uptime, memory, process count, instance id, boot count and the last
measured echo throughput; `GET /livez` is 200 as soon as the socket is
open. For an ALB target group use path `/healthz`, port 8080, matcher 200;
for an auto-scaling group set the health check type to ELB. The
implementation (`app/lib/uniapp/health.ex`, 160 lines of `:gen_tcp`) is
the template for your own application's endpoint.

Throughput, t3.small, Asterinas with the ENA driver after patch 0009:

| Path | Result |
|---|---|
| guest-side echo through the NIC driver (`BENCH tcp_echo`, 8 MB) | 78 to 101 MB/s |
| NIC to NIC, two instances, same subnet (`scripts/bench-ec2.sh`) | 77 to 108 MB/s round trip, one queue pair |
| same with `ena.queues=2` | 34 to 51 MB/s (single flow; see the patch notes) |
| from a laptop over the internet (`BULK`, 4 MB) | about 1 MB/s, latency bound |

`scripts/bench-ec2.sh <ami> [kernel args]` launches two instances, has the
second push 8 MB through the first's TCP echo and prints the sender's
`BENCH tcp_echo_peer` line; both are terminated afterwards.

## Operating it

- **Configuration** comes from EC2 user data, not from rebuilding the AMI:
  plain `key=value` lines (`uniapp.mode=iex`, `uniapp.log_group=/prod/web`,
  anything the [command line](../reference/cmdline.md) accepts). `/init`
  fetches it over IMDSv2 and the raw text is at `/run/user-data` for the
  application.
- **Crashes** restart the instance: when the VM exits, `/init` reboots the
  machine and the AMI boots again (about 45 s). Set `uniapp.on_exit=poweroff`
  with `--instance-initiated-shutdown-behavior terminate` if the ASG should
  replace the instance instead.
- **`stop-instances`, `reboot-instances`, `terminate-instances`** press the
  ACPI power button. The kernel turns it into `SIGPWR`, `/init` stops the VM
  with `SIGTERM` (ERTS shuts the applications down in order), waits up to
  20 s and powers off through ACPI S5. Stops complete in about 15 s, reboots
  in about 45 s, instead of EC2's four-minute hard reset.
- **State** lives on an EBS volume mounted at `/data` (`uniapp.data=auto`),
  ext2, so write small files and `fsync`. `scripts/mkdata.sh` makes an empty
  image, `scripts/ami-publish.py --snapshot-only` turns it into a snapshot to
  launch from. `erl_crash.dump` lands there too.
- **Logs and metrics** go to CloudWatch from inside the BEAM
  (`uniapp.cloudwatch=1`, instance role with `logs:*` on the group): every
  `Logger` event is batched into `PutLogEvents`, metrics are EMF documents in
  the same stream. Nothing else runs on the instance, so this is the only
  telemetry path; use it as the model for your own application.
- **Time** is set from Amazon Time Sync at boot and hourly.

## What does not work yet

- ENA: no LLQ, no TSO; one queue pair by default (`ena.queues=auto` for
  one per vCPU). See the
  [ENA driver notes](../internals/asterinas-patches.md#0009-ena-driver-second-round).
- Asterinas's NVMe driver needs patch 0007 to talk to EBS (the controller
  reports 32 queue entries and rejects larger queues); it has one I/O queue
  and no interrupts tuning, fine for a boot counter and crash dumps, not for
  a database.
- IPv6 is not used. Graviton (arm64), Xen-based instance types and
  Marketplace publishing are out of scope.
