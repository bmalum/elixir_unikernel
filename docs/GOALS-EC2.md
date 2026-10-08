# Goal: an Asterinas AMI on EC2

Status: proposed, 2026-10-08. Successor to M2; independent of the Hermit
track (M3).

## Vision

The elixir_unikernel image boots as an EC2 instance: an AMI whose only
software is the Asterinas kernel, `/init` and the BEAM. `aws ec2 run-instances`
on it gives you an Elixir node with a public IP, reachable over TCP and TLS,
with IEx available through the EC2 Serial Console. No Linux anywhere in the
guest.

## What exists upstream (checked 2026-10-08, Asterinas `main` 10a2418)

- NVMe: a PCI NVMe block driver (`kernel/core/comps/nvme`), with a regression
  test and fio benchmarks. EBS volumes on Nitro appear as NVMe. Promising,
  untested against the Nitro controller.
- Boot: OSDK can emit a Linux `bzImage` with legacy-BIOS and EFI-handover
  entry points (`--grub-boot-protocol linux`) and GRUB disk images
  (`grub-qcow2`). EC2 boots UEFI or legacy BIOS from a disk; both paths exist
  in principle, neither has been run on EC2.
- ENA (Elastic Network Adapter): no driver. Every Nitro instance type uses
  ENA; the Xen-based types (t2, m4, c4) use Xen netfront, also unsupported.
  Without it the instance has no network.
- DHCP: not in the kernel, not in `/init`. EC2 assigns addresses by DHCP; the
  address is also readable from IMDS, but only once an address exists.
- Interface configuration: the address is compiled into the kernel
  (`net/iface/init.rs`); the set-ioctls return `ENOTTY`.

So the blocker is a network driver, and the gaps around it are a disk image, a
DHCP client, and runtime interface configuration.

## Success criteria

1. `make ami` produces `build/disk.raw`: a GPT disk with an EFI system
   partition holding a bootloader (GRUB or Limine), the Asterinas kernel and
   `initramfs.cpio.gz`, with the kernel command line baked in. The same image
   boots under QEMU with `-bios OVMF` and `-device nvme`, and passes
   `scripts/smoke.sh` in app mode.
2. `make ami-publish AWS_PROFILE=elixir-playground` uploads the image to S3,
   imports it as a snapshot, registers an AMI with `--ena-support
   --boot-mode uefi --architecture x86_64`, and prints the AMI id. The script
   is idempotent and tags everything it creates
   (`Project=elixir_unikernel`, `Version=<VERSION>`).
3. `run-instances` on that AMI (t3.micro or t3.small, eu-central-1) reaches
   `uniapp starting` on the EC2 Serial Console within 30 s of the instance
   entering `running`. Serial output is captured with
   `aws ec2 get-console-output` and checked by `scripts/smoke-ec2.sh`.
4. Networking on the instance: the guest obtains its address by DHCP;
   `nc <public-ip> 4000` echoes; `openssl s_client -connect <public-ip>:4443
   -tls1_3` echoes; inside the guest `PROBE dns ok` and `PROBE tls ok`
   (resolving and connecting to an external host over the VPC's resolver and
   NAT/IGW).
5. IEx over the Serial Console: an AMI variant or a kernel-command-line
   switch (`uniapp.mode=iex`) gives an interactive IEx on
   `aws ec2-instance-connect send-serial-console-ssh-public-key` +
   `ssh ...@serial-console.ec2-instance-connect...`.
6. Footprint: root volume 1 GiB (the minimum EBS size; the image itself stays
   under 40 MB), instance RAM 1 GiB on t3.micro; `beam.smp` RSS under 100 MB.
7. Cost and hygiene: `scripts/smoke-ec2.sh` terminates its instance and
   `make ami-clean` deregisters AMIs and deletes snapshots and S3 objects for
   a given version. Nothing is left running after a test.
8. The Linux A/B path is kept: `make ami KERNEL=linux` builds the same disk
   image around a Linux kernel with ENA + NVMe compiled in, so an EC2 failure
   can be attributed to the kernel or to the image.

## Work items, in order

1. Disk image (QEMU-testable, no AWS). `scripts/mkdisk.sh`: GPT, 64 MB ESP
   with GRUB EFI binary, `grub.cfg` with `multiboot2`/`linux` entry and our
   command line, kernel, initramfs. Boot in QEMU with OVMF and an NVMe root
   device. Verify Asterinas's bzImage/EFI-handover path or fall back to
   multiboot2 under GRUB. Add `make ami` (local part) and a smoke target.
