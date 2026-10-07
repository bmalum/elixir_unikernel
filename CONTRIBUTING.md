# Contributing

Thanks for looking at this. The manual's
[Development workflow](docs/book/src/contributing/workflow.md) chapter has the
edit-build-boot loop and debugging tips; this file covers the mechanics of a
contribution.

## Before you start

- `make check` passes on your machine.
- `make smoke` passes on `main` (about 12 minutes cold). If it does not, that
  is the first bug to report.

## Pull requests

1. One change per PR. Kernel patches, build changes and application changes
   are separate PRs.
2. Run `make smoke` from a clean `build/` before pushing. Paste the
   `SMOKE m0: PASS` / `SMOKE m1: PASS` lines into the PR.
3. If you touched `docs/book/`, run `make docs`; mdBook fails on broken links.
4. Update `CHANGELOG.md` under `Unreleased`.
5. Describe what changed and why. If you fixed a kernel issue, include the
   reproducer, like `builder/asterinas-patches/` does.

## Kernel patches

Patches under `builder/asterinas-patches/` are `git diff` output against the
pinned `ASTERINAS_REF`, numbered, with a header paragraph explaining the
symptom, the cause and the fix. Keep them minimal and send them upstream;
link the upstream issue or PR in the patch header once it exists.

## Bumping upstreams

`OTP_TAG`, `ELIXIR_TAG` and `ASTERINAS_REF` live at the top of the Makefile.
A bump is its own PR with `make smoke` output and any size or memory changes
noted in `docs/book/src/reference/limits.md`.

## Reporting bugs

Please include: host OS and architecture, `make check` output, the kernel
(`m0` or `m1`), the exact `make` target, and the console log from
`build/logs/`. If it is a boot stall, `loglevel=debug` output and the last
few hundred lines help a lot.

## Code of conduct

Be kind and specific. Technical disagreement is welcome; personal remarks are
not.
