# Goal: elixir_unikernel as an EC2 AMI on Asterinas

Repo: https://github.com/bmalum/elixir_unikernel (local: ~/Development/elixir_unikernel).
Read GOALS.md and docs/GOALS-EC2.md first. Branch `ec2`, small commits, keep `make smoke` green.

## Outcome

`aws ec2 run-instances --image-id <ami> --instance-type t3.small` gives, within 30 s of
`running`, an Elixir node whose guest contains only the Asterinas kernel, `/init`, `beam.smp`,
`erl_child_setup` and the release (no Linux). It prints `uniapp starting` on the EC2 Serial
Console, echoes on TCP 4000 and TLS 1.3 4443 from the internet, prints `PROBE dns ok` and
`PROBE tls ok`, and offers IEx on the Serial Console with `uniapp.mode=iex`.

## Success criteria (each proven by command output)

1. `make ami` builds `build/disk.raw` (GPT, EFI partition, GRUB, kernel, initramfs, cmdline
   baked in). `make smoke-disk` boots it in QEMU with OVMF + NVMe root and passes scripts/smoke.sh.
2. `/init` gets address, netmask, gateway, DNS via DHCP when `uniapp.ip=` is absent;
   `make smoke-m0`/`smoke-m1` pass without static net parameters (QEMU user net serves DHCP).
3. Asterinas honours `SIOCSIFADDR/SIOCSIFNETMASK/SIOCSIFFLAGS/SIOCADDRT` at runtime, as
   `builder/asterinas-patches/0003-*.patch` with an upstream-ready header.
4. Asterinas reads the initramfs from the Nitro NVMe root volume on a t3 (console log as proof).
5. Asterinas gets an ENA driver (PCI 1d0f:ec20; admin queue, one Tx/Rx pair, interrupts or
   polling) as a separate component crate registered with `aster-network`. Proof: 7 passes.
6. `make ami-publish AWS_PROFILE=elixir-playground`: S3 upload, import-snapshot,
   register-image (`--ena-support --boot-mode uefi --sriov-net-support simple`), everything
   tagged `Project=elixir_unikernel Version=<VERSION>`, idempotent, prints the AMI id.
7. `scripts/smoke-ec2.sh <ami>`: security group (4000/4443 from caller IP), launch t3.small,
   poll `get-console-output` for `uniapp starting` (max 120 s), TCP + TLS echo against the
   public IP, check PROBE lines, terminate and delete the group in an EXIT trap.
8. `scripts/ec2-console.sh <instance>`: serial-console SSH via ec2-instance-connect; typing
   `1 + 2` at `iex(1)>` prints `3`. (`enable-serial-console-access` once per account.)
9. `make ami KERNEL=linux` builds the same disk around a Linux kernel with ENA + NVMe built in
   and passes smoke-ec2.sh. Do this before 4 and 5 to validate image, scripts and DHCP on real
   Nitro hardware with a known-good kernel.
10. `make ami-clean VERSION=<v>` removes AMIs, snapshots and S3 objects; afterwards no
    non-terminated instances tagged `Project=elixir_unikernel` exist.
11. Docs: manual chapter "Running on EC2", limits page, CHANGELOG, ENA driver design note.
12. `make smoke` on `main` passes after merge.

## Constraints

- Account: profile `elixir-playground` (Isengard, Admin, eu-central-1, 537124966503). Personal
  playground: tag everything, never leave an instance running (t3.small ≈ 18 USD/month),
  nothing above t3.medium without asking. Verify access with `aws sts get-caller-identity --profile elixir-playground`.
- Out of scope: Marketplace, Graviton, Xen instances, data volumes.
- Kernel fixes are patches under builder/asterinas-patches/ with symptom/cause/fix headers and
  a reproducer; the ENA driver is new code kept applicable to upstream `main`.
- QEMU has no ENA model: the ENA loop is build → publish → launch → read console (~5 min).
  Put verbose driver logging behind `loglevel=debug`.

## Order

1 → 2 → 3 → Linux AMI end to end (9, 6, 7, 10) → Asterinas boot + NVMe on EC2 (4) → ENA (5)
→ 8 → 11 → 12. Criteria 1–3 and 9 take about a week and yield a useful Linux-kernel AMI;
criterion 5 is the milestone.

## Done when

All twelve criteria have cited output, smoke-ec2.sh passed twice in a row on the Asterinas
AMI, and only the final tagged AMI and its snapshot remain in the account.
