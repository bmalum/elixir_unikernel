#!/usr/bin/env bash
# aster-lint.sh: run upstream Asterinas' lint job (typos, rustfmt check, clippy
# with -D warnings) on a ref of the fork clone, for one or more target archs, the
# way asterinas/asterinas CI does per PR. Prints one "LINT ref arch: ok|FAIL"
# line per arch plus the first errors; exits non-zero if any failed.
#
#   scripts/aster-lint.sh [--fork DIR] REF ARCH [ARCH...]
#   scripts/aster-lint.sh --matrix "REF:ARCH REF:ARCH ..."
#
# ARCH is x86_64, riscv64 or loongarch64. REF is any commit-ish of the fork
# clone (build/aster-fork). Runs take 5-10 min each under Rosetta: start them
# through scripts/bg.sh and poll, do not block on this script.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FORK=${FORK:-$ROOT/build/aster-fork}
JOBS=${LINT_JOBS:-2}   # the emulated linker dies with more parallelism
WT=$ROOT/build/aster-lint-wt

pairs=()
while [ $# -gt 0 ]; do
  case $1 in
    --fork) FORK=$2; shift 2 ;;
    --matrix) for p in $2; do pairs+=("$p"); done; shift 2 ;;
    *) ref=$1; shift; for a in "$@"; do pairs+=("$ref:$a"); done; break ;;
  esac
done
[ ${#pairs[@]} -gt 0 ] || { sed -n '2,12p' "$0"; exit 2; }

FORK=$(cd "$FORK" && pwd -P)   # docker (colima) needs the physical $HOME path
IMAGE="asterinas/dev:$(cat "$FORK/DOCKER_IMAGE_VERSION")"
LABEL=${BG_NAME:+--label bg.name=$BG_NAME}
mkdir -p "$FORK/target"

fail=0
for p in "${pairs[@]}"; do
  ref=${p%%:*}; arch=${p##*:}
  sha=$(git -C "$FORK" rev-parse --short "$ref")
  rm -rf "$WT"; git -C "$FORK" worktree prune
  git -C "$FORK" worktree add -q --detach "$WT" "$ref"
  t0=$(date +%s)
  # shellcheck disable=SC2086
  out=$(docker run --rm --platform linux/amd64 $LABEL \
      -e CARGO_BUILD_JOBS="$JOBS" -e OSDK_TARGET_ARCH="$arch" \
      -v "$WT":/root/asterinas -v "$FORK/target":/root/asterinas/target \
      -v "$ROOT/build/asterinas-cache/cargo-registry":/root/.cargo/registry \
      -w /root/asterinas "$IMAGE" bash -c '
        make install_osdk >/dev/null 2>&1
        if typos >/dev/null 2>&1; then echo TYPOS_OK; else echo TYPOS_FAIL; typos 2>&1 | grep -E "^error|-->" | head -6; fi
        if ./tools/format_all.sh --check >/dev/null 2>&1; then echo FMT_OK; else echo FMT_FAIL; ./tools/format_all.sh --check 2>&1 | grep "^Diff in" | head -5; fi
        for try in 1 2 3; do
          o=$(./tools/clippy_check.sh workspace 2>&1)
          echo "$o" | grep -qE "linking with .cc. failed|SIGSEGV|signal: 9" || break
          echo "(linker flake under emulation, retry $try)"
        done
        echo "$o" | grep -E "^error(\[|:)|^\s+--> " | grep -v "duplicate package" | head -8
        echo "$o" | grep -qE "^error" && echo CLIPPY_FAIL || echo CLIPPY_OK
      ' 2>&1 | grep -v "toolchain file" || true)
  rm -f "$WT/core"
  dt=$(( $(date +%s) - t0 ))
  if echo "$out" | grep -q TYPOS_OK && echo "$out" | grep -q FMT_OK && echo "$out" | grep -q CLIPPY_OK; then
    echo "LINT $sha $arch: ok (${dt}s)"
  else
    echo "LINT $sha $arch: FAIL (${dt}s)"; echo "$out" | grep -vE '^(TYPOS|FMT|CLIPPY)_' | sed 's/^/    /'; fail=1
  fi
done
rm -rf "$WT"; git -C "$FORK" worktree prune
exit $fail
