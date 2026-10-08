# Goal: elixir_unikernel boots as an EC2 instance (Asterinas AMI)

Repository: https://github.com/bmalum/elixir_unikernel (local checkout at
~/Development/elixir_unikernel). Read GOALS.md, docs/GOALS-EC2.md and the
manual in docs/book before starting; they contain the measurements and the
upstream facts this goal builds on. Work on a branch `ec2`, commit in small
steps, keep `make smoke` green.

## Outcome

`aws ec2 run-instances --image-id <ami> --instance-type t3.small` with the
AMI this goal produces gives, within 30 seconds of the instance reaching
`running`, an Elixir node that:

- prints `uniapp starting (otp 29, elixir 1.20.4, ...)` on the EC2 Serial
  Console,
- echoes on TCP 4000 and TLS 1.3 on 4443 from the public internet,
- resolves names and completes a TLS 1.3 handshake to www.erlang.org from
  inside (`PROBE dns ok`, `PROBE tls ok` on the console),
- offers IEx over the Serial Console when launched with `uniapp.mode=iex`,

and whose guest contains nothing but the Asterinas kernel, `/init`,
`beam.smp`, `erl_child_setup` and the release. No Linux in the guest.

## Success criteria (each must be shown by command output)

1. `make ami` builds `build/disk.raw` (GPT, EFI system partition, GRUB,
   kernel, initramfs, command line baked in) from the pinned tags, and
   `make smoke-disk` boots it in QEMU with OVMF and an NVMe root device and
   passes the existing `scripts/smoke.sh` assertions in app and iex mode.
2. `/init` obtains its address, netmask, gateway and DNS server by DHCP when
   `uniapp.ip=` is absent; `make smoke-m0` and `make smoke-m1` pass with the
   static parameters removed from the command line (QEMU user networking
   serves DHCP at 10.0.2.2).
3. Asterinas honours interface configuration at runtime: `SIOCSIFADDR`,
   `SIOCSIFNETMASK`, `SIOCSIFFLAGS`, `SIOCADDRT` succeed (`/init` no longer
   logs `Not a tty`), carried as `builder/asterinas-patches/0003-*.patch` with
   a header suitable for an upstream PR.
4. Asterinas drives the Nitro NVMe root volume: the kernel finds and reads
   the initramfs from `/dev/nvme0n1` on a t3 instance (console log as
   evidence). Any driver fix is a patch under `builder/asterinas-patches/`.
5. Asterinas has an ENA network driver (PCI `1d0f:ec20`): admin queue, one
   Tx/Rx queue pair, interrupts or polling, registered as an
   `aster-network` device. Evidence: criteria 7 and 8 passing on EC2. Keep
   it as a separate component crate so it can be sent upstream.
6. `make ami-publish AWS_PROFILE=elixir-playground` uploads `disk.raw` to S3,
   imports a snapshot, registers an AMI (`--ena-support --boot-mode uefi
   --architecture x86_64 --sriov-net-support simple`), tags every resource
   `Project=elixir_unikernel Version=<VERSION>`, is idempotent, and prints
   the AMI id.
7. `scripts/smoke-ec2.sh <ami>` creates a security group open on 4000 and
   4443 to the caller's IP, launches a t3.small, polls `get-console-output`
   until `uniapp starting` or 120 s, runs the TCP and TLS echo clients
   against the public IP, checks `PROBE dns ok` and `PROBE tls ok` in the
   console output, and terminates the instance and deletes the security
   group in an `EXIT` trap. Exit code reflects the result. Paste its output
   into the PR.
8. IEx over the Serial Console: `scripts/ec2-console.sh <instance>` pushes a
   key with `ec2-instance-connect send-serial-console-ssh-public-key` and
   opens the serial SSH session; typing `1 + 2` at `iex(1)>` prints `3`.
   (Requires `aws ec2 enable-serial-console-access` once per account.)
9. `make ami KERNEL=linux` builds the same disk around a Linux kernel with
   ENA and NVMe built in, and `smoke-ec2.sh` passes on it too. Do this before
   criterion 4 and 5: it validates the disk image, the AWS scripts and the
   DHCP client on real hardware with a known-good kernel, so every later
   failure is attributable to Asterinas.
10. `make ami-clean VERSION=<v>` deregisters the AMIs, deletes the snapshots
    and S3 objects for that version. After the final test run,
    `aws ec2 describe-instances --filters Name=tag:Project,Values=elixir_unikernel
    --query 'Reservations[].Instances[?State.Name!=\`terminated\`]'` returns
    nothing.
11. Docs: manual chapter "Running on EC2" (prerequisites, `make ami`,
    publish, launch, serial console, costs), limits page updated with EC2
    boot time and memory, CHANGELOG entry, and a design note for the ENA
    driver (queue layout, what is not implemented, how it was tested).
12. `make smoke` on `main` still passes after the merge; the QEMU path must
    not regress.

## Constraints

- AWS account: profile `elixir-playground` (Isengard, Admin, eu-central-1,
  account 537124966503). It is a personal playground: create what you need,
  but tag everything and never leave an instance running; a forgotten
  t3.small costs about 18 USD a month. Prefer t3.micro/t3.small; never launch
  anything larger than t3.medium without asking.
- The `credential_process` needs Rosetta 2 on Apple Silicon (installed on
  this machine on 2026-10-08); `aws sts get-caller-identity --profile
  elixir-playground` must work before any AWS step.
- No Marketplace listing, no Graviton, no Xen instance types, no persistent
  data volume: out of scope (see docs/GOALS-EC2.md non-goals).
- Kernel changes go in as patches under `builder/asterinas-patches/`, each
  with a header explaining symptom, cause and fix, and a reproducer where one
  is possible. The ENA driver is new code, not a patch: add it as a component
  crate and keep the diff against upstream `main` applicable.
- QEMU has no ENA model. The ENA development loop is build, `make
  ami-publish`, launch, read console (about 5 minutes). Budget for it; add
  verbose driver logging behind `loglevel=debug` to make each round count.

## Suggested order

disk image in QEMU (1) → DHCP (2) → ioctls (3) → Linux-kernel AMI end to end
(9, 6, 7, 10) → Asterinas on EC2 without network to prove boot + NVMe (4) →
ENA (5) → serial console IEx (8) → docs (11) → merge (12).

Criteria 1 to 3 and 9 are about a week and produce a useful Linux-kernel AMI
on their own. Criterion 5 is the milestone and the bulk of the effort.

## Done when

All twelve criteria have cited command output, `scripts/smoke-ec2.sh` has
passed on the Asterinas AMI at least twice in a row, and no EC2 resources
remain other than the final tagged AMI and its snapshot.
