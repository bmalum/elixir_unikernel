# Security

## Reporting a vulnerability

Please report security issues privately to the maintainer listed in the
repository (GitHub "Report a vulnerability" if enabled, otherwise an email to
the address in the commit log) rather than in a public issue. You will get an
acknowledgement within a week.

## What is in scope

- `/init` (`init/init.c`): it runs as PID 1 and parses the kernel command line.
- `builder/`: the toolchain, including how OpenSSL and OTP are built and
  pinned.
- `builder/asterinas-patches/`: our changes to the kernel.
- `scripts/`: anything that runs on a developer's or CI machine.

Issues in Erlang/OTP, Elixir, OpenSSL or Asterinas themselves should go to
those projects; we will pick up their fixes by bumping the pinned tags.

## Threat model and known properties

- The image has no shell, no dynamic loader and no programs other than the
  BEAM and its `erl_child_setup` helper. Code execution inside the guest means
  Erlang code execution; there is nothing else to pivot to.
- Everything in the image is read-only after boot. Configuration arrives on
  the kernel command line, which is readable by whoever controls the VMM.
  Treat secrets on the command line like environment variables in a
  container.
- `beam.smp` runs as root (there is no other user) and as PID 1. The kernel's
  isolation is the security boundary; Asterinas is pre-1.0 and not yet
  audited for that role.
- TLS: OpenSSL 3.5 from Alpine 3.22, statically linked. Updating it means
  bumping `ALPINE` and rebuilding. The CA bundle is Alpine's
  `ca-certificates`.
- There is no distribution, no `epmd`, and no listening socket unless the
  application opens one.

## Supported versions

Only the latest release is supported. Pinned upstream versions are listed in
`VERSIONS` inside each `dist` bundle.