2. DHCP in `/init`. A minimal DHCPv4 client in C (discover, offer, request,
   ack; ~200 lines; raw UDP on port 68, no options beyond subnet, router,
   DNS, lease). Falls back to `uniapp.ip=` when absent. Testable with QEMU
   user networking, which runs a DHCP server at 10.0.2.2.
3. Interface configuration on Asterinas. Either implement `SIOCSIFADDR`,
   `SIOCSIFNETMASK`, `SIOCSIFFLAGS` and `SIOCADDRT` in
   `net/socket/ip/ioctl.rs` (preferred, and upstreamable) or accept a kernel
   command-line parameter for the address. Needed because EC2 addresses are
   not known at build time.
4. NVMe on Nitro. Run the disk image on a t3 instance with the Linux kernel
   first (item 8) to validate the image format, then with Asterinas to see
   whether its NVMe driver initialises the Nitro controller and reads the
   initramfs from it. Expect to find device-specific gaps (queue count,
   MSI-X, doorbell stride).
5. ENA driver for Asterinas. The large item. Scope: PCI device
   `1d0f:ec20`, admin queue, one Tx/one Rx I/O queue pair, MSI-X or polling,
   LLQ not required, as an `aster-network` device so `aster-bigtcp` picks it
   up. Reference implementations: Linux `drivers/net/ethernet/amazon/ena`,
   the FreeBSD driver, and the Rust ENA code in Firecracker's or
   cloud-hypervisor's test guests if any. Estimated 3 to 6 k lines of Rust
   including the DMA and interrupt plumbing. Cannot be tested locally: QEMU
   has no ENA model, so the development loop is "build, upload, boot, read
   serial console", about 5 minutes per iteration. Plan it as its own
   milestone and upstream it.
6. AWS plumbing. `scripts/ami-publish.sh` (S3 upload, `import-snapshot`,
   wait, `register-image`, tag), `scripts/smoke-ec2.sh` (security group
   allowing 4000/4443 from the caller's IP, `run-instances`, poll
   `get-console-output`, client checks, terminate), `make ami-clean`.
7. Documentation: manual chapter "Running on EC2", limits page update, the
   ENA driver's own design note.

Items 1, 2, 6 and the Linux variant of 8 are a week and give a working Linux
AMI with the elixir_unikernel userland (a useful product by itself). Item 5
is the Asterinas AMI and is the actual milestone.

## Test account

Profile `elixir-playground` (Isengard, role Admin, eu-central-1, account
`mkarrer+elixirplayground@amazon.de`). It is a personal playground account:
create freely, but every script that creates a resource must tag it and have
a matching clean-up, and `smoke-ec2.sh` must terminate its instance in a
trap so a failed test cannot leave a t3 running.

Blocker on this machine: the profile's `credential_process` runs
`isengardcli` from `~/.toolbox/tools/isengard-cli/1.0.1206.0`, which is an
x86-64 build and fails on arm64 with "bad CPU type in executable". Reinstall
the toolbox tool for arm64 (`toolbox update isengard-cli`) or run the AWS
steps from a Linux host before item 6.

## Non-goals

- AWS Marketplace listing (seller registration, scanning, pricing). Public
  sharing of the AMI (`modify-image-attribute --launch-permission
  group=all`) is one call and can be done once criteria 3 and 4 pass.
- Xen-based instance families, Graviton (arm64), bare-metal instances,
  Firecracker inside EC2.
- Persistent storage for the application. The root volume is read-only
  initramfs semantics; EBS as a data volume would be a later item once NVMe
  is proven.
- IMDSv2, instance roles, cloud-init style user data. A `user-data` to
  kernel-command-line bridge would be nice but is not needed to boot.

## Risks

- ENA is the whole project. If Asterinas upstream picks it up, this shrinks
  to weeks; if not, it is the single largest piece of code in
  elixir_unikernel and the only one we cannot test without AWS.
- Nitro NVMe may expose features the driver does not handle; the Linux
  kernel variant tells us whether the disk image is at fault.
- UEFI boot of a multiboot2 kernel through GRUB on EC2 is unverified;
  Asterinas's EFI-handover bzImage is the alternative, also unverified.
- EC2 Serial Console needs the instance type to support it (all Nitro types
  do) and the account setting
  `ec2 enable-serial-console-access` once.
- Cost: an S3 object, snapshots and AMIs are cents; a forgotten t3.small is
  about 18 USD a month. Clean-up is a criterion, not a nicety.
