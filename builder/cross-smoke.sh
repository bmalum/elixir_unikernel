#!/bin/sh
# cross-smoke.sh <otp-root>: start the (x86-64) beam.smp of a cross-built OTP
# tree, through qemu-user when the host is not x86-64, and check that OTP 29
# boots with ssl/crypto (static OpenSSL) working.
set -eu
ROOT=$1
cd "$ROOT"
ERTS_VSN=$(cat ERTS_VSN)
export BINDIR="$ROOT/erts-$ERTS_VSN/bin" ROOTDIR="$ROOT"
RUN=
if [ "$(uname -m)" != x86_64 ]; then
  apk add --no-cache qemu-x86_64 >/dev/null 2>&1
  RUN=qemu-x86_64
fi
BOOT=$(ls releases/*/start.boot | head -1); BOOT=${BOOT%.boot}
OUT=$($RUN "$BINDIR/beam.smp" -- -root "$ROOT" -bindir "$BINDIR" -progname erl -- -home / -- \
  -boot "$BOOT" -noshell \
  -eval 'io:format("cross otp ~s ~p~n",[erlang:system_info(otp_release), erlang:system_info(emu_flavor)]), {ok,_}=application:ensure_all_started(ssl), io:format("~p~n",[crypto:info_lib()]), halt().' 2>&1 || true)
echo "$OUT" | grep -vE 'ld-musl|Could not open'   # qemu-user noise from the forker exec
echo "$OUT" | grep -q 'cross otp 29 jit'
echo "$OUT" | grep -q 'OpenSSL'
