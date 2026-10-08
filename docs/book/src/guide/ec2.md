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

## What does not work yet

- Only one ENA queue pair, no LLQ, no checksum offload; see the
  [ENA driver notes](../internals/asterinas-patches.md#0005-the-ena-network-driver).
- Asterinas's NVMe driver fails its first admin command on Nitro
  (`nvme: Device initialization error: Err(CommandFailed)`). The image does
  not need the block device, since GRUB loads the initramfs as a multiboot
  module, but it means no persistent volume on Asterinas for now.
- Instance metadata (169.254.169.254), cloud-init style user data and IPv6
  are not used. Graviton (arm64), Xen-based instance types and Marketplace
  publishing are out of scope.
